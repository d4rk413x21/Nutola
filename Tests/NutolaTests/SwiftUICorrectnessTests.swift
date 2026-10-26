import Foundation
import Testing
@testable import Nutola

extension SharedStateTests {
    struct SwiftUICorrectnessTests {
        @Test func testClipboardExcludesAnotherMeetingAndKeepsSavedNames() {
            var meeting = Meeting(title: "Archived", createdAt: .now)
            meeting.speakers = [Speaker(id: "s1", name: "Alice")]
            let saved = [TranscriptSegment(speakerID: "s1", start: 0, end: 1, text: "Archived words")]
            let live = [TranscriptSegment(speakerID: LiveTranscriber.othersSpeakerID, start: 1, end: 2, text: "Other meeting")]
            let text = TranscriptFormatter.clipboardText(meeting: meeting, saved: saved, liveMeetingID: UUID(),
                                                         live: live, localName: "Current local", remoteName: "Current remote")
            #expect(text.contains("Alice"))
            #expect(text.contains("Archived words"))
            #expect(!(text.contains("Other meeting")))
            #expect(!(text.contains("Current")))
        }

        @Test func testClipboardIncludesLiveAudioOnlyForTheSameMeeting() {
            let meeting = Meeting(title: "Live", createdAt: .now)
            let live = [TranscriptSegment(speakerID: LiveTranscriber.othersSpeakerID, start: 1, end: 2, text: "Live words")]
            let text = TranscriptFormatter.clipboardText(meeting: meeting, saved: [], liveMeetingID: meeting.id,
                                                         live: live, localName: "Local", remoteName: "Bob")
            #expect(text.contains("Bob"))
            #expect(text.contains("Live words"))
        }

        @Test func testCancelledAnswerCannotUpdateOrRemoveItsReplacement() {
            var chat = AskConversation()
            let old = chat.beginResponse()
            chat.cancelResponse(old)
            let current = chat.beginResponse()
            let updatedOld = chat.updateResponse(old, text: "Old answer")
            #expect(!updatedOld)
            let cancelledOld = chat.cancelResponse(old)
            #expect(!cancelledOld)
            #expect(chat.isAnswering)
            let updatedCurrent = chat.updateResponse(current, text: "Correct answer", finished: true)
            #expect(updatedCurrent)
            #expect(!(chat.isAnswering))
            #expect(chat.messages.map(\.text) == ["Correct answer"])
        }

        @Test func testQueuedStreamUpdateCannotOverwriteAFinalAnswer() {
            var chat = AskConversation()
            let id = chat.beginResponse()
            chat.updateResponse(id, text: "Final", finished: true)
            let accepted = chat.updateResponse(id, text: "Late partial")
            #expect(!accepted)
            #expect(chat.messages.first?.text == "Final")
        }

        @Test func testOldDownloadCannotFinishOrUpdateTheNewOne() {
            var download = ModelDownloadProgress()
            let old = download.start()
            download.cancel()
            let current = download.start()
            download.update(old, fraction: 1)
            #expect(download.progress == 0)
            let finishedOld = download.finish(old)
            #expect(!finishedOld)
            #expect(download.isRunning)
            download.update(current, fraction: 0.4)
            #expect(download.progress == 0.4)
            let finishedCurrent = download.finish(current)
            #expect(finishedCurrent)
            #expect(!(download.isRunning))
        }

        @Test func testDownloadProgressIsMonotonicBoundedAndFinite() {
            var download = ModelDownloadProgress()
            let id = download.start()
            download.update(id, fraction: 0.6)
            download.update(id, fraction: 0.2)
            download.update(id, fraction: .nan)
            #expect(download.progress == 0.6)
            download.update(id, fraction: 2)
            #expect(download.progress == 1)
        }

        @MainActor
        @Test func testInvalidEditorBlocksSavingUntilCorrected() {
            let edits = UnsavedEdits()
            var dirty = true
            var valid = false
            edits.register(UUID(), entry: .init(isDirty: { dirty }, save: {
                guard valid else { return false }
                dirty = false
                return true
            }, discard: { dirty = false }))
            #expect(edits.hasChanges)
            #expect(!(edits.saveAll()))
            #expect(edits.hasChanges)
            valid = true
            #expect(edits.saveAll())
            #expect(!(edits.hasChanges))
        }

        @MainActor
        @Test func testDiscardAndUnregistrationReleaseUnsavedEditors() {
            let edits = UnsavedEdits()
            let id = UUID()
            var text = "Changed"
            edits.register(id, entry: .init(isDirty: { text != "Original" }, save: { false }, discard: { text = "Original" }))
            edits.discardAll()
            #expect(text == "Original")
            #expect(!(edits.hasChanges))
            text = "Changed again"
            #expect(edits.hasChanges)
            edits.remove(id)
            #expect(!(edits.hasChanges))
        }

        @Test func testPublishingPreflightRejectsAChangedOrMissingTranscript() throws {
            var transcript = [TranscriptSegment(speakerID: "s1", start: 0, end: 1, text: "Original")]
            let review = DevelopmentTaskReview(transcriptFingerprint: try DevelopmentTaskReview.fingerprint(transcript))
            #expect(throws: Never.self) { try review.validateTranscript(transcript) }
            transcript[0].text = "Updated after opening the panel"
            #expect(throws: (any Error).self) { try review.validateTranscript(transcript) }
            #expect(throws: (any Error).self) { try review.validateTranscript([]) }
        }

        @Test func testAnonymousVoicesRemainScopedToTheirMeetings() {
            let first = Meeting(title: "First", createdAt: .now)
            let second = Meeting(title: "Second", createdAt: .now)
            let speakers = [Speaker(id: "s1", name: "Speaker 1")]
            let segments = [TranscriptSegment(speakerID: "s1", start: 0, end: 5, text: "Words")]
            let summaries = TalkTimeAggregator.aggregate(meetings: [first, second],
                transcripts: [(first.id, segments), (second.id, segments)],
                speakers: [(first.id, speakers), (second.id, speakers)])
            #expect(summaries.count == 2)
            #expect(Set(summaries.compactMap(\.meetingID)) == [first.id, second.id])
            #expect(summaries.allSatisfy { $0.meetingCount == 1 && $0.localSpeakerID == "s1" })
        }

        @Test func testTwoSpeakerIDsWithTheSameNameCountAsOneMeeting() throws {
            let meeting = Meeting(title: "One meeting", createdAt: .now)
            let speakers = [Speaker(id: "s1", name: "Alice"), Speaker(id: "s2", name: "Alice")]
            let segments = [TranscriptSegment(speakerID: "s1", start: 0, end: 5, text: "One"),
                            TranscriptSegment(speakerID: "s2", start: 5, end: 10, text: "Two")]
            let summary = try #require(TalkTimeAggregator.aggregate(meetings: [meeting],
                transcripts: [(meeting.id, segments)], speakers: [(meeting.id, speakers)]).first)
            #expect(summary.meetingCount == 1)
            #expect(summary.avgTalkTimePerMeeting == 10)
        }

        @MainActor
        @Test func testAnonymousRenameChangesOnlyTheSelectedMeeting() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("nutola-rename-\(UUID())")
            defer { FilePersistence.discard(in: root); try? FileManager.default.removeItem(at: root) }
            let archive = MeetingArchive(root: root)
            let store = MeetingStore(archive: archive)
            var first = Meeting(title: "First", createdAt: .now)
            first.speakers = [Speaker(id: "s1", name: "Speaker 1")]
            var second = Meeting(title: "Second", createdAt: .now)
            second.speakers = first.speakers
            for meeting in [first, second] { try archive.createFolder(for: meeting.id); store.upsert(meeting) }
            #expect(store.bulkRenameSpeakers(from: "Speaker 1", to: "Alice") == 0)
            store.renameSpeaker(meetingID: first.id, speakerID: "s1", to: "Alice")
            #expect(store.meeting(id: first.id)?.speakers.first?.name == "Alice")
            #expect(store.meeting(id: second.id)?.speakers.first?.name == "Speaker 1")
        }

        @Test func testLargeArchiveTalkTimeAggregation() {
            let meetings = (0..<100).map { Meeting(title: "Meeting \($0)", createdAt: .now) }
            let speakers = [Speaker(id: "named", name: "Alice"), Speaker(id: "s1", name: "Speaker 1")]
            let segments = (0..<1_000).map { index in
                TranscriptSegment(speakerID: index.isMultiple(of: 2) ? "named" : "s1",
                                  start: Double(index), end: Double(index + 1), text: "Meeting words")
            }
            let transcripts = meetings.map { ($0.id, segments) }
            let people = meetings.map { ($0.id, speakers) }
            let summaries = TalkTimeAggregator.aggregate(meetings: meetings, transcripts: transcripts, speakers: people)
            #expect(summaries.count == 101)
            #expect(summaries.first(where: { $0.name == "Alice" })?.totalTalkTime == 50_000)
        }

        @Test func testSummaryCacheHonorsExternalChangesAndPendingWrites() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("nutola-summary-cache-\(UUID())")
            defer { FilePersistence.discard(in: root); try? FileManager.default.removeItem(at: root) }
            let archive = MeetingArchive(root: root)
            let id = UUID()
            try archive.createFolder(for: id)
            try archive.saveSummary("Original", for: id)
            #expect(archive.summary(for: id) == "Original")
            let file = archive.folder(for: id).appendingPathComponent("summary.md")
            try Data("External edit".utf8).write(to: file)
            #expect(archive.summary(for: id) == "External edit")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try archive.saveSummary("Pending edit", for: id) }
            #expect(archive.summary(for: id) == "Pending edit")
            try FileManager.default.removeItem(at: file)
            FilePersistence.retryAll()
            #expect(archive.summary(for: id) == "Pending edit")
        }
    }
}
