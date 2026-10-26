import Foundation
import Testing
@testable import Nutola

extension SharedStateTests {
    final class FilePersistenceTests {
        private var root: URL!

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("nutola-write-tests-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit {
            FilePersistence.discard(in: root)
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error) }
        }

        @Test func testRetryKeepsOnlyTheLatestFailedContents() throws {
            let file = root.appendingPathComponent("notes.md")
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try FilePersistence.write(Data("first".utf8), to: file) }
            #expect(throws: (any Error).self) { try FilePersistence.write(Data("latest".utf8), to: file) }
            #expect(FilePersistence.failures[file]?.data == Data("latest".utf8))
            try FileManager.default.removeItem(at: file)
            FilePersistence.retryAll()
            #expect(try String(contentsOf: file, encoding: .utf8) == "latest")
            #expect(FilePersistence.failures[file] == nil)
        }

        @Test func testSuccessfulSaveSupersedesAnOlderFailedWrite() throws {
            let file = root.appendingPathComponent("notes.md")
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try FilePersistence.write(Data("old".utf8), to: file) }
            try FileManager.default.removeItem(at: file)
            try FilePersistence.write(Data("new".utf8), to: file)
            FilePersistence.retryAll()
            #expect(try String(contentsOf: file, encoding: .utf8) == "new")
            #expect(FilePersistence.failures[file] == nil)
        }

        @MainActor
        @Test func testFailedSummarySaveDoesNotTriggerSuccessHook() throws {
            let archive = MeetingArchive(root: root)
            let meeting = Meeting(title: "Planning", createdAt: .now)
            try archive.createFolder(for: meeting.id)
            try archive.save(meeting)
            let store = MeetingStore(archive: archive)
            let file = archive.folder(for: meeting.id).appendingPathComponent("summary.md")
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            var callbacks = 0
            store.onSummarySaved = { _, _ in callbacks += 1 }
            #expect(!(store.saveSummarySafely("Keep these edits", for: meeting.id)))
            #expect(callbacks == 0)
            #expect(FilePersistence.failures[file]?.data == Data("Keep these edits".utf8))
            try FileManager.default.removeItem(at: file)
            #expect(store.saveSummarySafely("Saved edits", for: meeting.id))
            #expect(callbacks == 1)
            #expect(FilePersistence.failures[file] == nil)
        }

        @Test func testDeletingMeetingDiscardsItsPendingWrites() throws {
            let archive = MeetingArchive(root: root)
            let id = UUID()
            try archive.createFolder(for: id)
            let file = archive.folder(for: id).appendingPathComponent("notes.md")
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try archive.saveSideNotes("Unsaved", for: id) }
            try archive.delete(id: id)
            FilePersistence.retryAll()
            #expect(FilePersistence.failures[file] == nil)
            #expect(!(FileManager.default.fileExists(atPath: archive.folder(for: id).path)))
        }

        @Test func testFolderEditsAccumulateAcrossWriteFailures() throws {
            let archive = FolderArchive(root: root)
            let file = archive.foldersDir.appendingPathComponent("folders.json")
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            let first = MeetingFolder(name: "First", createdAt: .now)
            let second = MeetingFolder(name: "Second", createdAt: .now)
            #expect(throws: (any Error).self) { try archive.save(first) }
            #expect(throws: (any Error).self) { try archive.save(second) }
            try FileManager.default.removeItem(at: file)
            FilePersistence.retryAll()
            #expect(Set(archive.allFolders().map(\.id)) == [first.id, second.id])
        }

        @Test func testPermissionGuidanceDoesNotTreatPastCaptureAsCurrentAuthorization() {
            let text = SystemAudioPermission.guidance(previouslyCaptured: true)
            #expect(text.contains("previous recording"))
            #expect(text.contains("does not expose the current permission"))
            #expect(!(SystemAudioPermission.guidance(previouslyCaptured: false).contains("previous recording")))
        }

        @Test func testEncodingFailureDoesNotErasePreviouslySavedTasks() throws {
            let suite = "nutola-task-encoding-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = TaskTrackerStore(defaults: defaults)
            store.add(text: "Saved task")
            let previous = try #require(defaults.data(forKey: SettingsKey.taskTracker))
            store.add(text: "Invalid date", createdAt: Date(timeIntervalSince1970: .infinity))
            #expect(defaults.data(forKey: SettingsKey.taskTracker) == previous)
        }

        @Test func testAutomaticSummaryCannotReplaceAPendingUserEdit() throws {
            let archive = MeetingArchive(root: root)
            let id = UUID()
            try archive.createFolder(for: id)
            try archive.saveSummary("Original", for: id)
            let file = archive.folder(for: id).appendingPathComponent("summary.md")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try archive.saveSummary("User edits", for: id) }
            #expect(archive.summary(for: id) == "User edits")
            do {
                _ = try archive.saveSummary("AI improvement", for: id, replacing: "Original")
                Issue.record("Expected an error")
            } catch {
                guard case MeetingArchive.ArchiveError.summaryChanged = error else {
                    Issue.record("Expected a concurrent edit conflict")
                    return
                }
            }
            try FileManager.default.removeItem(at: file)
            FilePersistence.retryAll()
            #expect(archive.summary(for: id) == "User edits")
        }

        @Test func testTranscriptCacheDoesNotHidePendingEdits() throws {
            let archive = MeetingArchive(root: root)
            let id = UUID()
            try archive.createFolder(for: id)
            let original = [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Original")]
            try archive.saveTranscript(original, for: id)
            #expect(archive.transcript(for: id) == original)
            let file = archive.folder(for: id).appendingPathComponent("transcript.json")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            let edited = [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Edited")]
            #expect(throws: (any Error).self) { try archive.saveTranscript(edited, for: id) }
            #expect(archive.transcript(for: id) == edited)
        }

        @Test func testAudioWriteFailureKeepsTheFirstErrorForTheRecording() {
            var failure = AudioWriteFailure()
            failure.record(NSError(domain: "Disk", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "Disk full (AVFAudio error)"]), source: "Microphone")
            let first = failure.message
            failure.record(NSError(domain: "Disk", code: 2), source: "Microphone")
            #expect(failure.message == first)
            #expect(first?.contains("Disk full") == true)
            #expect(first?.contains("Some audio may be missing") == true)
            #expect(MeetingNotice.finalizedNotice([first!], hasTranscriptContent: true) == first)
            #expect(MeetingNotice.effectivePresentation(for: first, hasTranscript: true)?.title == "Incomplete audio recording")
        }
    }
}
