import Foundation
import XCTest
@testable import Nutola

final class GoogleMeetTests: XCTestCase {
    private let code = "abc-defg-hij"

    private func fixture() throws -> MeetAccessibilityNode {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "google-meet-it", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(MeetAccessibilityNode.self, from: Data(contentsOf: file))
    }

    private func row(_ name: String, _ text: String, id: String = "row") -> MeetAccessibilityNode {
        MeetAccessibilityNode(role: "AXGroup", identifier: id, children: [
            MeetAccessibilityNode(role: "AXGroup", children: [MeetAccessibilityNode(role: "AXStaticText", value: name)]),
            MeetAccessibilityNode(role: "AXGroup", children: [MeetAccessibilityNode(role: "AXStaticText", value: text)]),
        ])
    }

    private func snapshot(_ name: String? = nil, text: String = "Hello", id: String = "row",
                          local: Bool = false, room: String = "abc-defg-hij") -> GoogleMeetSnapshot {
        GoogleMeetSnapshot(roomCode: room, participants: nil,
            captions: name.map { [GoogleMeetSnapshot.Caption(id: id, name: $0, text: text, isLocal: local)] } ?? [],
            captionsEnabled: true)
    }

    func testObservedItalianTreeExposesCaptionsAndExplicitLocalMarker() throws {
        let parsed = try XCTUnwrap(GoogleMeetSnapshot.parse(fixture(), roomCode: code))
        XCTAssertEqual(parsed.participants, [PlatformParticipant(name: "Local User", isLocal: true)])
        XCTAssertEqual(parsed.captions.map(\.name), ["Tu"])
        XCTAssertEqual(parsed.captions.first?.text, "Questa è una frase di prova anonima.")
        XCTAssertTrue(parsed.captions.first?.isLocal == true)
        XCTAssertTrue(parsed.captionsEnabled)
    }

    func testEnglishCaptionUsesItsSpeakerLabelWithoutGuessingFromTheAccount() throws {
        var root = try fixture()
        root.children![0].title = "Captions"
        root.children![0].description = "Captions"
        root.children![0].children = [row("alice smith", "Fix login")]
        root.children![1].title = "Participants"
        root.children![2].title = "Leave call"
        let parsed = try XCTUnwrap(GoogleMeetSnapshot.parse(root, roomCode: code))
        XCTAssertEqual(parsed.captions.first?.name, "alice smith")
        XCTAssertEqual(parsed.captions.first?.isLocal, false)
    }

    func testChatTextCannotSupplyCaptionNames() throws {
        var root = try fixture()
        root.children!.append(MeetAccessibilityNode(role: "AXGroup", subrole: "AXLandmarkRegion", title: "Chat",
                                                    children: [row("Mallory", "Fake speaker")]))
        let parsed = try XCTUnwrap(GoogleMeetSnapshot.parse(root, roomCode: code))
        XCTAssertEqual(parsed.captions.map(\.name), ["Tu"])
    }

    func testPrejoinPageDoesNotStartTracking() throws {
        var root = try fixture()
        root.children!.removeLast()
        XCTAssertNil(GoogleMeetSnapshot.parse(root, roomCode: code))
    }

    func testClosedPeoplePanelDoesNotMeanEmptyRoster() throws {
        var root = try fixture()
        root.children!.remove(at: 1)
        let parsed = try XCTUnwrap(GoogleMeetSnapshot.parse(root, roomCode: code))
        XCTAssertNil(parsed.participants)
    }

    func testDisabledCaptionsDoNotUseOtherPageText() throws {
        var root = try fixture()
        root.children!.removeFirst()
        let parsed = try XCTUnwrap(GoogleMeetSnapshot.parse(root, roomCode: code))
        XCTAssertTrue(parsed.captions.isEmpty)
        XCTAssertFalse(parsed.captionsEnabled)
    }

    func testEmptyCaptionBodyDoesNotBecomeASpeakerEvent() throws {
        var root = try fixture()
        root.children![0].children = [row("Alice", " ")]
        XCTAssertTrue(try XCTUnwrap(GoogleMeetSnapshot.parse(root, roomCode: code)).captions.isEmpty)
    }

    func testOnlyExactHTTPSMeetRoomURLsMatch() {
        XCTAssertEqual(GoogleMeetSnapshot.roomCode(from: URL(string: "https://meet.google.com/abc-defg-hij?authuser=0")!), code)
        for url in ["http://meet.google.com/abc-defg-hij", "https://meet.google.com.evil.example/abc-defg-hij",
                    "https://meet.google.com@evil.example/abc-defg-hij", "https://meet.google.com/",
                    "https://meet.google.com/lookup/name", "https://example.com/abc-defg-hij",
                    "https://meet.google.com:8443/abc-defg-hij"] {
            XCTAssertNil(GoogleMeetSnapshot.roomCode(from: URL(string: url)!), url)
        }
    }

    func testChromeDetectionDoesNotMatchOtherBrowsers() {
        for source in ["Chrome", "Google Chrome", "Google Meet", "com.google.Chrome", "com.google.Chrome.helper"] {
            XCTAssertTrue(MeetingDetector.isChromeMeetSource(source), source)
        }
        for source in ["Safari", "Microsoft Edge", "Chrome Beta", "com.google.Chrome.canary", "Chrome Music Player"] {
            XCTAssertFalse(MeetingDetector.isChromeMeetSource(source), source)
        }
    }

    func testExistingCaptionsAreSeededWithoutAttributingPreRecordingSpeech() {
        var timeline = GoogleMeetTimeline()
        timeline.observe(snapshot("Alice"), at: 1)
        XCTAssertTrue(timeline.events.isEmpty)
        XCTAssertNil(timeline.activeName(at: 1))
    }

    func testFreshRemoteCaptionProducesANamedWindowAndExpires() throws {
        var timeline = GoogleMeetTimeline()
        timeline.observe(snapshot(), at: 0)
        timeline.observe(snapshot("Alice"), at: 3)
        XCTAssertEqual(timeline.events, [PlatformSpeakerEvent(name: "Alice", start: 1.5, end: 3, source: .caption)])
        XCTAssertEqual(timeline.speaker(at: 2), "Alice")
        XCTAssertEqual(timeline.activeName(at: 4), "Alice")
        XCTAssertNil(timeline.activeName(at: 6))
    }

    func testStaleOrRecreatedCaptionDoesNotExtendItsWindow() {
        var timeline = GoogleMeetTimeline()
        timeline.observe(snapshot(), at: 0)
        timeline.observe(snapshot("Alice"), at: 3)
        timeline.observe(snapshot("Alice"), at: 8)
        timeline.observe(snapshot("Alice", id: "recreated"), at: 9)
        XCTAssertEqual(timeline.events.last?.end, 3)
        XCTAssertNil(timeline.activeName(at: 9))
    }

    func testLocalCaptionsNeverLabelSystemAudio() {
        var timeline = GoogleMeetTimeline()
        timeline.observe(snapshot(), at: 0)
        timeline.observe(snapshot("Tu", local: true), at: 3)
        XCTAssertTrue(timeline.events.isEmpty)
        XCTAssertNil(timeline.activeName(at: 3))
    }

    func testSimultaneousDifferentNamesRemainAnonymous() {
        var timeline = GoogleMeetTimeline()
        timeline.observe(snapshot(), at: 0)
        var value = snapshot("Alice")
        value.captions.append(GoogleMeetSnapshot.Caption(id: "second", name: "Bob", text: "Hi", isLocal: false))
        timeline.observe(value, at: 3)
        XCTAssertTrue(timeline.events.isEmpty)
        XCTAssertNil(timeline.activeName(at: 3))
    }

    func testTimelineStaysPinnedToItsFirstMeetingRoom() {
        var timeline = GoogleMeetTimeline()
        timeline.observe(snapshot(), at: 0)
        XCTAssertFalse(timeline.observe(snapshot("Other meeting", room: "xyz-abcd-efg"), at: 3))
        XCTAssertEqual(timeline.roomCode, code)
        XCTAssertTrue(timeline.events.isEmpty)
    }

    func testReturningToHiddenTabDoesNotReplayItsOldCaptions() {
        var timeline = GoogleMeetTimeline()
        timeline.observe(snapshot(), at: 0)
        timeline.observe(snapshot("Alice"), at: 3)
        timeline.observe(nil, at: 4)
        timeline.observe(snapshot("Alice"), at: 10)
        XCTAssertEqual(timeline.events.last?.end, 3)
        XCTAssertNil(timeline.activeName(at: 10))
        timeline.observe(snapshot("Alice", text: "New words"), at: 11)
        XCTAssertEqual(timeline.events.last?.end, 11)
    }

    func testExplicitParticipantsPersistSeparatelyFromLegacyZoomRoster() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nutola-meet-\(UUID())")
        defer { FilePersistence.discard(in: root); try? FileManager.default.removeItem(at: root) }
        let archive = MeetingArchive(root: root)
        let id = UUID()
        try archive.createFolder(for: id)
        XCTAssertNil(archive.platformParticipants(for: id))
        archive.savePlatformParticipants([], for: id)
        XCTAssertEqual(archive.platformParticipants(for: id), [])
        archive.savePlatformParticipants([PlatformParticipant(name: "Local User", isLocal: true)], for: id)
        XCTAssertEqual(archive.platformParticipants(for: id)?.first?.isLocal, true)
        XCTAssertTrue(archive.zoomRoster(for: id).isEmpty)
        archive.removePlatformParticipants(for: id)
        XCTAssertNil(archive.platformParticipants(for: id))
    }
}
