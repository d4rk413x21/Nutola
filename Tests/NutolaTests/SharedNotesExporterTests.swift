import Foundation
import Testing
@testable import Nutola

struct SharedNotesExporterTests {
    // MARK: - fixtures

    private func sampleMeeting() -> Meeting {
        var m = Meeting(title: "Sprint Planning", createdAt: Date(timeIntervalSince1970: 1_750_000_000))
        m.duration = 30 * 60
        m.speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
        ]
        return m
    }

    private func sampleTranscript() -> [TranscriptTurn] {
        [
            TranscriptTurn(id: "me-0", speakerID: "me", start: 0, end: 4, text: "Welcome everyone.", segmentCount: 1),
            TranscriptTurn(id: "s1-65", speakerID: "s1", start: 65, end: 70, text: "Thanks for hosting.", segmentCount: 1),
        ]
    }

    private func sampleActionItems() -> [ActionItem] {
        [
            ActionItem(text: "Send the recap", owner: "Alice", isChecked: false, lineNumber: 1),
            ActionItem(text: "File the ticket", owner: nil, isChecked: true, lineNumber: 2),
        ]
    }

    private func sampleSummary() -> String {
        "# Sprint Planning\n\n## TL;DR\nWe aligned on the Q3 scope."
    }

    // MARK: - exportHTML

    @Test func testExportHTMLContainsTitle() {
        let html = SharedNotesExporter.exportHTML(
            meeting: sampleMeeting(),
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            actionItems: sampleActionItems())
        #expect(html.contains("<title>Sprint Planning</title>"))
        #expect(html.contains("<h1>Sprint Planning</h1>"))
    }

    @Test func testExportHTMLContainsSummary() {
        let html = SharedNotesExporter.exportHTML(
            meeting: sampleMeeting(),
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            actionItems: sampleActionItems())
        #expect(html.contains("We aligned on the Q3 scope."))
        #expect(html.contains("TL;DR"))
    }

    @Test func testExportHTMLContainsTranscript() {
        let html = SharedNotesExporter.exportHTML(
            meeting: sampleMeeting(),
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            actionItems: sampleActionItems())
        #expect(html.contains("<span class=\"speaker\">Me</span>"))
        #expect(html.contains("<span class=\"speaker\">Alice</span>"))
        #expect(html.contains("Welcome everyone."))
        #expect(html.contains("Thanks for hosting."))
        // Timestamps from the turn starts.
        #expect(html.contains("0:00"))
        #expect(html.contains("1:05"))
    }

    @Test func testExportHTMLContainsActionItems() {
        let html = SharedNotesExporter.exportHTML(
            meeting: sampleMeeting(),
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            actionItems: sampleActionItems())
        #expect(html.contains("Send the recap"))
        #expect(html.contains("File the ticket"))
        #expect(html.contains("Action items"))
        // Owner rendered inline.
        #expect(html.contains("Alice"))
    }

    @Test func testExportHTMLIsSelfContained() {
        let html = SharedNotesExporter.exportHTML(
            meeting: sampleMeeting(),
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            actionItems: sampleActionItems())
        #expect(!(html.contains("<link")))
        #expect(!(html.contains("<script src=")))
        #expect(!(html.contains("<script")))
    }

    @Test func testExportHTMLHasDarkTheme() {
        let html = SharedNotesExporter.exportHTML(
            meeting: sampleMeeting(),
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            actionItems: sampleActionItems())
        #expect(html.contains("background"))
        #expect(html.contains("#1") || html.contains("#2") || html.contains("#14"))
    }

    @Test func testExportToFileReturnsURL() throws {
        let url = try SharedNotesExporter.exportToFile(
            meeting: sampleMeeting(),
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            actionItems: sampleActionItems())
        #expect(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        let html = String(data: data, encoding: .utf8) ?? ""
        #expect(html.contains("<title>Sprint Planning</title>"))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func testExportHTMLWithEmptyData() {
        let m = Meeting(title: "Empty", createdAt: Date())
        let html = SharedNotesExporter.exportHTML(
            meeting: m,
            summary: "",
            transcript: [],
            actionItems: [])
        #expect(html.contains("<!doctype html>"))
        #expect(html.contains("<title>Empty</title>"))
        #expect(html.contains("<html"))
        #expect(html.contains("</html>"))
        // Empty sections are simply omitted — still a valid page.
        #expect(!(html.contains("Summary")))
        #expect(!(html.contains("Transcript")))
        #expect(!(html.contains("Action items")))
    }
}
