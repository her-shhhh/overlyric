import AppKit
import OverlyricCore

/// The friends' guide in a small, nicely set window: app icon and title, then the story, setup, controls
/// and the "scary warnings" explainer. It typesets the same text that ships as "Read This or Hum
/// Forever.txt" next to the app in the DMG, so the two can never drift apart.
@MainActor
final class GuideWindow: NSObject {
    static let shared = GuideWindow()
    static let repoURL = URL(string: "https://github.com/her-shhhh/overlyric")!

    private var window: NSWindow?

    func show() {
        guard let url = Bundle.main.url(forResource: "Read This or Hum Forever", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            NSWorkspace.shared.open(Self.repoURL.appendingPathComponent("#readme"))
            return
        }
        let firstTime = window == nil
        if firstTime { window = makeWindow(guide: text) }
        NSApp.activate()
        if firstTime { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Window

    func makeWindow(guide: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 700),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Read This or Hum Forever"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 460, height: 420)

        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        w.contentView = background

        // Header: icon, name, version + tagline.
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = label("Overlyric", font: Self.rounded(26, .heavy), color: .labelColor)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let tagline = label("Version \(version)  \u{00B7}  sing along to anything on Spotify",
                            font: .systemFont(ofSize: 12.5), color: .secondaryLabelColor)
        let titles = NSStackView(views: [name, tagline])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let header = NSStackView(views: [icon, titles])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        // Body: the guide, typeset.
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(Self.typeset(GuideDocument.parse(guide)))
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)

        let divider = NSBox()
        divider.boxType = .separator

        // Footer.
        let github = NSButton(title: "View on GitHub", target: self, action: #selector(openGitHub))
        github.bezelStyle = .rounded
        let sing = NSButton(title: "Let\u{2019}s sing \u{266A}", target: self, action: #selector(close(_:)))
        sing.bezelStyle = .rounded
        sing.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [github, spacer, sing])
        footer.orientation = .horizontal

        for v in [header, scroll, divider, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        let margin: CGFloat = 32
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 60),
            icon.heightAnchor.constraint(equalToConstant: 60),
            header.topAnchor.constraint(equalTo: background.topAnchor, constant: 40),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: margin),
            header.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -margin),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: margin),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -margin + 12),
            divider.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            footer.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 14),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: margin),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -margin),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -16),
        ])
        textView.frame = NSRect(x: 0, y: 0, width: 580 - 2 * margin, height: 100)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        return w
    }

    @objc private func openGitHub() { NSWorkspace.shared.open(Self.repoURL) }
    @objc private func close(_ sender: Any?) { window?.close() }

    private func label(_ s: String, font: NSFont, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = font
        l.textColor = color
        return l
    }

    // MARK: Typesetting

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    /// A soft yellow, deepened to a readable gold on light backgrounds.
    static let accent = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1.00, green: 0.89, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.52, blue: 0.00, alpha: 1)
    }

    static func typeset(_ blocks: [GuideBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 13.5)
        func para(spacingBefore: CGFloat = 0, after: CGFloat = 8, indent: CGFloat = 0, first: CGFloat? = nil,
                  tab: CGFloat? = nil) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.22
            p.paragraphSpacingBefore = spacingBefore
            p.paragraphSpacing = after
            p.headIndent = indent
            p.firstLineHeadIndent = first ?? indent
            if let tab { p.tabStops = [NSTextTab(textAlignment: .left, location: tab)] }
            return p
        }
        /// Body text; a leading “quoted phrase” (the warnings' own words) is set in bold.
        func bodyText(_ raw: String, _ style: NSParagraphStyle) -> NSAttributedString {
            let s = Typography.prettify(raw)
            let a = NSMutableAttributedString(string: s, attributes: [.font: body, .foregroundColor: NSColor.labelColor,
                                                                      .paragraphStyle: style])
            if s.hasPrefix("\u{201C}"), let close = s.range(of: "\u{201D}") {
                let r = NSRange(s.startIndex..<close.upperBound, in: s)
                a.addAttribute(.font, value: NSFont.systemFont(ofSize: 13.5, weight: .semibold), range: r)
            }
            return a
        }
        var first = true
        for block in blocks {
            switch block {
            case .title:
                continue      // the window header shows it
            case .heading(let h, let aside):
                if !first { out.append(NSAttributedString(string: "\n")) }
                let style = para(spacingBefore: first ? 0 : 14, after: 6)
                out.append(NSAttributedString(string: h, attributes: [
                    .font: rounded(17, .bold), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]))
                if let aside {
                    out.append(NSAttributedString(string: "   " + Typography.prettify(aside), attributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                        .paragraphStyle: style]))
                }
            case .paragraph(let t):
                out.append(NSAttributedString(string: "\n"))
                out.append(bodyText(t, para(after: 8)))
            case .bullet(let t, let level):
                out.append(NSAttributedString(string: "\n"))
                let x: CGFloat = level == 0 ? 2 : 26
                let style = para(after: 6, indent: x + 16, first: x, tab: x + 16)
                out.append(NSAttributedString(string: (level == 0 ? "\u{2022}" : "\u{2013}") + "\t", attributes: [
                    .font: rounded(13.5, .bold), .foregroundColor: accent, .paragraphStyle: style]))
                out.append(bodyText(t, style))
            case .numbered(let n, let t):
                out.append(NSAttributedString(string: "\n"))
                let style = para(after: 6, indent: 26, first: 2, tab: 26)
                out.append(NSAttributedString(string: "\(n)\t", attributes: [
                    .font: rounded(14, .heavy), .foregroundColor: accent, .paragraphStyle: style]))
                out.append(bodyText(t, style))
            }
            first = false
        }
        return out
    }
}
