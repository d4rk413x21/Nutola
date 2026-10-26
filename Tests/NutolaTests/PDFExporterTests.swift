import Foundation
import Testing
@testable import Nutola

struct PDFExporterTests {
    @Test func testExportProducesNonEmptyPDF() throws {
        let meeting = Meeting(
            title: "Test Meeting",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 600
        )
        let summary = """
        # Summary

        - Decision A
        - Decision B
        """
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 3, text: "Hello world"),
            TranscriptSegment(speakerID: "s1", start: 4, end: 7, text: "Hi there")
        ]
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Speaker 1")
        ]
        var meetingWithSpeakers = meeting
        meetingWithSpeakers.speakers = speakers

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-pdf-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: dest) }

        try PDFExporter.exportPDF(
            meeting: meetingWithSpeakers,
            summaryMarkdown: summary,
            segments: segments,
            to: dest)

        #expect(FileManager.default.fileExists(atPath: dest.path), "PDF should exist at \(dest.path)")
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 100, "PDF should not be empty")
        // PDF magic bytes
        let data = try Data(contentsOf: dest)
        #expect(data.prefix(4) == Data("%PDF".utf8), "File should start with %PDF")
    }
}
