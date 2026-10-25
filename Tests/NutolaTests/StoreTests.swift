import XCTest
@testable import Nutola

final class StoreTests: XCTestCase {
    var tmp: URL!
    var archive: MeetingArchive!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-tests-\(UUID().uuidString)")
        archive = MeetingArchive(root: tmp)
    }

    override func tearDown() {
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

    func testSaveRefusesToResurrectDeletedMeeting() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.delete(id: m.id)
        // A late pipeline write must not recreate the deleted meeting on disk.
        XCTAssertThrowsError(try archive.save(m))
        XCTAssertNil(archive.meeting(id: m.id))
    }

    func testMeetingRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        XCTAssertEqual(archive.meeting(id: m.id), m)
        XCTAssertEqual(archive.allMeetings(), [m])
    }

    func testTranscriptRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 2.5, text: "Morning everyone."),
            TranscriptSegment(speakerID: "s1", start: 3, end: 6, text: "Hey! Ready to start?"),
        ]
        try archive.saveTranscript(segments, for: m.id)
        XCTAssertEqual(archive.transcript(for: m.id), segments)
    }

    func testDevelopmentDraftsRoundTripWithoutChangingMeetingNotes() throws {
        let meeting = makeMeeting()
        try archive.save(meeting)
        try archive.saveSummary("Existing notes", for: meeting.id)
        XCTAssertNil(try archive.developmentTasks(for: meeting.id))
        let evidence = [TranscriptSegment(speakerID: "me", start: 2, end: 3, text: "Fix login.")]
        let review = DevelopmentTaskReview(
            transcriptFingerprint: try DevelopmentTaskReview.fingerprint(evidence),
            tasks: [DevelopmentTaskDraft(title: "Fix login", detail: "Handle expired tokens.", evidence: evidence)])
        try archive.saveDevelopmentTasks(review, for: meeting.id)
        XCTAssertEqual(try archive.developmentTasks(for: meeting.id), review)
        XCTAssertEqual(archive.summary(for: meeting.id), "Existing notes")
        XCTAssertEqual(archive.meeting(id: meeting.id), meeting)
    }

    func testStaleDevelopmentDraftWritesCannotEraseLinearCheckpoints() throws {
        let meeting = makeMeeting()
        try archive.save(meeting)
        let draft = DevelopmentTaskDraft(title: "Fix login", detail: "Handle expired tokens.", evidence: [])
        let original = DevelopmentTaskReview(tasks: [draft])
        try archive.saveDevelopmentTasks(original, for: meeting.id, replacing: DevelopmentTaskReview())
        var linked = original
        linked.tasks[0].linearExport = LinearIssueExport(id: draft.id, workspaceID: "workspace", teamID: "team",
            identifier: "DEV-12", url: URL(string: "https://linear.app/work/issue/DEV-12/task")!)
        try archive.saveDevelopmentTasks(linked, for: meeting.id, replacing: original)
        XCTAssertThrowsError(try archive.saveDevelopmentTasks(original, for: meeting.id, replacing: original))
        XCTAssertEqual(try archive.developmentTasks(for: meeting.id), linked)
    }

    func testDevelopmentDraftsCannotResurrectDeletedMeetings() throws {
        let meeting = makeMeeting()
        try archive.save(meeting)
        try archive.delete(id: meeting.id)
        XCTAssertThrowsError(try archive.saveDevelopmentTasks(DevelopmentTaskReview(), for: meeting.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.folder(for: meeting.id).path))
    }

    func testCorruptDevelopmentDraftsAreReportedInsteadOfDiscarded() throws {
        let meeting = makeMeeting()
        try archive.save(meeting)
        let file = archive.folder(for: meeting.id).appendingPathComponent("development-tasks.json")
        try Data("invalid json".utf8).write(to: file)
        XCTAssertThrowsError(try archive.developmentTasks(for: meeting.id))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "invalid json")
    }

    func testSummaryRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("## TL;DR\nShipped it.", for: m.id)
        XCTAssertEqual(archive.summary(for: m.id), "## TL;DR\nShipped it.")
    }

    // MARK: - Summary edit history

    func testSaveSummarySnapshotsPreviousVersion() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        XCTAssertEqual(archive.summaryHistory(for: m.id), [])
        // Overwriting with different content creates a snapshot of v1.
        try archive.saveSummary("v2", for: m.id)
        let history = archive.summaryHistory(for: m.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].markdown, "v1")
        XCTAssertEqual(archive.summary(for: m.id), "v2")
    }

    func testSaveSummaryDoesNotSnapshotIdenticalContent() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("same", for: m.id)
        try archive.saveSummary("same", for: m.id)
        XCTAssertEqual(archive.summaryHistory(for: m.id), [])
    }

    func testSaveSummaryDoesNotSnapshotEmptyToContent() throws {
        let m = makeMeeting()
        try archive.save(m)
        // First write from empty → no snapshot (not an edit).
        try archive.saveSummary("first real summary", for: m.id)
        XCTAssertEqual(archive.summaryHistory(for: m.id), [])
    }

    func testHistoryIsNewestFirst() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        try archive.saveSummary("v2", for: m.id)
        try archive.saveSummary("v3", for: m.id)
        let history = archive.summaryHistory(for: m.id)
        XCTAssertEqual(history.count, 2)
        // Newest snapshot first: v2 was displaced by v3, v1 by v2.
        XCTAssertEqual(history[0].markdown, "v2")
        XCTAssertEqual(history[1].markdown, "v1")
    }

    func testHistoryPrunesToMax() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v0", for: m.id)
        // Write more than maxSummaryHistory versions.
        for i in 1...(MeetingArchive.maxSummaryHistory + 5) {
            try archive.saveSummary("v\(i)", for: m.id)
        }
        let history = archive.summaryHistory(for: m.id)
        XCTAssertEqual(history.count, MeetingArchive.maxSummaryHistory)
    }

    func testRestoreSummarySwapsCurrentAndIsReversible() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        try archive.saveSummary("v2", for: m.id)
        let v1Snapshot = archive.summaryHistory(for: m.id).first { $0.markdown == "v1" }!
        // Restore v1: current "v2" becomes a snapshot, summary becomes v1.
        XCTAssertTrue(archive.restoreSummary(at: v1Snapshot.timestamp, for: m.id))
        XCTAssertEqual(archive.summary(for: m.id), "v1")
        // v2 is now in history, so the restore is reversible.
        let v2Snapshot = archive.summaryHistory(for: m.id).first { $0.markdown == "v2" }!
        XCTAssertTrue(archive.restoreSummary(at: v2Snapshot.timestamp, for: m.id))
        XCTAssertEqual(archive.summary(for: m.id), "v2")
    }

    func testRestoreSummaryUnknownTimestampFails() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        XCTAssertFalse(archive.restoreSummary(at: Date(timeIntervalSince1970: 0), for: m.id))
    }

    func testSummaryTimestampsAdvancePastSavedHistoryAfterReopening() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        let edits = archive.folder(for: m.id).appendingPathComponent("Edits", isDirectory: true)
        try FileManager.default.createDirectory(at: edits, withIntermediateDirectories: true)
        // A persisted timestamp ahead of the clock makes collisions deterministic.
        let futureMS: Int64 = 4_102_444_800_000
        try Data("v0".utf8).write(to: edits.appendingPathComponent("summary-\(futureMS)-AAAA.md"))
        try archive.saveSummary("v2", for: m.id)
        XCTAssertEqual(archive.summaryHistory(for: m.id).first?.markdown, "v1")

        archive = MeetingArchive(root: tmp)
        try archive.saveSummary("v3", for: m.id)
        let history = archive.summaryHistory(for: m.id)
        XCTAssertEqual(history.map(\.markdown), ["v2", "v1", "v0"])
        XCTAssertEqual(Set(history.map(\.timestamp)).count, history.count)
        XCTAssertGreaterThan(try XCTUnwrap(history.first).timestamp.timeIntervalSince1970,
                             TimeInterval(futureMS) / 1000)
        let v1 = try XCTUnwrap(history.first { $0.markdown == "v1" })
        XCTAssertTrue(archive.restoreSummary(at: v1.timestamp, for: m.id))
        XCTAssertEqual(archive.summary(for: m.id), "v1")
        let v3 = try XCTUnwrap(archive.summaryHistory(for: m.id).first { $0.markdown == "v3" })
        XCTAssertTrue(archive.restoreSummary(at: v3.timestamp, for: m.id))
        XCTAssertEqual(archive.summary(for: m.id), "v3")
    }

    func testDeleteMeetingRemovesHistory() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        try archive.saveSummary("v2", for: m.id)
        XCTAssertFalse(archive.summaryHistory(for: m.id).isEmpty)
        try archive.delete(id: m.id)
        XCTAssertEqual(archive.summaryHistory(for: m.id), [])
    }

    func testSideNotesRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSideNotes("- Action: follow up with design\n- Blocker: API latency", for: m.id)
        XCTAssertEqual(archive.sideNotes(for: m.id), "- Action: follow up with design\n- Blocker: API latency")
        XCTAssertEqual(archive.summary(for: m.id), "")
    }

    func testDelete() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.delete(id: m.id)
        XCTAssertNil(archive.meeting(id: m.id))
        XCTAssertEqual(archive.allMeetings(), [])
    }

    func testSearchRanksTitleAboveTranscript() throws {
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
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].meeting.id, titled.id)
        XCTAssertEqual(hits[1].meeting.id, other.id)
        XCTAssertTrue(hits[1].excerpts[0].contains("Me @ 0:00"))
    }

    func testSearchSkipsTranscriptDecodeForNonMatchingMeetings() throws {
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
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].meeting.id, m.id)
        XCTAssertEqual(hits[0].score, 10) // title only, no transcript contribution
    }

    func testSearchPreFilterStillFindsTranscriptMatches() throws {
        // Verify the pre-filter doesn't false-negative on real transcript hits.
        let m = makeMeeting(title: "Random title")
        try archive.save(m)
        try archive.saveTranscript(
            [TranscriptSegment(speakerID: "me", start: 10, end: 12, text: "We need to discuss the migration plan.")],
            for: m.id
        )
        let hits = archive.search("migration")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].excerpts.contains(where: { $0.contains("migration") }))
    }

    func testSearchNoResults() {
        XCTAssertTrue(archive.search("zebra").isEmpty)
        XCTAssertTrue(archive.search("   ").isEmpty)
    }

    // MARK: - Error paths (#76, #78)

    func testSaveSummaryThrowsWhenFolderDeleted() throws {
        // A late pipeline write to a meeting the user deleted mid-run must
        // surface the failure (the folder is gone) instead of silently recreating it.
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("first", for: m.id)
        try archive.delete(id: m.id)
        XCTAssertThrowsError(try archive.saveSummary("second", for: m.id))
        XCTAssertEqual(archive.summary(for: m.id), "")
    }

    func testDeleteWhenFolderMissing() throws {
        // delete(id:) must not throw when the meeting folder was already removed
        // (e.g. user trashed it from Finder). Removing twice should be idempotent.
        let m = makeMeeting()
        try archive.save(m)
        try archive.delete(id: m.id)
        XCTAssertNil(archive.meeting(id: m.id))
        // Second delete — folder is already gone.
        XCTAssertNoThrow(try archive.delete(id: m.id))
    }

    // MARK: - Unicode / emoji round-trip (#77)

    func testSummaryRoundTripUnicode() throws {
        let m = makeMeeting()
        try archive.save(m)
        // Emoji + combining marks + non-BMP (U+1F600) + CJK + RTL Hebrew.
        let unicode = "## 🎉 Q4 review — café naïve — שָׁלוֹם — 日本語"
        try archive.saveSummary(unicode, for: m.id)
        XCTAssertEqual(archive.summary(for: m.id), unicode)
    }

    // MARK: - Sorting (#79)

    func testAllMeetingsSortedDescending() throws {
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
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map(\.id), [newest.id, middle.id, oldest.id])
    }

    // MARK: - Search edge cases (#80)

    func testSearchWithEmptyQuery() {
        // An empty query has no words to match — returns no hits rather than
        // matching every meeting.
        let m = makeMeeting(title: "Standup")
        try? archive.save(m)
        XCTAssertTrue(archive.search("").isEmpty)
    }

    func testSearchWithWhitespaceQuery() {
        // Whitespace-only collapses to no words, same as empty.
        let m = makeMeeting(title: "Standup")
        try? archive.save(m)
        XCTAssertTrue(archive.search("   \t  ").isEmpty)
        XCTAssertTrue(archive.search("\n\n").isEmpty)
    }

    // MARK: - Zoom roster (#90)

    func testZoomRosterRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        let roster = ["Alice Rivera", "Bob Chen", "桂 太郎"]
        archive.saveZoomRoster(roster, for: m.id)
        XCTAssertEqual(archive.zoomRoster(for: m.id), roster)
        // Empty roster round-trips too (writes an empty array, not a deletion).
        archive.saveZoomRoster([], for: m.id)
        XCTAssertEqual(archive.zoomRoster(for: m.id), [])
    }

    // MARK: - bulkRenameSpeakers (cross-meeting rename / merge)

    @MainActor
    func testBulkRenameAcrossMeetings() throws {
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
        XCTAssertEqual(touched, 2)
        let after1 = store.meeting(id: m1.id)!
        let after2 = store.meeting(id: m2.id)!
        XCTAssertEqual(after1.speakers.first { $0.id == "s1" }?.name, "Guilherme Lima")
        XCTAssertEqual(after2.speakers.first { $0.id == "s2" }?.name, "Guilherme Lima")
    }

    @MainActor
    func testBulkRenameIsCaseInsensitiveAndWhitespaceTolerant() throws {
        let store = MeetingStore(archive: archive)
        var m1 = makeMeeting(title: "M1")
        m1.speakers = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Gui  Lima ")]
        try archive.save(m1)
        store.reload()

        let touched = store.bulkRenameSpeakers(from: "gui lima", to: "Guilherme Lima")
        XCTAssertEqual(touched, 1)
        XCTAssertEqual(store.meeting(id: m1.id)!.speakers.first { $0.id == "s1" }?.name, "Guilherme Lima")
    }

    @MainActor
    func testBulkRenameNoOpForSameName() throws {
        let store = MeetingStore(archive: archive)
        var m1 = makeMeeting(title: "M1")
        m1.speakers = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Alice")]
        try archive.save(m1)
        store.reload()

        // "alice" → "Alice" should still rename (different display strings).
        XCTAssertEqual(store.bulkRenameSpeakers(from: "alice", to: "Alice"), 1)
        // "Alice" → "Alice" should be a no-op.
        XCTAssertEqual(store.bulkRenameSpeakers(from: "Alice", to: "Alice"), 0)
    }

    @MainActor
    func testBulkRenameOnlyTouchesMatchingMeetings() throws {
        let store = MeetingStore(archive: archive)
        var m1 = makeMeeting(title: "M1")
        var m2 = makeMeeting(title: "M2")
        m1.speakers = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Bob")]
        m2.speakers = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Carol")]
        try archive.save(m1)
        try archive.save(m2)
        store.reload()

        let touched = store.bulkRenameSpeakers(from: "Bob", to: "Robert")
        XCTAssertEqual(touched, 1)
        XCTAssertEqual(store.meeting(id: m1.id)!.speakers.first { $0.id == "s1" }?.name, "Robert")
        // M2 untouched.
        XCTAssertEqual(store.meeting(id: m2.id)!.speakers.first { $0.id == "s1" }?.name, "Carol")
    }
}
