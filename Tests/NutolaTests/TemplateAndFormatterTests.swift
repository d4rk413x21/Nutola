import Foundation
import Testing
@testable import Nutola

struct TemplateTests {
    @Test func testFillSubstitutesPlaceholders() {
        var m = Meeting(title: "Kickoff", createdAt: Date(timeIntervalSince1970: 1_750_000_000))
        m.attendees = ["Alice", "Bob"]
        m.duration = 65 * 60
        m.sourceApp = "zoom.us"
        let out = TemplateRenderer.fill(
            "# {{title}}\n{{attendees}} · {{duration}} · {{app}}", meeting: m)
        #expect(out.contains("# Kickoff"))
        #expect(out.contains("Alice, Bob"))
        #expect(out.contains("1 hr 5 min"))
        #expect(out.contains("zoom.us"))
        #expect(!(out.contains("{{")))
    }

    @Test func testFillFallsBackToSpeakersWhenNoAttendees() {
        var m = Meeting(title: "Chat", createdAt: Date())
        m.speakers = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Dana")]
        let out = TemplateRenderer.fill("{{attendees}}", meeting: m)
        #expect(out == "Me, Dana")
    }

    @Test func testTemplateStoreSeedsAndRoundTrips() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-tpl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TemplateStore(root: tmp)
        #expect(store.list().map(\.name).contains("Meeting Notes"))
        try store.save(SummaryTemplate(name: "Retro", body: "## Went well"))
        #expect(store.template(named: "Retro")?.body == "## Went well")
        try store.delete(named: "Retro")
        #expect(store.template(named: "Retro") == nil)
    }

    @Test func testTemplateRenameRejectsSlashAndKeepsBody() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-tpl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TemplateStore(root: tmp)
        try store.save(SummaryTemplate(name: "Weekly", body: "## Agenda"))
        #expect(throws: (any Error).self) { try store.rename(from: "Weekly", to: "Notes 6/25", body: "## Agenda") }
        // The original must survive a rejected rename.
        #expect(store.template(named: "Weekly")?.body == "## Agenda")
    }

    @Test func testTemplateRenameRefusesToOverwriteAnother() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-tpl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TemplateStore(root: tmp)
        try store.save(SummaryTemplate(name: "A", body: "aaa"))
        try store.save(SummaryTemplate(name: "B", body: "bbb"))
        #expect(throws: (any Error).self) { try store.rename(from: "A", to: "B", body: "aaa") }
        #expect(store.template(named: "B")?.body == "bbb") // untouched
        #expect(store.template(named: "A")?.body == "aaa") // still there
    }

    @Test func testTemplateRenameSucceeds() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-tpl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TemplateStore(root: tmp)
        try store.save(SummaryTemplate(name: "Old", body: "body"))
        try store.rename(from: "Old", to: "New", body: "body v2")
        #expect(store.template(named: "Old") == nil)
        #expect(store.template(named: "New")?.body == "body v2")
    }

    @Test func testTemplateCaseOnlyRename() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-tpl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TemplateStore(root: tmp)
        try store.save(SummaryTemplate(name: "notes", body: "b"))
        try store.rename(from: "notes", to: "Notes", body: "b")
        let names = store.list().map(\.name)
        #expect(names.contains("Notes"))
        #expect(!(names.contains("notes"))) // the lowercase entry is gone, not duplicated
    }
}

struct FormatterTests {
    let speakers = [
        Speaker(id: "me", name: "Me", isMe: true),
        Speaker(id: "s1", name: "Alice"),
    ]
    let segments = [
        TranscriptSegment(speakerID: "me", start: 0, end: 2, text: "Hi Alice."),
        TranscriptSegment(speakerID: "s1", start: 3, end: 5, text: "Hey!"),
        TranscriptSegment(speakerID: "s1", start: 5, end: 8, text: "Ready when you are."),
        TranscriptSegment(speakerID: "me", start: 70, end: 72, text: "Let's start."),
    ]

    @Test func testPlainText() {
        let text = TranscriptFormatter.plainText(segments, speakers: speakers)
        #expect(text.split(separator: "\n").count == 4)
        #expect(text.contains("Me @ 0:00: Hi Alice."))
        #expect(text.contains("Alice @ 0:03: Hey!"))
        #expect(text.contains("Me @ 1:10: Let's start."))
    }

    @Test func testMarkdownMergesConsecutiveTurns() {
        let md = TranscriptFormatter.markdown(segments, speakers: speakers)
        #expect(md.contains("Hey! Ready when you are."))
        #expect(md.components(separatedBy: "**Alice**").count == 2) // one Alice block
    }

    @Test func testParseEditedRoundTrip() {
        let text = TranscriptFormatter.plainText(segments, speakers: speakers)
        let (parsed, outSpeakers) = TranscriptFormatter.parseEdited(
            text, originalSegments: segments, speakers: speakers)
        #expect(parsed.count == 4)
        #expect(parsed.map(\.text) == segments.map(\.text))
        #expect(parsed.map(\.speakerID) == segments.map(\.speakerID))
        #expect(parsed[3].start == 70)
        #expect(outSpeakers.count == 2)
    }

    @Test func testParseEditedRenamesAndNewSpeaker() {
        let edited = """
        Me @ 0:00: Hi Alice.
        Bob @ 0:03: Actually it's Bob.
        """
        let (parsed, outSpeakers) = TranscriptFormatter.parseEdited(
            edited, originalSegments: segments, speakers: speakers)
        #expect(parsed.count == 2)
        #expect(outSpeakers.count == 3)
        #expect(outSpeakers.contains { $0.name == "Bob" })
        #expect(parsed[1].speakerID == outSpeakers.first { $0.name == "Bob" }!.id)
        // reused original end time for the matching 0:03 segment
        #expect(parsed[1].end == 5)
    }

    @Test func testParseEditedKeepsDistinctSpeakersSharingAName() {
        // Two speakers with the same display name must NOT be merged by a no-op
        // save — identity resolves by timestamp for unchanged names.
        let dupSpeakers = [
            Speaker(id: "me", name: "Alex", isMe: true),
            Speaker(id: "s1", name: "Alex"),
        ]
        let segs = [
            TranscriptSegment(speakerID: "me", start: 0, end: 2, text: "Hi."),
            TranscriptSegment(speakerID: "s1", start: 3, end: 5, text: "Hello."),
        ]
        let text = TranscriptFormatter.plainText(segs, speakers: dupSpeakers)
        let (parsed, _) = TranscriptFormatter.parseEdited(
            text, originalSegments: segs, speakers: dupSpeakers)
        #expect(parsed.map(\.speakerID) == ["me", "s1"])
    }

    @Test func testParseEditedContinuationLines() {
        let edited = """
        Me @ 0:00: First line
        and a continuation.
        """
        let (parsed, _) = TranscriptFormatter.parseEdited(
            edited, originalSegments: [], speakers: speakers)
        #expect(parsed.count == 1)
        #expect(parsed[0].text == "First line and a continuation.")
    }
}
