import Foundation
import Testing
@testable import Nutola

final class MeetingCommandServiceTests {
    private var root: URL!
    private var archive: MeetingArchive!
    private var service: MeetingCommandService!
    private var meeting: Meeting!

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-meeting-reads-\(UUID().uuidString)")
        archive = MeetingArchive(root: root)
        service = MeetingCommandService(archive: archive)

        var value = Meeting(title: "Roadmap sync", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        value.attendees = ["Priya", "Taylor"]
        value.speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Priya"),
        ]
        value.duration = 1_800
        value.state = .ready
        try archive.createFolder(for: value.id)
        try archive.save(value)
        try archive.saveTranscript([
            TranscriptSegment(speakerID: "s1", start: 12, end: 15, text: "Let's move launch to March."),
        ], for: value.id)
        try archive.saveSummary("## TL;DR\nLaunch moved to March.", for: value.id)
        meeting = value
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @Test func testListPreservesDescriptionAndPagination() throws {
        var older = Meeting(title: "Older sync", createdAt: Date(timeIntervalSince1970: 1_600_000_000))
        older.state = .ready
        try archive.createFolder(for: older.id)
        try archive.save(older)

        let page = service.list(limit: 1, offset: 0)

        #expect(page.contains("[\(meeting.id.uuidString)] Roadmap sync"))
        #expect(page.contains("next_offset: 1"))
        #expect(service.list(limit: 1, offset: 2) == "No more meetings (offset 2 ≥ 2).")
    }

    @Test func testSearchPreservesExcerpts() throws {
        let result = try service.search(query: "march launch", limit: 1, offset: 0)

        #expect(result.contains("Roadmap sync"))
        #expect(result.contains("Priya @ 0:12: Let's move launch to March."))
        #expect(try service.search(query: "missing", limit: 20, offset: 0) == "No meetings matched \"missing\".")
    }

    @Test func testShowIncludesMetadataSummaryAttendeesAndSpeakers() throws {
        let result = try service.show(id: meeting.id.uuidString)

        #expect(result.contains("Attendees: Priya, Taylor"))
        #expect(result.contains("Speakers: Me, Priya"))
        #expect(result.contains("Launch moved to March."))
    }

    @Test func testTranscriptUsesStoredSpeakerNamesAndTimestamps() throws {
        #expect(try service.transcript(id: meeting.id.uuidString) == "# Roadmap sync\n\nPriya @ 0:12: Let's move launch to March.")
    }

    @Test func testLookupRejectsMalformedAndMissingIDs() {
        do {
            _ = try service.show(id: "not-a-uuid")
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription == "'id' must be a meeting UUID")
        }

        let missing = UUID().uuidString
        do {
            _ = try service.transcript(id: missing)
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription == "No meeting with id \(missing)")
        }
    }

    @Test func testLivePreservesDefaultAndWholeMeetingWindows() throws {
        var live = Meeting(title: "Live sync", createdAt: Date())
        live.state = .recording
        try archive.createFolder(for: live.id)
        try archive.save(live)
        archive.saveLiveTranscript([
            TranscriptSegment(speakerID: "me", start: 0, end: 10, text: "Old context"),
            TranscriptSegment(speakerID: "me", start: 420, end: 430, text: "Current context"),
        ], for: live.id)

        let recent = service.live(minutes: nil)
        let whole = service.live(minutes: 0)

        #expect(!(recent.contains("Old context")))
        #expect(recent.contains("Current context"))
        #expect(whole.contains("Old context"))
        #expect(whole.contains("Current context"))
    }
}
