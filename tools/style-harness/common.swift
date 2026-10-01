import AppKit
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
import Metal

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    print((ok ? "PASS " : "FAIL ") + msg())
    if !ok { failures += 1 }
}

func registryCount(_ r: AnyObject) -> Int {
    var m: Mirror? = Mirror(reflecting: r)
    while let mm = m {
        for c in mm.children where c.label == "registry" { return Mirror(reflecting: c.value).children.count }
        m = mm.superclassMirror
    }
    return -1
}

struct Bitmap { let w: Int; let h: Int; var px: [UInt8] }

func savePNG(_ img: CGImage, _ path: String) {
    if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}

@MainActor func render(_ root: CALayer, scale: CGFloat, path: String?) -> Bitmap {
    func disp(_ l: CALayer) { l.displayIfNeeded(); l.sublayers?.forEach(disp) }
    disp(root)
    let W = Int(root.bounds.width * scale), H = Int(root.bounds.height * scale)
    var px = [UInt8](repeating: 0, count: W * H * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    px.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.scaleBy(x: scale, y: scale)
        root.render(in: ctx)
        if let path, let img = ctx.makeImage() { savePNG(img, path) }
    }
    return Bitmap(w: W, h: H, px: px)
}

func diff(_ a: Bitmap, _ b: Bitmap) -> (max: Int, mean: Double, over32: Int) {
    guard a.w == b.w, a.h == b.h else { return (999, 999, 999) }
    var mx = 0, sum = 0, over = 0
    for i in 0..<a.px.count {
        let d = abs(Int(a.px[i]) - Int(b.px[i]))
        mx = max(mx, d); sum += d
        if d > 32 { over += 1 }
    }
    return (mx, Double(sum) / Double(a.px.count), over)
}

@MainActor final class Host {
    let root = QuietLayer()
    let r: StyleRenderer
    var size = CGSize.zero
    init(_ r: StyleRenderer) {
        self.r = r
        root.addSublayer(r.layer)
    }
    @discardableResult
    func show(_ c: StyleContent, advancing: Bool, _ ctx: RenderContext, minSize: CGSize = .zero) -> CGSize {
        let s = r.show(c, advancing: advancing, context: ctx)
        size = s
        let P = ctx.padding
        let shown = CGSize(width: max(s.width, minSize.width), height: max(s.height, minSize.height))
        let win = CGSize(width: ceil(shown.width + 2 * P), height: ceil(shown.height + 2 * P))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.bounds = CGRect(origin: .zero, size: win)
        r.layer.position = CGPoint(x: win.width / 2, y: win.height - P)
        CATransaction.commit()
        return s
    }
}

/// Renders a layer tree WITH its animations at a chosen media time, offscreen (CARenderer → Metal texture).
@MainActor final class Offscreen {
    let device = MTLCreateSystemDefaultDevice()!
    let queue: MTLCommandQueue
    let tex: MTLTexture
    let renderer: CARenderer
    let canvas = QuietLayer()
    let W: Int, H: Int
    init(_ content: CALayer, width: Int, height: Int, scale: CGFloat) {
        W = width; H = height
        queue = device.makeCommandQueue()!
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead, .shaderWrite]
        d.storageMode = .shared
        tex = device.makeTexture(descriptor: d)!
        renderer = CARenderer(mtlTexture: tex, options: [kCARendererMetalCommandQueue: queue])
        CATransaction.begin(); CATransaction.setDisableActions(true)
        canvas.bounds = CGRect(x: 0, y: 0, width: W, height: H)
        canvas.anchorPoint = .zero; canvas.position = .zero
        canvas.backgroundColor = CGColor(gray: 0.35, alpha: 1)
        content.anchorPoint = .zero; content.position = .zero
        content.transform = CATransform3DMakeScale(scale, scale, 1)
        canvas.addSublayer(content)
        CATransaction.commit()
        renderer.layer = canvas
        renderer.bounds = canvas.bounds
        _ = frame(at: CACurrentMediaTime(), path: nil)      // warm-up
    }
    /// Returns BGRA pixels (top row first) and optionally saves a PNG.
    @discardableResult
    func frame(at t: CFTimeInterval, path: String?) -> Bitmap {
        CATransaction.flush()
        renderer.beginFrame(atTime: t, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        let cb = queue.makeCommandBuffer()!; cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: W * H * 4)
        tex.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        if let path {
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            px.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                if let raw = ctx.makeImage() { savePNG(raw, path) }
            }
        }
        return Bitmap(w: W, h: H, px: px)
    }
}

func spin(_ dt: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(dt)) }

/// Stacks compositor frames (BGRA, bottom row first) into one upright PNG, cropped to rows [y0, y1) of each.
func sheet(_ frames: [Bitmap], crop: Range<Int>? = nil, path: String) {
    guard let f0 = frames.first else { return }
    let rows = crop ?? 0..<f0.h
    let W = f0.w, H = rows.count * frames.count
    var px = [UInt8](repeating: 0, count: W * H * 4)
    for (k, f) in frames.enumerated() {
        for (j, y) in rows.enumerated() {
            let src = (f.h - 1 - y) * W * 4
            let dst = (k * rows.count + j) * W * 4
            px.replaceSubrange(dst..<dst + W * 4, with: f.px[src..<src + W * 4])
        }
        if k > 0 { let d = k * rows.count * W * 4; for i in stride(from: d, to: d + W * 4, by: 4) { px[i] = 0; px[i + 1] = 0; px[i + 2] = 255; px[i + 3] = 255 } }
    }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    px.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        if let img = ctx.makeImage() { savePNG(img, path) }
    }
}
