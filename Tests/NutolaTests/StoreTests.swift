import Foundation
import Testing
@testable import Nutola

final class StoreTests {
    var tmp: URL!
    var archive: MeetingArchive!

    init() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-tests-\(UUID().uuidString)")
        archive = MeetingArchive(root: tmp)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmp)
    }

    func makeMeeting(title: String = "Standup") -> Meeting {
        // Whole-millisecond date so it survives the ISO8601 round-trip exactly.
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
        var m = Meeting(title: title, createdAt: now)
        m.speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Speaker 1"),
        ]
        m.state = .ready
        // save() refuses to (re)create the folder — start-of-recording owns that.
        try? archive.createFolder(for: m.id)
        return m
    }

    @Test func testSaveRefusesToResurrectDeletedMeeting() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.delete(id: m.id)
        // A late pipeline write must not recreate the deleted meeting on disk.
        #expect(throws: (any Error).self) { try archive.save(m) }
        #expect(archive.meeting(id: m.id) == nil)
    }

    @Test func testMeetingRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        #expect(archive.meeting(id: m.id) == m)
        #expect(archive.allMeetings() == [m])
    }

    @Test func testReadsExistingISODatesWithAndWithoutFractionalSeconds() throws {
        let meeting = makeMeeting()
        try archive.save(meeting)
        let file = archive.folder(for: meeting.id).appendingPathComponent("meeting.json")
        var data = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        for (text, expected) in [("2023-11-14T22:13:20.123Z", 1_700_000_000.123),
                                 ("2023-11-14T22:13:20Z", 1_700_000_000.0)] {
            data["createdAt"] = text
            try JSONSerialization.data(withJSONObject: data).write(to: file)
            let loaded = try #require(archive.meeting(id: meeting.id))
            #expect(abs((loaded.createdAt.timeIntervalSince1970) - (expected)) <= 0.001)
        }
    }

    @Test func testTranscriptRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 2.5, text: "Morning everyone."),
            TranscriptSegment(speakerID: "s1", start: 3, end: 6, text: "Hey! Ready to start?"),
        ]
        try archive.saveTranscript(segments, for: m.id)
        #expect(archive.transcript(for: m.id) == segments)
    }

    @Test func testDevelopmentDraftsRoundTripWithoutChangingMeetingNotes() throws {
        let meeting = makeMeeting()
        try archive.save(meeting)
        try archive.saveSummary("Existing notes", for: meeting.id)
        #expect(try archive.developmentTasks(for: meeting.id) == nil)
        let evidence = [TranscriptSegment(speakerID: "me", start: 2, end: 3, text: "Fix login.")]
        let review = DevelopmentTaskReview(
            transcriptFingerprint: try DevelopmentTaskReview.fingerprint(evidence),
            tasks: [DevelopmentTaskDraft(title: "Fix login", detail: "Handle expired tokens.", evidence: evidence)])
        try archive.saveDevelopmentTasks(review, for: meeting.id)
        #expect(try archive.developmentTasks(for: meeting.id) == review)
        #expect(archive.summary(for: meeting.id) == "Existing notes")
        #expect(archive.meeting(id: meeting.id) == meeting)
    }

    @Test func testStaleDevelopmentDraftWritesCannotEraseLinearCheckpoints() throws {
        let meeting = makeMeeting()
        try archive.save(meeting)
        let draft = DevelopmentTaskDraft(title: "Fix login", detail: "Handle expired tokens.", evidence: [])
        let original = DevelopmentTaskReview(tasks: [draft])
        try archive.saveDevelopmentTasks(original, for: meeting.id, replacing: DevelopmentTaskReview())
        var linked = original
        linked.tasks[0].linearExport = LinearIssueExport(id: draft.id, workspaceID: "workspace", teamID: "team",
            identifier: "DEV-12", url: URL(string: "https://linear.app/work/issue/DEV-12/task")!)
        try archive.saveDevelopmentTasks(linked, for: meeting.id, replacing: original)
        #expect(throws: (any Error).self) { try archive.saveDevelopmentTasks(original, for: meeting.id, replacing: original) }
        #expect(try archive.developmentTasks(for: meeting.id) == linked)
    }

    @Test func testDevelopmentDraftsCannotResurrectDeletedMeetings() throws {
        let meeting = makeMeeting()
        try archive.save(meeting)
        try archive.delete(id: meeting.id)
        #expect(throws: (any Error).self) { try archive.saveDevelopmentTasks(DevelopmentTaskReview(), for: meeting.id) }
        #expect(!(FileManager.default.fileExists(atPath: archive.folder(for: meeting.id).path)))
    }

    @Test func testCorruptDevelopmentDraftsAreReportedInsteadOfDiscarded() throws {
        let meeting = makeMeeting()
        try archive.save(meeting)
        let file = archive.folder(for: meeting.id).appendingPathComponent("development-tasks.json")
        try Data("invalid json".utf8).write(to: file)
        #expect(throws: (any Error).self) { try archive.developmentTasks(for: meeting.id) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "invalid json")
    }

    @Test func testSummaryRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("## TL;DR\nShipped it.", for: m.id)
        #expect(archive.summary(for: m.id) == "## TL;DR\nShipped it.")
    }

    // MARK: - Summary edit history

    @Test func testSaveSummarySnapshotsPreviousVersion() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        #expect(archive.summaryHistory(for: m.id) == [])
        // Overwriting with different content creates a snapshot of v1.
        try archive.saveSummary("v2", for: m.id)
        let history = archive.summaryHistory(for: m.id)
        #expect(history.count == 1)
        #expect(history[0].markdown == "v1")
        #expect(archive.summary(for: m.id) == "v2")
    }

    @Test func testSaveSummaryDoesNotSnapshotIdenticalContent() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("same", for: m.id)
        try archive.saveSummary("same", for: m.id)
        #expect(archive.summaryHistory(for: m.id) == [])
    }

    @Test func testSaveSummaryDoesNotSnapshotEmptyToContent() throws {
        let m = makeMeeting()
        try archive.save(m)
        // First write from empty → no snapshot (not an edit).
        try archive.saveSummary("first real summary", for: m.id)
        #expect(archive.summaryHistory(for: m.id) == [])
    }

    @Test func testHistoryIsNewestFirst() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        try archive.saveSummary("v2", for: m.id)
        try archive.saveSummary("v3", for: m.id)
        let history = archive.summaryHistory(for: m.id)
        #expect(history.count == 2)
        // Newest snapshot first: v2 was displaced by v3, v1 by v2.
        #expect(history[0].markdown == "v2")
        #expect(history[1].markdown == "v1")
    }

    @Test func testHistoryPrunesToMax() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v0", for: m.id)
        // Write more than maxSummaryHistory versions.
        for i in 1...(MeetingArchive.maxSummaryHistory + 5) {
            try archive.saveSummary("v\(i)", for: m.id)
        }
        let history = archive.summaryHistory(for: m.id)
        #expect(history.count == MeetingArchive.maxSummaryHistory)
    }

    @Test func testRestoreSummarySwapsCurrentAndIsReversible() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        try archive.saveSummary("v2", for: m.id)
        let v1Snapshot = archive.summaryHistory(for: m.id).first { $0.markdown == "v1" }!
        // Restore v1: current "v2" becomes a snapshot, summary becomes v1.
        #expect(archive.restoreSummary(at: v1Snapshot.timestamp, for: m.id))
        #expect(archive.summary(for: m.id) == "v1")
        // v2 is now in history, so the restore is reversible.
        let v2Snapshot = archive.summaryHistory(for: m.id).first { $0.markdown == "v2" }!
        #expect(archive.restoreSummary(at: v2Snapshot.timestamp, for: m.id))
        #expect(archive.summary(for: m.id) == "v2")
    }

    @Test func testRestoreSummaryUnknownTimestampFails() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        #expect(!(archive.restoreSummary(at: Date(timeIntervalSince1970: 0), for: m.id)))
    }

    @Test func testSummaryTimestampsAdvancePastSavedHistoryAfterReopening() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        let edits = archive.folder(for: m.id).appendingPathComponent("Edits", isDirectory: true)
        try FileManager.default.createDirectory(at: edits, withIntermediateDirectories: true)
        // A persisted timestamp ahead of the clock makes collisions deterministic.
        let futureMS: Int64 = 4_102_444_800_000
        try Data("v0".utf8).write(to: edits.appendingPathComponent("summary-\(futureMS)-AAAA.md"))
        try archive.saveSummary("v2", for: m.id)
        #expect(archive.summaryHistory(for: m.id).first?.markdown == "v1")

        archive = MeetingArchive(root: tmp)
        try archive.saveSummary("v3", for: m.id)
        let history = archive.summaryHistory(for: m.id)
        #expect(history.map(\.markdown) == ["v2", "v1", "v0"])
        #expect(Set(history.map(\.timestamp)).count == history.count)
        #expect(try #require(history.first).timestamp.timeIntervalSince1970 > TimeInterval(futureMS) / 1000)
        let v1 = try #require(history.first { $0.markdown == "v1" })
        #expect(archive.restoreSummary(at: v1.timestamp, for: m.id))
        #expect(archive.summary(for: m.id) == "v1")
        let v3 = try #require(archive.summaryHistory(for: m.id).first { $0.markdown == "v3" })
        #expect(archive.restoreSummary(at: v3.timestamp, for: m.id))
        #expect(archive.summary(for: m.id) == "v3")
    }

    @Test func testDeleteMeetingRemovesHistory() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        try archive.saveSummary("v2", for: m.id)
        #expect(!(archive.summaryHistory(for: m.id).isEmpty))
        try archive.delete(id: m.id)
        #expect(archive.summaryHistory(for: m.id) == [])
    }

    @Test func testSideNotesRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSideNotes("- Action: follow up with design\n- Blocker: API latency", for: m.id)
        #expect(archive.sideNotes(for: m.id) == "- Action: follow up with design\n- Blocker: API latency")
        #expect(archive.summary(for: m.id) == "")
    }

    @Test func testDelete() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.delete(id: m.id)
        #expect(archive.meeting(id: m.id) == nil)
        #expect(archive.allMeetings() == [])
    }

    @Test func testSearchRanksTitleAboveTranscript() throws {
        let titled = makeMeeting(title: "Budget review")
        try archive.save(titled)
        var other = makeMeeting(title: "Standup")
        other.createdAt = Date(timeIntervalSinceNow: -60)
        try archive.save(other)
        try archive.saveTranscript(
            [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "We touched on the budget briefly.")],
            for: other.id
        )
        let hits = archive.search("budget")
        #expect(hits.count == 2)
        #expect(hits[0].meeting.id == titled.id)
        #expect(hits[1].meeting.id == other.id)
        #expect(hits[1].excerpts[0].contains("Me @ 0:00"))
    }

    @Test func testSearchSkipsTranscriptDecodeForNonMatchingMeetings() throws {
        // A meeting whose transcript can't contain the query word should still
        // be scored correctly (0 from transcript) and skipped at the JSON-decode
        // level — the pre-filter must not suppress title/summary/attendee hits.
        let m = makeMeeting(title: "Sprint planning")
        try archive.save(m)
        try archive.saveTranscript(
            [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Completely unrelated content about weather.")],
            for: m.id
        )
        // Title match only — transcript pre-filter skips the decode, score comes from title.
        let hits = archive.search("sprint")
        #expect(hits.count == 1)
        #expect(hits[0].meeting.id == m.id)
        #expect(hits[0].score == 10) // title only, no transcript contribution
    }

    @Test func testSearchPreFilterStillFindsTranscriptMatches() throws {
        // Verify the pre-filter doesn't false-negative on real transcript hits.
        let m = makeMeeting(title: "Random title")
        try archive.save(m)
        try archive.saveTranscript(
            [TranscriptSegment(speakerID: "me", start: 10, end: 12, text: "We need to discuss the migration plan.")],
            for: m.id
        )
        let hits = archive.search("migration")
        #expect(hits.count == 1)
        #expect(hits[0].excerpts.contains(where: { $0.contains("migration") }))
    }

    @Test func testSearchNoResults() {
        #expect(archive.search("zebra").isEmpty)
        #expect(archive.search("   ").isEmpty)
    }

    // MARK: - Error paths (#76, #78)

    @Test func testSaveSummaryThrowsWhenFolderDeleted() throws {
        // A late pipeline write to a meeting the user deleted mid-run must
        // surface the failure (the folder is gone) instead of silently recreating it.
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("first", for: m.id)
        try archive.delete(id: m.id)
        #expect(throws: (any Error).self) { try archive.saveSummary("second", for: m.id) }
        #expect(archive.summary(for: m.id) == "")
    }

    @Test func testDeleteWhenFolderMissing() throws {
        // delete(id:) must not throw when the meeting folder was already removed
        // (e.g. user trashed it from Finder). Removing twice should be idempotent.
        let m = makeMeeting()
        try archive.save(m)
        try archive.delete(id: m.id)
        #expect(archive.meeting(id: m.id) == nil)
        // Second delete — folder is already gone.
        #expect(throws: Never.self) { try archive.delete(id: m.id) }
    }

    // MARK: - Unicode / emoji round-trip (#77)

    @Test func testSummaryRoundTripUnicode() throws {
        let m = makeMeeting()
        try archive.save(m)
        // Emoji + combining marks + non-BMP (U+1F600) + CJK + RTL Hebrew.
        let unicode = "## 🎉 Q4 review — café naïve — שָׁלוֹם — 日本語"
        try archive.saveSummary(unicode, for: m.id)
        #expect(archive.summary(for: m.id) == unicode)
    }

    // MARK: - Sorting (#79)

    @Test func testAllMeetingsSortedDescending() throws {
        // allMeetings() returns newest createdAt first (descending).
        var oldest = makeMeeting()
        oldest.createdAt = Date(timeIntervalSince1970: 1_000)
        try archive.save(oldest)
        var middle = makeMeeting()
        middle.createdAt = Date(timeIntervalSince1970: 2_000)
        try archive.save(middle)
        var newest = makeMeeting()
        newest.createdAt = Date(timeIntervalSince1970: 3_000)
        try archive.save(newest)
        let all = archive.allMeetings()
        #expect(all.count == 3)
        #expect(all.map(\.id) == [newest.id, middle.id, oldest.id])
    }

    // MARK: - Search edge cases (#80)

    @Test func testSearchWithEmptyQuery() {
        // An empty query has no words to match — returns no hits rather than
        // matching every meeting.
        let m = makeMeeting(title: "Standup")
        try? archive.save(m)
        #expect(archive.search("").isEmpty)
    }

    @Test func testSearchWithWhitespaceQuery() {
        // Whitespace-only collapses to no words, same as empty.
        let m = makeMeeting(title: "Standup")
        try? archive.save(m)
        #expect(archive.search("   \t  ").isEmpty)
        #expect(archive.search("\n\n").isEmpty)
    }

    // MARK: - Zoom roster (#90)

    @Test func testZoomRosterRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        let roster = ["Alice Rivera", "Bob Chen", "桂 太郎"]
        archive.saveZoomRoster(roster, for: m.id)
        #expect(archive.zoomRoster(for: m.id) == roster)
        // Empty roster round-trips too (writes an empty array, not a deletion).
        archive.saveZoomRoster([], for: m.id)
        #expect(archive.zoomRoster(for: m.id) == [])
    }

    // MARK: - bulkRenameSpeakers (cross-meeting rename / merge)

    @MainActor
    @Test func testBulkRenameAcrossMeetings() throws {
        let store = MeetingStore(archive: archive)
        var m1 = makeMeeting(title: "M1")
        var m2 = makeMeeting(title: "M2")
        // Both meetings have a "Gui Lima" speaker (with different IDs, mirroring
        // SpeakerLabeler's per-meeting reset).
        m1.speakers = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Gui Lima")]
        m2.speakers = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s2", name: "Gui Lima")]
        try archive.save(m1)
        try archive.save(m2)
        store.reload()

        let touched = store.bulkRenameSpeakers(from: "Gui Lima", to: "Guilherme Lima")
        #expect(touched == 2)
        let after1 = store.meeting(id: m1.id)!
        let after2 = store.meeting(id: m2.id)!
        #expect(after1.speakers.first { $0.id == "s1" }?.name == "Guilherme Lima")
        #expect(after2.speakers.first { $0.id == "s2" }?.name == "Guilherme Lima")
    }

    @MainActor
    @Test func testBulkRenameIsCaseInsensitiveAndWhitespaceTolerant() throws {
        let store = MeetingStore(archive: archive)
        var m1 = makeMeeting(title: "M1")
        m1.speakers = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Gui  Lima ")]
        try archive.save(m1)
        store.reload()

        let touched = store.bulkRenameSpeakers(from: "gui lima", to: "Guilherme Lima")
        #expect(touched == 1)
        #expect(store.meeting(id: m1.id)!.speakers.first { $0.id == "s1" }?.name == "Guilherme Lima")
    }

    @MainActor
    @Test func testBulkRenameNoOpForSameName() throws {
        let store = MeetingStore(archive: archive)
        var m1 = makeMeeting(title: "M1")
        m1.speakers = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Alice")]
        try archive.save(m1)
        store.reload()

        // "alice" → "Alice" should still rename (different display strings).
        #expect(store.bulkRenameSpeakers(from: "alice", to: "Alice") == 1)
        // "Alice" → "Alice" should be a no-op.
        #expect(store.bulkRenameSpeakers(from: "Alice", to: "Alice") == 0)
    }

    @MainActor
    @Test func testBulkRenameOnlyTouchesMatchingMeetings() throws {
        let store = MeetingStore(archive: archive)
        var m1 = makeMeeting(title: "M1")
        var m2 = makeMeeting(title: "M2")
        m1.speakers = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Bob")]
        m2.speakers = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Carol")]
        try archive.save(m1)
        try archive.save(m2)
        store.reload()

        let touched = store.bulkRenameSpeakers(from: "Bob", to: "Robert")
        #expect(touched == 1)
        #expect(store.meeting(id: m1.id)!.speakers.first { $0.id == "s1" }?.name == "Robert")
        // M2 untouched.
        #expect(store.meeting(id: m2.id)!.speakers.first { $0.id == "s1" }?.name == "Carol")
    }
}
