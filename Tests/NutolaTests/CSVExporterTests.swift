import Foundation
import Testing
@testable import Nutola

struct CSVExporterTests {
    // MARK: - Helpers

    private func makeMeeting(
        title: String = "Standup",
        createdAt: Date = Date(timeIntervalSince1970: 1_750_000_000),
        duration: TimeInterval = 65 * 60,
        state: MeetingState = .ready,
        sourceApp: String? = "zoom.us",
        speakers: [Speaker] = [],
        summaryProvider: String? = "claude"
    ) -> Meeting {
        var m = Meeting(title: title, createdAt: createdAt)
        m.duration = duration
        m.state = state
        m.sourceApp = sourceApp
        m.speakers = speakers
        m.summaryProvider = summaryProvider
        return m
    }

    /// RFC 4180-aware field splitter: respects double-quoted fields (which may
    /// contain commas, quotes, or newlines) and unescapes doubled `""`.
    private func csvFields(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = row.startIndex
        while i < row.endIndex {
            let ch = row[i]
            if inQuotes {
                if ch == "\"" {
                    let next = row.index(after: i)
                    if next < row.endIndex, row[next] == "\"" {
                        current.append("\"")
                        i = row.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                        i = next
                        continue
                    }
                }
                current.append(ch)
            } else {
                if ch == "," {
                    fields.append(current)
                    current = ""
                } else if ch == "\"" {
                    inQuotes = true
                } else {
                    current.append(ch)
                }
            }
            i = row.index(after: i)
        }
        fields.append(current)
        return fields
    }

    private func rows(_ csv: String) -> [String] {
        // Records are CRLF-separated; an embedded newline lives inside quotes,
        // so split on CRLF (the record terminator) rather than \n.
        csv.components(separatedBy: "\r\n")
    }

    // MARK: - Header

    @Test func testHeaderIsFirstLine() {
        let csv = CSVExporter.export(meetings: [])
        #expect(csv == CSVExporter.header)
    }

    // MARK: - Basic export

    @Test func testBasicExport() {
        let meeting = makeMeeting(
            title: "Design Sync",
            duration: 12 * 60,
            state: .ready,
            sourceApp: "zoom.us",
            speakers: [
                Speaker(id: "me", name: "Me", isMe: true),
                Speaker(id: "s1", name: "Alice"),
            ],
            summaryProvider: "claude")
        let csv = CSVExporter.export(meetings: [meeting])

        let lines = rows(csv)
        #expect(lines.count == 2)
        #expect(lines[0] == CSVExporter.header)
        let fields = csvFields(lines[1])
        #expect(fields.count == 8)
        #expect(fields[0] == "Design Sync")
        #expect(fields[3] == "ready")
        #expect(fields[4] == "zoom.us")
        #expect(fields[5] == "Me; Alice")
        #expect(fields[6] == "Yes")
        #expect(fields[7] == "Yes")
    }

    // MARK: - Multiple meetings

    @Test func testMultipleMeetings() {
        let meetings = [
            makeMeeting(title: "Standup A", duration: 15 * 60),
            makeMeeting(title: "Standup B", duration: 30 * 60),
            makeMeeting(title: "Standup C", duration: 45 * 60),
        ]
        let csv = CSVExporter.export(meetings: meetings)

        let lines = rows(csv)
        // Header + 3 rows, nothing trailing.
        #expect(lines.count == 4)
        #expect(lines[0] == CSVExporter.header)
        #expect(csvFields(lines[1])[0] == "Standup A")
        #expect(csvFields(lines[2])[0] == "Standup B")
        #expect(csvFields(lines[3])[0] == "Standup C")
    }

    // MARK: - CSV escaping

    @Test func testCSVEscaping() {
        let meeting = makeMeeting(
            title: "Q3 \"Roadmap\", Planning",
            speakers: [Speaker(id: "me", name: "Me, Jr.", isMe: true)])
        let csv = CSVExporter.export(meetings: [meeting])

        let lines = rows(csv)
        #expect(lines.count == 2)
        let fields = csvFields(lines[1])
        // Title with comma and quotes is wrapped and embedded quotes doubled.
        #expect(fields[0] == "Q3 \"Roadmap\", Planning")
        // Speaker name with a comma is also escaped.
        #expect(fields[5] == "Me, Jr.")
    }

    @Test func testFieldWithNewlineIsQuoted() {
        let meeting = makeMeeting(title: "Line one\nLine two")
        let csv = CSVExporter.export(meetings: [meeting])
        // The record stays one logical row; the embedded newline lives inside quotes.
        #expect(csv.contains("\"Line one\nLine two\""))
        // And it round-trips through the field parser.
        let lines = rows(csv)
        #expect(lines.count == 2)
        #expect(csvFields(lines[1])[0] == "Line one\nLine two")
    }

    // MARK: - Empty meetings

    @Test func testEmptyMeetings() {
        let csv = CSVExporter.export(meetings: [])
        #expect(csv == CSVExporter.header)
        // No trailing line break.
        #expect(!(csv.hasSuffix("\r\n")))
    }

    // MARK: - Duration formatting

    @Test func testDurationFormatting() {
        #expect(CSVExporter.duration(0) == "0m")
        #expect(CSVExporter.duration(45) == "1m")
        #expect(CSVExporter.duration(12 * 60) == "12m")
        #expect(CSVExporter.duration(65 * 60) == "1h 5m")
        #expect(CSVExporter.duration(125 * 60) == "2h 5m")
        #expect(CSVExporter.duration(60 * 60) == "1h 0m")
    }

    @Test func testDurationInExportedRow() {
        let meeting = makeMeeting(title: "Sync", duration: 65 * 60)
        let csv = CSVExporter.export(meetings: [meeting])
        #expect(csv.contains(",1h 5m,"))
    }

    // MARK: - Speakers formatting

    @Test func testSpeakersFormatting() {
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
            Speaker(id: "s2", name: "Bob"),
        ]
        let meeting = makeMeeting(title: "Sync", speakers: speakers)
        let csv = CSVExporter.export(meetings: [meeting])

        let lines = rows(csv)
        #expect(csvFields(lines[1])[5] == "Me; Alice; Bob")
    }

    @Test func testNoSpeakers() {
        let meeting = makeMeeting(title: "Solo", speakers: [])
        let csv = CSVExporter.export(meetings: [meeting])

        let lines = rows(csv)
        let fields = csvFields(lines[1])
        #expect(fields[5] == "")
        // No speakers → no transcript signal either.
        #expect(fields[7] == "No")
    }

    // MARK: - State and summary flags

    @Test func testStateRawValue() {
        for state in [MeetingState.prep, .recording, .processing, .ready, .failed] {
            let meeting = makeMeeting(title: "M", state: state)
            let csv = CSVExporter.export(meetings: [meeting])
            let row = rows(csv)[1]
            #expect(row.contains(",\(state.rawValue),"), "expected raw state \(state.rawValue) in row: \(row)")
        }
    }

    @Test func testHasSummaryFlags() {
        let withSummary = makeMeeting(title: "Has", speakers: [Speaker(id: "me", name: "Me", isMe: true)], summaryProvider: "claude")
        let withoutSummary = makeMeeting(title: "Missing", speakers: [Speaker(id: "me", name: "Me", isMe: true)], summaryProvider: nil)

        let csv = CSVExporter.export(meetings: [withSummary, withoutSummary])
        let lines = rows(csv)
        #expect(csvFields(lines[1])[6] == "Yes")
        #expect(csvFields(lines[2])[6] == "No")
    }

    @Test func testSourceAppEmptyWhenNil() {
        let meeting = makeMeeting(title: "M", sourceApp: nil)
        let csv = CSVExporter.export(meetings: [meeting])
        let row = rows(csv)[1]
        #expect(csvFields(row)[4] == "")
    }
}
