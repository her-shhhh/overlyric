import Foundation
import Testing
@testable import OverlyricCore

@Suite struct GuideDocumentTests {
    let sample = """
    Overlyric 1.1.2 - sing along to anything on Spotify


    HOW THIS HAPPENED

    I always have music on while I work, and a song is twice as good
    when I can sing along.


    SET IT UP (2 minutes, once)

    1. Drag Overlyric onto the Applications folder. Do NOT double-click
       it in there.

    2. Open it. The first time:
       - macOS 15 or later: click Done, then go to System Settings >
         Privacy & Security.
       - macOS 14: Control-click it.

    USE IT

    - Drag the lyrics anywhere. Hold Cmd and scroll on them.
    - Click the lyrics to jump to Spotify.
    """

    @Test func parsesTitleHeadingsParagraphsAndLists() {
        let blocks = GuideDocument.parse(sample)
        #expect(blocks == [
            .title("Overlyric 1.1.2 - sing along to anything on Spotify"),
            .heading("How this happened", aside: nil),
            .paragraph("I always have music on while I work, and a song is twice as good when I can sing along."),
            .heading("Set it up", aside: "2 minutes, once"),
            .numbered(1, "Drag Overlyric onto the Applications folder. Do NOT double-click it in there."),
            .numbered(2, "Open it. The first time:"),
            .bullet("macOS 15 or later: click Done, then go to System Settings > Privacy & Security.", level: 1),
            .bullet("macOS 14: Control-click it.", level: 1),
            .heading("Use it", aside: nil),
            .bullet("Drag the lyrics anywhere. Hold Cmd and scroll on them.", level: 0),
            .bullet("Click the lyrics to jump to Spotify.", level: 0),
        ])
    }

    @Test func mixedCaseLinesAreNotHeadings() {
        #expect(GuideDocument.parse("Title\n\nHappy singing!") == [.title("Title"), .paragraph("Happy singing!")])
    }

    @Test func prettifiesPlainAscii() {
        #expect(Typography.prettify(#"Hold Cmd and "scroll" - it's System Settings > Privacy"#)
                == "Hold \u{2318} and \u{201C}scroll\u{201D} \u{2014} it\u{2019}s System Settings \u{203A} Privacy")
    }

    @Test func parsesTheRealGuide() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/friends-readme.txt")
        let blocks = GuideDocument.parse(try String(contentsOf: url, encoding: .utf8))
        let headings = blocks.compactMap { if case .heading(let h, _) = $0 { return h } else { return nil } }
        #expect(headings == ["How this happened", "What it is", "Set it up", "Use it", "About the scary warnings"])
        #expect(blocks.contains { if case .numbered(4, _) = $0 { return true } else { return false } })
        // No list text should still carry a wrapped-line indent.
        for b in blocks { if case .bullet(let t, _) = b { #expect(!t.contains("  ")) } }
    }
}
