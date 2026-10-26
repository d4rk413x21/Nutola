import Foundation
import Testing
@testable import Nutola

@MainActor
struct MeetingSearchTests {
    @Test func testSearchFindsTranscriptMatch() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("search-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let archive = MeetingArchive(root: tmp)
        let store = MeetingStore(archive: archive)

        let meeting = Meeting(title: "Sprint Planning", createdAt: Date())
        try archive.createFolder(for: meeting.id)
        store.upsert(meeting)
        store.saveTranscript([
            TranscriptSegment(speakerID: "s1", start: 0, end: 5, text: "We need to ship the API"),
            TranscriptSegment(speakerID: "me", start: 5, end: 10, text: "I'll handle the frontend")
        ], for: meeting.id)

        // Verify data was saved
        #expect(store.meetings.count == 1, "meeting should be in store")
        #expect(store.transcript(for: meeting.id).count == 2, "transcript should be saved")

        let results = store.searchAll("API")
        #expect(results.count == 1)
        #expect(results[0].matchingSegments.count == 1)
        #expect(!(results[0].summaryMatch))
    }

    @Test func testSearchFindsSummaryMatch() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("search-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let archive = MeetingArchive(root: tmp)
        let store = MeetingStore(archive: archive)

        let meeting = Meeting(title: "Design Review", createdAt: Date())
        try archive.createFolder(for: meeting.id)
        store.upsert(meeting)
        store.saveSummary("We discussed the new button design and color palette.", for: meeting.id)

        let results = store.searchAll("button")
        #expect(results.count == 1)
        #expect(results[0].summaryMatch)
        #expect(results[0].matchingSegments.isEmpty)
    }

    @Test func testSearchEmptyQueryReturnsNothing() throws {
        let archive = MeetingArchive(root: FileManager.default.temporaryDirectory)
        let store = MeetingStore(archive: archive)
        let results = store.searchAll("")
        #expect(results.isEmpty)
    }

    @Test func testSearchCaseInsensitive() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("search-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let archive = MeetingArchive(root: tmp)
        let store = MeetingStore(archive: archive)

        let meeting = Meeting(title: "Test", createdAt: Date())
        try archive.createFolder(for: meeting.id)
        store.upsert(meeting)
        store.saveTranscript([
            TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Deploy to Production")
        ], for: meeting.id)

        #expect(store.meetings.count == 1, "meeting should be in store")
        #expect(store.transcript(for: meeting.id).count == 1, "transcript should be saved")

        let results = store.searchAll("production")
        #expect(results.count == 1, "should find 'production' in 'Deploy to Production'")
        #expect(results.first?.matchingSegments.count == 1)
    }

    @Test func testSearchMultipleMeetings() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("search-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let archive = MeetingArchive(root: tmp)
        let store = MeetingStore(archive: archive)

        let meeting1 = Meeting(title: "Standup", createdAt: Date())
        try archive.createFolder(for: meeting1.id)
        store.upsert(meeting1)
        store.saveTranscript([
            TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Working on the API")
        ], for: meeting1.id)

        let meeting2 = Meeting(title: "Retro", createdAt: Date().addingTimeInterval(-3600))
        try archive.createFolder(for: meeting2.id)
        store.upsert(meeting2)
        store.saveTranscript([
            TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "The API needs improvement"),
            TranscriptSegment(speakerID: "s1", start: 1, end: 2, text: "I agree about the API")
        ], for: meeting2.id)

        let results = store.searchAll("API")
        #expect(results.count == 2)
        #expect(results[0].matchingSegments.count == 2)
        #expect(results[1].matchingSegments.count == 1)
    }
}
