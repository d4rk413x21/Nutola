import Foundation
import XCTest
@testable import Nutola

final class SwiftUICorrectnessTests: XCTestCase {
    func testClipboardExcludesAnotherMeetingAndKeepsSavedNames() {
        var meeting = Meeting(title: "Archived", createdAt: .now)
        meeting.speakers = [Speaker(id: "s1", name: "Alice")]
        let saved = [TranscriptSegment(speakerID: "s1", start: 0, end: 1, text: "Archived words")]
        let live = [TranscriptSegment(speakerID: LiveTranscriber.othersSpeakerID, start: 1, end: 2, text: "Other meeting")]
        let text = TranscriptFormatter.clipboardText(meeting: meeting, saved: saved, liveMeetingID: UUID(),
                                                     live: live, localName: "Current local", remoteName: "Current remote")
        XCTAssertTrue(text.contains("Alice"))
        XCTAssertTrue(text.contains("Archived words"))
        XCTAssertFalse(text.contains("Other meeting"))
        XCTAssertFalse(text.contains("Current"))
    }

    func testClipboardIncludesLiveAudioOnlyForTheSameMeeting() {
        let meeting = Meeting(title: "Live", createdAt: .now)
        let live = [TranscriptSegment(speakerID: LiveTranscriber.othersSpeakerID, start: 1, end: 2, text: "Live words")]
        let text = TranscriptFormatter.clipboardText(meeting: meeting, saved: [], liveMeetingID: meeting.id,
                                                     live: live, localName: "Local", remoteName: "Bob")
        XCTAssertTrue(text.contains("Bob"))
        XCTAssertTrue(text.contains("Live words"))
    }

    func testCancelledAnswerCannotUpdateOrRemoveItsReplacement() {
        var chat = AskConversation()
        let old = chat.beginResponse()
        chat.cancelResponse(old)
        let current = chat.beginResponse()
        XCTAssertFalse(chat.updateResponse(old, text: "Old answer"))
        XCTAssertFalse(chat.cancelResponse(old))
        XCTAssertTrue(chat.isAnswering)
        XCTAssertTrue(chat.updateResponse(current, text: "Correct answer", finished: true))
        XCTAssertFalse(chat.isAnswering)
        XCTAssertEqual(chat.messages.map(\.text), ["Correct answer"])
    }

    func testQueuedStreamUpdateCannotOverwriteAFinalAnswer() {
        var chat = AskConversation()
        let id = chat.beginResponse()
        chat.updateResponse(id, text: "Final", finished: true)
        XCTAssertFalse(chat.updateResponse(id, text: "Late partial"))
        XCTAssertEqual(chat.messages.first?.text, "Final")
    }

    func testOldDownloadCannotFinishOrUpdateTheNewOne() {
        var download = ModelDownloadProgress()
        let old = download.start()
        download.cancel()
        let current = download.start()
        download.update(old, fraction: 1)
        XCTAssertEqual(download.progress, 0)
        XCTAssertFalse(download.finish(old))
        XCTAssertTrue(download.isRunning)
        download.update(current, fraction: 0.4)
        XCTAssertEqual(download.progress, 0.4)
        XCTAssertTrue(download.finish(current))
        XCTAssertFalse(download.isRunning)
    }

    func testDownloadProgressIsMonotonicBoundedAndFinite() {
        var download = ModelDownloadProgress()
        let id = download.start()
        download.update(id, fraction: 0.6)
        download.update(id, fraction: 0.2)
        download.update(id, fraction: .nan)
        XCTAssertEqual(download.progress, 0.6)
        download.update(id, fraction: 2)
        XCTAssertEqual(download.progress, 1)
    }

    @MainActor
    func testInvalidEditorBlocksSavingUntilCorrected() {
        let edits = UnsavedEdits()
        var dirty = true
        var valid = false
        edits.register(UUID(), entry: .init(isDirty: { dirty }, save: {
            guard valid else { return false }
            dirty = false
            return true
        }, discard: { dirty = false }))
        XCTAssertTrue(edits.hasChanges)
        XCTAssertFalse(edits.saveAll())
        XCTAssertTrue(edits.hasChanges)
        valid = true
        XCTAssertTrue(edits.saveAll())
        XCTAssertFalse(edits.hasChanges)
    }

    @MainActor
    func testDiscardAndUnregistrationReleaseUnsavedEditors() {
        let edits = UnsavedEdits()
        let id = UUID()
        var text = "Changed"
        edits.register(id, entry: .init(isDirty: { text != "Original" }, save: { false }, discard: { text = "Original" }))
        edits.discardAll()
        XCTAssertEqual(text, "Original")
        XCTAssertFalse(edits.hasChanges)
        text = "Changed again"
        XCTAssertTrue(edits.hasChanges)
        edits.remove(id)
        XCTAssertFalse(edits.hasChanges)
    }

    func testPublishingPreflightRejectsAChangedOrMissingTranscript() throws {
        var transcript = [TranscriptSegment(speakerID: "s1", start: 0, end: 1, text: "Original")]
        let review = DevelopmentTaskReview(transcriptFingerprint: try DevelopmentTaskReview.fingerprint(transcript))
        XCTAssertNoThrow(try review.validateTranscript(transcript))
        transcript[0].text = "Updated after opening the panel"
        XCTAssertThrowsError(try review.validateTranscript(transcript))
        XCTAssertThrowsError(try review.validateTranscript([]))
    }

    func testAnonymousVoicesRemainScopedToTheirMeetings() {
        let first = Meeting(title: "First", createdAt: .now)
        let second = Meeting(title: "Second", createdAt: .now)
        let speakers = [Speaker(id: "s1", name: "Speaker 1")]
        let segments = [TranscriptSegment(speakerID: "s1", start: 0, end: 5, text: "Words")]
        let summaries = TalkTimeAggregator.aggregate(meetings: [first, second],
            transcripts: [(first.id, segments), (second.id, segments)],
            speakers: [(first.id, speakers), (second.id, speakers)])
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(Set(summaries.compactMap(\.meetingID)), [first.id, second.id])
        XCTAssertTrue(summaries.allSatisfy { $0.meetingCount == 1 && $0.localSpeakerID == "s1" })
    }

    func testTwoSpeakerIDsWithTheSameNameCountAsOneMeeting() throws {
        let meeting = Meeting(title: "One meeting", createdAt: .now)
        let speakers = [Speaker(id: "s1", name: "Alice"), Speaker(id: "s2", name: "Alice")]
        let segments = [TranscriptSegment(speakerID: "s1", start: 0, end: 5, text: "One"),
                        TranscriptSegment(speakerID: "s2", start: 5, end: 10, text: "Two")]
        let summary = try XCTUnwrap(TalkTimeAggregator.aggregate(meetings: [meeting],
            transcripts: [(meeting.id, segments)], speakers: [(meeting.id, speakers)]).first)
        XCTAssertEqual(summary.meetingCount, 1)
        XCTAssertEqual(summary.avgTalkTimePerMeeting, 10)
    }

    @MainActor
    func testAnonymousRenameChangesOnlyTheSelectedMeeting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nutola-rename-\(UUID())")
        defer { FilePersistence.discard(in: root); try? FileManager.default.removeItem(at: root) }
        let archive = MeetingArchive(root: root)
        let store = MeetingStore(archive: archive)
        var first = Meeting(title: "First", createdAt: .now)
        first.speakers = [Speaker(id: "s1", name: "Speaker 1")]
        var second = Meeting(title: "Second", createdAt: .now)
        second.speakers = first.speakers
        for meeting in [first, second] { try archive.createFolder(for: meeting.id); store.upsert(meeting) }
        XCTAssertEqual(store.bulkRenameSpeakers(from: "Speaker 1", to: "Alice"), 0)
        store.renameSpeaker(meetingID: first.id, speakerID: "s1", to: "Alice")
        XCTAssertEqual(store.meeting(id: first.id)?.speakers.first?.name, "Alice")
        XCTAssertEqual(store.meeting(id: second.id)?.speakers.first?.name, "Speaker 1")
    }

    func testLargeArchiveTalkTimeAggregation() {
        let meetings = (0..<100).map { Meeting(title: "Meeting \($0)", createdAt: .now) }
        let speakers = [Speaker(id: "named", name: "Alice"), Speaker(id: "s1", name: "Speaker 1")]
        let segments = (0..<1_000).map { index in
            TranscriptSegment(speakerID: index.isMultiple(of: 2) ? "named" : "s1",
                              start: Double(index), end: Double(index + 1), text: "Meeting words")
        }
        let transcripts = meetings.map { ($0.id, segments) }
        let people = meetings.map { ($0.id, speakers) }
        var summaries: [SpeakerTalkTimeSummary] = []
        measure {
            summaries = TalkTimeAggregator.aggregate(meetings: meetings, transcripts: transcripts, speakers: people)
        }
        XCTAssertEqual(summaries.count, 101)
        XCTAssertEqual(summaries.first(where: { $0.name == "Alice" })?.totalTalkTime, 50_000)
    }

    func testSummaryCacheHonorsExternalChangesAndPendingWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nutola-summary-cache-\(UUID())")
        defer { FilePersistence.discard(in: root); try? FileManager.default.removeItem(at: root) }
        let archive = MeetingArchive(root: root)
        let id = UUID()
        try archive.createFolder(for: id)
        try archive.saveSummary("Original", for: id)
        XCTAssertEqual(archive.summary(for: id), "Original")
        let file = archive.folder(for: id).appendingPathComponent("summary.md")
        try Data("External edit".utf8).write(to: file)
        XCTAssertEqual(archive.summary(for: id), "External edit")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try archive.saveSummary("Pending edit", for: id))
        XCTAssertEqual(archive.summary(for: id), "Pending edit")
        try FileManager.default.removeItem(at: file)
        FilePersistence.retryAll()
        XCTAssertEqual(archive.summary(for: id), "Pending edit")
    }
}
