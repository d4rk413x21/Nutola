import Foundation
import XCTest
@testable import Nutola

final class FilePersistenceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nutola-write-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        FilePersistence.discard(in: root)
        try FileManager.default.removeItem(at: root)
    }

    func testRetryKeepsOnlyTheLatestFailedContents() throws {
        let file = root.appendingPathComponent("notes.md")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try FilePersistence.write(Data("first".utf8), to: file))
        XCTAssertThrowsError(try FilePersistence.write(Data("latest".utf8), to: file))
        XCTAssertEqual(FilePersistence.failures[file]?.data, Data("latest".utf8))
        try FileManager.default.removeItem(at: file)
        FilePersistence.retryAll()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "latest")
        XCTAssertNil(FilePersistence.failures[file])
    }

    func testSuccessfulSaveSupersedesAnOlderFailedWrite() throws {
        let file = root.appendingPathComponent("notes.md")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try FilePersistence.write(Data("old".utf8), to: file))
        try FileManager.default.removeItem(at: file)
        try FilePersistence.write(Data("new".utf8), to: file)
        FilePersistence.retryAll()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        XCTAssertNil(FilePersistence.failures[file])
    }

    @MainActor
    func testFailedSummarySaveDoesNotTriggerSuccessHook() throws {
        let archive = MeetingArchive(root: root)
        let meeting = Meeting(title: "Planning", createdAt: .now)
        try archive.createFolder(for: meeting.id)
        try archive.save(meeting)
        let store = MeetingStore(archive: archive)
        let file = archive.folder(for: meeting.id).appendingPathComponent("summary.md")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var callbacks = 0
        store.onSummarySaved = { _, _ in callbacks += 1 }
        XCTAssertFalse(store.saveSummarySafely("Keep these edits", for: meeting.id))
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(FilePersistence.failures[file]?.data, Data("Keep these edits".utf8))
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(store.saveSummarySafely("Saved edits", for: meeting.id))
        XCTAssertEqual(callbacks, 1)
        XCTAssertNil(FilePersistence.failures[file])
    }

    func testDeletingMeetingDiscardsItsPendingWrites() throws {
        let archive = MeetingArchive(root: root)
        let id = UUID()
        try archive.createFolder(for: id)
        let file = archive.folder(for: id).appendingPathComponent("notes.md")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try archive.saveSideNotes("Unsaved", for: id))
        try archive.delete(id: id)
        FilePersistence.retryAll()
        XCTAssertNil(FilePersistence.failures[file])
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.folder(for: id).path))
    }

    func testFolderEditsAccumulateAcrossWriteFailures() throws {
        let archive = FolderArchive(root: root)
        let file = archive.foldersDir.appendingPathComponent("folders.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let first = MeetingFolder(name: "First", createdAt: .now)
        let second = MeetingFolder(name: "Second", createdAt: .now)
        XCTAssertThrowsError(try archive.save(first))
        XCTAssertThrowsError(try archive.save(second))
        try FileManager.default.removeItem(at: file)
        FilePersistence.retryAll()
        XCTAssertEqual(Set(archive.allFolders().map(\.id)), [first.id, second.id])
    }

    func testPermissionGuidanceDoesNotTreatPastCaptureAsCurrentAuthorization() {
        let text = SystemAudioPermission.guidance(previouslyCaptured: true)
        XCTAssertTrue(text.contains("previous recording"))
        XCTAssertTrue(text.contains("does not expose the current permission"))
        XCTAssertFalse(SystemAudioPermission.guidance(previouslyCaptured: false).contains("previous recording"))
    }

    func testEncodingFailureDoesNotErasePreviouslySavedTasks() throws {
        let suite = "nutola-task-encoding-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaskTrackerStore(defaults: defaults)
        store.add(text: "Saved task")
        let previous = try XCTUnwrap(defaults.data(forKey: SettingsKey.taskTracker))
        store.add(text: "Invalid date", createdAt: Date(timeIntervalSince1970: .infinity))
        XCTAssertEqual(defaults.data(forKey: SettingsKey.taskTracker), previous)
    }

    func testAutomaticSummaryCannotReplaceAPendingUserEdit() throws {
        let archive = MeetingArchive(root: root)
        let id = UUID()
        try archive.createFolder(for: id)
        try archive.saveSummary("Original", for: id)
        let file = archive.folder(for: id).appendingPathComponent("summary.md")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try archive.saveSummary("User edits", for: id))
        XCTAssertEqual(archive.summary(for: id), "User edits")
        XCTAssertThrowsError(try archive.saveSummary("AI improvement", for: id, replacing: "Original")) { error in
            guard case MeetingArchive.ArchiveError.summaryChanged = error else {
                return XCTFail("Expected a concurrent edit conflict")
            }
        }
        try FileManager.default.removeItem(at: file)
        FilePersistence.retryAll()
        XCTAssertEqual(archive.summary(for: id), "User edits")
    }

    func testTranscriptCacheDoesNotHidePendingEdits() throws {
        let archive = MeetingArchive(root: root)
        let id = UUID()
        try archive.createFolder(for: id)
        let original = [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Original")]
        try archive.saveTranscript(original, for: id)
        XCTAssertEqual(archive.transcript(for: id), original)
        let file = archive.folder(for: id).appendingPathComponent("transcript.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let edited = [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Edited")]
        XCTAssertThrowsError(try archive.saveTranscript(edited, for: id))
        XCTAssertEqual(archive.transcript(for: id), edited)
    }

    func testAudioWriteFailureKeepsTheFirstErrorForTheRecording() {
        var failure = AudioWriteFailure()
        failure.record(NSError(domain: "Disk", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "Disk full (AVFAudio error)"]), source: "Microphone")
        let first = failure.message
        failure.record(NSError(domain: "Disk", code: 2), source: "Microphone")
        XCTAssertEqual(failure.message, first)
        XCTAssertTrue(first?.contains("Disk full") == true)
        XCTAssertTrue(first?.contains("Some audio may be missing") == true)
        XCTAssertEqual(MeetingNotice.finalizedNotice([first!], hasTranscriptContent: true), first)
        XCTAssertEqual(MeetingNotice.effectivePresentation(for: first, hasTranscript: true)?.title,
                       "Incomplete audio recording")
    }
}
