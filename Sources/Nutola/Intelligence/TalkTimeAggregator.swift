import Foundation

/// Cross-meeting talk-time summary for a single speaker.
///
/// Aggregates one speaker's talk time across many meetings: the total seconds
/// they spoke, how many of the supplied meetings they appeared in, the average
/// per meeting, and their share of the total talk time across all speakers.
struct SpeakerTalkTimeSummary: Identifiable, Equatable, Sendable {
    let speakerID: String
    let name: String
    let totalTalkTime: TimeInterval
    let meetingCount: Int
    let avgTalkTimePerMeeting: TimeInterval
    let percentageOfTotal: Double

    var meetingID: UUID? = nil
    var localSpeakerID: String? = nil
    var id: String { speakerID }
}

/// Aggregates per-speaker talk time across many meetings.
///
/// For each meeting, per-speaker talk time is computed with `TalkTimeStats.compute`,
/// then summed across meetings. Meetings without a transcript are skipped. Results
/// are sorted by total talk time descending, with stable tie-breaking on speaker ID.
enum TalkTimeAggregator {
    /// Aggregate talk time across the given meetings.
    ///
    /// - Parameters:
    ///   - meetings: Meetings to include in the aggregation.
    ///   - transcripts: `(meetingID, segments)` pairs; entries for meetings not in
    ///     `meetings` are ignored, and meetings with no matching transcript (or an
    ///     empty transcript) are skipped.
    ///   - speakers: `(meetingID, speakers)` pairs used to resolve display names.
    static func aggregate(
        meetings: [Meeting],
        transcripts: [(UUID, [TranscriptSegment])],
        speakers: [(UUID, [Speaker])]
    ) -> [SpeakerTalkTimeSummary] {
        guard !meetings.isEmpty else { return [] }

        let transcriptByID = Dictionary(uniqueKeysWithValues: transcripts)
        let speakersByID = Dictionary(uniqueKeysWithValues: speakers)

        var order: [String] = []
        var totals: [String: TimeInterval] = [:]
        var meetingCounts: [String: Int] = [:]
        var names: [String: String] = [:]
        var origins: [String: (UUID, String)] = [:]

        for meeting in meetings {
            let segments = transcriptByID[meeting.id] ?? []
            guard !segments.isEmpty else { continue }

            let perSpeaker = TalkTimeStats.compute(
                segments: segments,
                speakers: speakersByID[meeting.id] ?? meeting.speakers)

            guard !perSpeaker.isEmpty else { continue }

            var counted = Set<String>()
            for stat in perSpeaker {
                // Anonymous labels identify a voice only within its own meeting.
                let anonymous = Speaker.isAnonymousName(stat.name)
                let key = anonymous ? "\(meeting.id)/\(stat.speakerID)" : Self.nameKey(stat.name)
                if anonymous { origins[key] = (meeting.id, stat.speakerID) }
                if totals[key] == nil { order.append(key) }
                totals[key, default: 0] += stat.talkTime
                if counted.insert(key).inserted { meetingCounts[key, default: 0] += 1 }
                // Prefer the most specific (non-ID) name we see. The first
                // non-key name wins, and a later meeting can refine an unknown
                // name into a real one.
                if names[key] == nil || names[key] == key {
                    names[key] = stat.name
                }
            }
        }

        let grandTotal = totals.values.reduce(0, +)

        return order.map { key in
            let total = totals[key, default: 0]
            let count = meetingCounts[key, default: 0]
            let pct = grandTotal > 0 ? total / grandTotal * 100 : 0
            return SpeakerTalkTimeSummary(
                speakerID: key,
                name: names[key] ?? key,
                totalTalkTime: total,
                meetingCount: count,
                avgTalkTimePerMeeting: count > 0 ? total / Double(count) : 0,
                percentageOfTotal: pct,
                meetingID: origins[key]?.0,
                localSpeakerID: origins[key]?.1)
        }
        .sorted { lhs, rhs in
            lhs.totalTalkTime != rhs.totalTalkTime
                ? lhs.totalTalkTime > rhs.totalTalkTime
                : lhs.speakerID < rhs.speakerID
        }
    }

    /// Normalized key for display-name-based aggregation: lowercase, trimmed,
    /// internal whitespace collapsed to a single space. "Gui Lima" / "gui lima "
    /// / "Gui  Lima" all collapse to "gui lima".
    static func nameKey(_ name: String) -> String {
        name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
