import Foundation
import SwiftUI

/// A single meeting's search result across the transcript and summary.
struct MeetingSearchResult: Identifiable {
    let meeting: Meeting
    let matchingSegments: [TranscriptSegment]
    let summaryMatch: Bool
    var id: UUID { meeting.id }
}

/// Observable, main-actor face of MeetingArchive for the UI.
@MainActor
final class MeetingStore: ObservableObject {
    let archive: MeetingArchive
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var transcriptRevision: UInt64 = 0

    /// Hook fired after a summary is saved, carrying the meeting id and
    /// the new markdown. Wired by `AppState` to sync action items into the
    /// task tracker. Kept as a plain closure (not a protocol) so `MeetingStore`
    /// stays decoupled from the tracker layer.
    var onSummarySaved: ((UUID, String) -> Void)?
    var onMeetingDeleted: ((UUID) -> Void)?

    init(archive: MeetingArchive = MeetingArchive()) {
        self.archive = archive
        reload()
    }

    func reload() {
        meetings = archive.allMeetings()
    }

    func meeting(id: UUID) -> Meeting? {
        meetings.first { $0.id == id } ?? archive.meeting(id: id)
    }

    @discardableResult
    func upsert(_ meeting: Meeting) -> Meeting {
        do {
            try archive.save(meeting)
        } catch MeetingArchive.ArchiveError.meetingDeleted {
            // The meeting was deleted out from under a long-running task —
            // don't resurrect it in memory either.
            meetings.removeAll { $0.id == meeting.id }
            return meeting
        } catch {
            // Keep the latest edits visible while FilePersistence retains the failed write.
            PersistenceStatus.shared.report(error)
        }
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[i] = meeting
        } else {
            meetings.insert(meeting, at: 0)
            meetings.sort { $0.createdAt > $1.createdAt }
        }
        return meeting
    }

    func delete(id: UUID) {
        do { try archive.delete(id: id) }
        catch { PersistenceStatus.shared.report(error); return }
        meetings.removeAll { $0.id == id }
        onMeetingDeleted?(id)
    }

    func transcript(for id: UUID) -> [TranscriptSegment] { archive.transcript(for: id) }

    func saveTranscript(_ segments: [TranscriptSegment], for id: UUID) {
        defer { transcriptRevision &+= 1 }
        do { try archive.saveTranscript(segments, for: id) }
        catch { PersistenceStatus.shared.report(error) }
    }

    func summary(for id: UUID) -> String { archive.summary(for: id) }

    func saveSummary(_ markdown: String, for id: UUID) {
        _ = saveSummarySafely(markdown, for: id)
    }

    @discardableResult
    func saveSummarySafely(_ markdown: String, for id: UUID) -> Bool {
        do { try archive.saveSummary(markdown, for: id) }
        catch { PersistenceStatus.shared.report(error); return false }
        onSummarySaved?(id, markdown)
        return true
    }

    /// Search across all meetings' transcripts and summaries for a query.
    /// Returns meetings with matching segments/summaries, case-insensitive.
    func searchAll(_ query: String) -> [MeetingSearchResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var results: [MeetingSearchResult] = []
        for meeting in meetings {
            let segs = transcript(for: meeting.id)
            let matchingSegments = segs.filter {
                $0.text.localizedCaseInsensitiveContains(q)
            }
            let summaryText = summary(for: meeting.id)
            let summaryMatch = summaryText.localizedCaseInsensitiveContains(q) && !summaryText.isEmpty
            if !matchingSegments.isEmpty || summaryMatch {
                results.append(MeetingSearchResult(
                    meeting: meeting,
                    matchingSegments: matchingSegments,
                    summaryMatch: summaryMatch))
            }
        }
        return results.sorted { $0.matchingSegments.count > $1.matchingSegments.count }
    }

    func sideNotes(for id: UUID) -> String {
        let file = archive.folder(for: id).appendingPathComponent("notes.md")
        return FilePersistence.failure(at: file).map { String(decoding: $0.data, as: UTF8.self) }
            ?? archive.sideNotes(for: id)
    }

    func saveSideNotes(_ text: String, for id: UUID) {
        do { try archive.saveSideNotes(text, for: id) }
        catch { PersistenceStatus.shared.report(error) }
    }

    /// Rename a speaker everywhere in one meeting.
    func renameSpeaker(meetingID: UUID, speakerID: String, to newName: String) {
        guard var m = meeting(id: meetingID) else { return }
        guard let i = m.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
        m.speakers[i].name = newName
        upsert(m)
    }

    /// Rename every speaker whose display name matches `fromName` (case-insensitive,
    /// whitespace-normalized — the same rule `TalkTimeAggregator.nameKey` uses) to
    /// `toName`, across ALL meetings. This is the engine behind the insights
    /// dashboard's "Rename" and "Merge with…" actions.
    ///
    /// Within a single meeting, multiple distinct speaker IDs may all carry the
    /// same display name (rare but possible after a rename). They all get the new
    /// name. The `speakerID` on each transcript segment is NOT changed — the IDs
    /// stay stable, only the display name is rewritten. Aggregation will still
    /// merge them because it keys on the (now identical) display name.
    ///
    /// `toName` is taken verbatim. Returns the number of meetings touched.
    @discardableResult
    func bulkRenameSpeakers(from fromName: String, to toName: String) -> Int {
        let target = toName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = fromName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !source.isEmpty else { return 0 }
        guard !Speaker.isAnonymousName(source) else { return 0 }
        // No-op only when the raw (trimmed) display strings are identical —
        // case/whitespace-only differences (e.g. "alice" → "Alice") still
        // apply so the user can fix capitalization.
        guard source != target else { return 0 }
        let fromKey = Self.nameKey(fromName)

        var touched = 0
        for candidate in meetings {
            guard candidate.speakers.contains(where: { Self.nameKey($0.name) == fromKey }) else { continue }
            guard var updated = self.meeting(id: candidate.id) else { continue }
            var changed = false
            for i in updated.speakers.indices {
                if Self.nameKey(updated.speakers[i].name) == fromKey {
                    updated.speakers[i].name = target
                    changed = true
                }
            }
            if changed {
                upsert(updated)
                touched += 1
            }
        }
        return touched
    }

    /// Same normalization as `TalkTimeAggregator.nameKey`. Duplicated locally
    /// to keep `MeetingStore` decoupled from the Intelligence layer.
    private static func nameKey(_ name: String) -> String {
        name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
