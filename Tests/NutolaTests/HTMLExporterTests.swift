import Foundation
import Testing
@testable import Nutola

struct HTMLExporterTests {
    // MARK: - renderMarkdown

    @Test func testHeadings() {
        let html = HTMLExporter.renderMarkdown("# One\n## Two\n### Three")
        #expect(html.contains("<h1>One</h1>"))
        #expect(html.contains("<h2>Two</h2>"))
        #expect(html.contains("<h3>Three</h3>"))
    }

    @Test func testParagraphsSeparatedByBlankLines() {
        let html = HTMLExporter.renderMarkdown("First line\nstill first.\n\nSecond.")
        #expect(html.contains("<p>First line still first.</p>"))
        #expect(html.contains("<p>Second.</p>"))
    }

    @Test func testBoldAndItalic() {
        let html = HTMLExporter.renderMarkdown("Ship **now** and *fast*.")
        #expect(html.contains("<strong>now</strong>"))
        #expect(html.contains("<em>fast</em>"))
        #expect(!(html.contains("*")))
    }

    @Test func testSpacedAsterisksNotItalic() {
        // CommonMark: * text * (whitespace-flanking) is not emphasis.
        let html = HTMLExporter.renderMarkdown("The ratio was * 3 * and that was fine.")
        #expect(!(html.contains("<em>")))
        #expect(html.contains("* 3 *"))
    }

    @Test func testSpacedAsterisksNotBold() {
        // CommonMark: ** text ** (whitespace-flanking) is not bold.
        let html = HTMLExporter.renderMarkdown("It was ** not important ** so we skipped it.")
        #expect(!(html.contains("<strong>")))
    }

    @Test func testSingleCharEmphasis() {
        // Single-character emphasis like *a* should still render as italic.
        let html = HTMLExporter.renderMarkdown("This is *a* test.")
        #expect(html.contains("<em>a</em>"))
    }

    @Test func testBullets() {
        let html = HTMLExporter.renderMarkdown("- one\n- two\n\nafter")
        #expect(html.contains("<ul>"))
        #expect(html.contains("<li>one</li>"))
        #expect(html.contains("<li>two</li>"))
        #expect(html.contains("</ul>"))
        #expect(html.contains("<p>after</p>"))
    }

    @Test func testCheckboxes() {
        let html = HTMLExporter.renderMarkdown("- [ ] open item\n- [x] done item")
        #expect(html.contains("<li class=\"task\"><input type=\"checkbox\" disabled> open item</li>"))
        #expect(html.contains("<li class=\"task\"><input type=\"checkbox\" disabled checked> done item</li>"))
    }

    @Test func testUnknownLinesBecomeParagraphs() {
        let html = HTMLExporter.renderMarkdown("> not a supported quote")
        #expect(html.contains("<p>&gt; not a supported quote</p>"))
    }

    @Test func testHorizontalRule() {
        let html = HTMLExporter.renderMarkdown("Before\n\n---\n\nAfter")
        #expect(html.contains("<hr>"))
        #expect(!(html.contains("---")))
        #expect(html.contains("<p>Before</p>"))
        #expect(html.contains("<p>After</p>"))
    }

    // MARK: - escape

    @Test func testEscapeNeutralizesScriptTag() {
        let out = HTMLExporter.escape("<script>alert('x & y')</script>")
        #expect(!(out.contains("<script>")))
        #expect(out == "&lt;script&gt;alert(&#39;x &amp; y&#39;)&lt;/script&gt;")
    }

    // MARK: - html

    @Test func testHTMLDocument() {
        var m = Meeting(title: "Design Sync <Q3>", createdAt: Date(timeIntervalSince1970: 1_750_000_000))
        m.duration = 30 * 60
        m.attendees = ["Alice", "Bob"]
        m.speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
        ]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 2, text: "Hi <everyone>."),
            TranscriptSegment(speakerID: "me", start: 2, end: 4, text: "Let's begin."),
            TranscriptSegment(speakerID: "s1", start: 65, end: 70, text: "Sounds good."),
        ]
        let html = HTMLExporter.html(
            meeting: m,
            summaryMarkdown: "# {{title}}\n\n{{date}} · {{attendees}}\n\n## TL;DR\nWe met.",
            segments: segments)

        // title (escaped) in <title> and header; raw user markup never survives
        #expect(html.contains("<title>Design Sync &lt;Q3&gt;</title>"))
        #expect(html.contains("<h1>Design Sync &lt;Q3&gt;</h1>"))
        #expect(!(html.contains("<Q3>")))

        // speaker names and attendee chips
        #expect(html.contains("<span class=\"speaker\">Me</span>"))
        #expect(html.contains("<span class=\"speaker\">Alice</span>"))
        #expect(html.contains("<span class=\"chip\">Bob</span>"))

        // timestamps, with consecutive same-speaker segments merged into one turn
        #expect(html.contains("0:00"))
        #expect(html.contains("1:05"))
        #expect(html.contains("<p>Hi &lt;everyone&gt;. Let&#39;s begin.</p>"))

        // template placeholders were filled — none leak into the page
        #expect(!(html.contains("{{")))
        #expect(html.contains("30 min"))
    }

    @Test func testGeneratorMetaPresentOnceBeforeTitle() {
        let m = Meeting(title: "Solo", createdAt: Date())
        let html = HTMLExporter.html(meeting: m, summaryMarkdown: "", segments: [])
        let marker = "<meta name=\"generator\" content=\"nutola/1\">"
        #expect(html.components(separatedBy: marker).count - 1 == 1)
        guard let markerRange = html.range(of: marker), let titleRange = html.range(of: "<title>") else {
            Issue.record("expected both generator meta and <title> in output")
            return
        }
        #expect(markerRange.upperBound <= titleRange.lowerBound)
    }

    @Test func testHTMLOmitsEmptySections() {
        let m = Meeting(title: "Solo", createdAt: Date())
        let html = HTMLExporter.html(meeting: m, summaryMarkdown: "", segments: [])
        #expect(!(html.contains("Transcript")))
        #expect(!(html.contains("Summary")))
        #expect(html.contains("Recorded with"))
    }
}
