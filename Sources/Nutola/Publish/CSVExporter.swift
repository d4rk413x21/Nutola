import Foundation

/// Bulk meeting metadata exporter — one CSV row per meeting.
///
/// Columns: Title, Date, Duration, State, Source, Speakers, Has Summary, Has Transcript.
/// Fields containing commas, quotes, or newlines are RFC 4180-escaped by wrapping
/// them in double quotes and doubling any embedded quotes.
enum CSVExporter {
    /// Header row, in column order.
    static let header = "Title,Date,Duration,State,Source,Speakers,Has Summary,Has Transcript"

    /// Render `meetings` as CSV. An empty list yields just the header line.
    static func export(meetings: [Meeting]) -> String {
        var lines: [String] = [header]
        for meeting in meetings {
            lines.append(row(for: meeting))
        }
        return lines.joined(separator: "\r\n")
    }

    /// One CSV record (no terminator) for a single meeting.
    private static func row(for meeting: Meeting) -> String {
        let fields = [
            meeting.title,
            dateString(meeting.createdAt),
            duration(meeting.duration),
            meeting.state.rawValue,
            meeting.sourceApp ?? "",
            speakersField(meeting.speakers),
            meeting.summaryProvider != nil ? "Yes" : "No",
            meeting.speakers.isEmpty ? "No" : "Yes",
        ]
        return fields.map(escape).joined(separator: ",")
    }

    /// "12m" for under an hour, "1h 5m" otherwise. 0 seconds → "0m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int((seconds / 60).rounded())
        if total < 60 { return "\(total)m" }
        return "\(total / 60)h \(total % 60)m"
    }

    /// ISO 8601 date — sortable and unambiguous in a spreadsheet.
    private static func dateString(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// Speakers as semicolon-joined display names, preserving stored order.
    private static func speakersField(_ speakers: [Speaker]) -> String {
        speakers.map(\.name).joined(separator: "; ")
    }

    /// RFC 4180 escaping: wrap in quotes when the field contains a comma, quote,
    /// CR, or LF; double every embedded quote.
    static func escape(_ field: String) -> String {
        let needsQuoting = field.contains(",") || field.contains("\"")
            || field.contains("\r") || field.contains("\n")
        guard needsQuoting else { return field }
        let doubled = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(doubled)\""
    }

}
