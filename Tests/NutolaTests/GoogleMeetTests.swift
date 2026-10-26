import Foundation
import Testing
@testable import Nutola

extension SharedStateTests {
    struct GoogleMeetTests {
        private let code = "abc-defg-hij"

        private func fixture() throws -> MeetAccessibilityNode {
            let file = try #require(Bundle.module.url(forResource: "google-meet-it", withExtension: "json", subdirectory: "Fixtures"))
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

        @Test func testObservedItalianTreeExposesCaptionsAndExplicitLocalMarker() throws {
            let parsed = try #require(GoogleMeetSnapshot.parse(fixture(), roomCode: code))
            #expect(parsed.participants == [PlatformParticipant(name: "Local User", isLocal: true)])
            #expect(parsed.captions.map(\.name) == ["Tu"])
            #expect(parsed.captions.first?.text == "Questa è una frase di prova anonima.")
            #expect(parsed.captions.first?.isLocal == true)
            #expect(parsed.captionsEnabled)
        }

        @Test func testEnglishCaptionUsesItsSpeakerLabelWithoutGuessingFromTheAccount() throws {
            var root = try fixture()
            root.children![0].title = "Captions"
            root.children![0].description = "Captions"
            root.children![0].children = [row("alice smith", "Fix login")]
            root.children![1].title = "Participants"
            root.children![2].title = "Leave call"
            let parsed = try #require(GoogleMeetSnapshot.parse(root, roomCode: code))
            #expect(parsed.captions.first?.name == "alice smith")
            #expect(parsed.captions.first?.isLocal == false)
        }

        @Test func testChatTextCannotSupplyCaptionNames() throws {
            var root = try fixture()
            root.children!.append(MeetAccessibilityNode(role: "AXGroup", subrole: "AXLandmarkRegion", title: "Chat",
                                                        children: [row("Mallory", "Fake speaker")]))
            let parsed = try #require(GoogleMeetSnapshot.parse(root, roomCode: code))
            #expect(parsed.captions.map(\.name) == ["Tu"])
        }

        @Test func testPrejoinPageDoesNotStartTracking() throws {
            var root = try fixture()
            root.children!.removeLast()
            #expect(GoogleMeetSnapshot.parse(root, roomCode: code) == nil)
        }

        @Test func testClosedPeoplePanelDoesNotMeanEmptyRoster() throws {
            var root = try fixture()
            root.children!.remove(at: 1)
            let parsed = try #require(GoogleMeetSnapshot.parse(root, roomCode: code))
            #expect(parsed.participants == nil)
        }

        @Test func testDisabledCaptionsDoNotUseOtherPageText() throws {
            var root = try fixture()
            root.children!.removeFirst()
            let parsed = try #require(GoogleMeetSnapshot.parse(root, roomCode: code))
            #expect(parsed.captions.isEmpty)
            #expect(!(parsed.captionsEnabled))
        }

        @Test func testEmptyCaptionBodyDoesNotBecomeASpeakerEvent() throws {
            var root = try fixture()
            root.children![0].children = [row("Alice", " ")]
            #expect(try #require(GoogleMeetSnapshot.parse(root, roomCode: code)).captions.isEmpty)
        }

        @Test func testOnlyExactHTTPSMeetRoomURLsMatch() {
            #expect(GoogleMeetSnapshot.roomCode(from: URL(string: "https://meet.google.com/abc-defg-hij?authuser=0")!) == code)
            for url in ["http://meet.google.com/abc-defg-hij", "https://meet.google.com.evil.example/abc-defg-hij",
                        "https://meet.google.com@evil.example/abc-defg-hij", "https://meet.google.com/",
                        "https://meet.google.com/lookup/name", "https://example.com/abc-defg-hij",
                        "https://meet.google.com:8443/abc-defg-hij"] {
                #expect(GoogleMeetSnapshot.roomCode(from: URL(string: url)!) == nil, "\(url)")
            }
        }

        @Test func testChromeDetectionDoesNotMatchOtherBrowsers() {
            for source in ["Chrome", "Google Chrome", "Google Meet", "com.google.Chrome", "com.google.Chrome.helper"] {
                #expect(MeetingDetector.isChromeMeetSource(source), "\(source)")
            }
            for source in ["Safari", "Microsoft Edge", "Chrome Beta", "com.google.Chrome.canary", "Chrome Music Player"] {
                #expect(!(MeetingDetector.isChromeMeetSource(source)), "\(source)")
            }
        }

        @Test func testExistingCaptionsAreSeededWithoutAttributingPreRecordingSpeech() {
            var timeline = GoogleMeetTimeline()
            timeline.observe(snapshot("Alice"), at: 1)
            #expect(timeline.events.isEmpty)
            #expect(timeline.activeName(at: 1) == nil)
        }

        @Test func testFreshRemoteCaptionProducesANamedWindowAndExpires() throws {
            var timeline = GoogleMeetTimeline()
            timeline.observe(snapshot(), at: 0)
            timeline.observe(snapshot("Alice"), at: 3)
            #expect(timeline.events == [PlatformSpeakerEvent(name: "Alice", start: 1.5, end: 3, source: .caption)])
            #expect(timeline.speaker(at: 2) == "Alice")
            #expect(timeline.activeName(at: 4) == "Alice")
            #expect(timeline.activeName(at: 6) == nil)
        }

        @Test func testStaleOrRecreatedCaptionDoesNotExtendItsWindow() {
            var timeline = GoogleMeetTimeline()
            timeline.observe(snapshot(), at: 0)
            timeline.observe(snapshot("Alice"), at: 3)
            timeline.observe(snapshot("Alice"), at: 8)
            timeline.observe(snapshot("Alice", id: "recreated"), at: 9)
            #expect(timeline.events.last?.end == 3)
            #expect(timeline.activeName(at: 9) == nil)
        }

        @Test func testLocalCaptionsNeverLabelSystemAudio() {
            var timeline = GoogleMeetTimeline()
            timeline.observe(snapshot(), at: 0)
            timeline.observe(snapshot("Tu", local: true), at: 3)
            #expect(timeline.events.isEmpty)
            #expect(timeline.activeName(at: 3) == nil)
        }

        @Test func testSimultaneousDifferentNamesRemainAnonymous() {
            var timeline = GoogleMeetTimeline()
            timeline.observe(snapshot(), at: 0)
            var value = snapshot("Alice")
            value.captions.append(GoogleMeetSnapshot.Caption(id: "second", name: "Bob", text: "Hi", isLocal: false))
            timeline.observe(value, at: 3)
            #expect(timeline.events.isEmpty)
            #expect(timeline.activeName(at: 3) == nil)
        }

        @Test func testTimelineStaysPinnedToItsFirstMeetingRoom() {
            var timeline = GoogleMeetTimeline()
            timeline.observe(snapshot(), at: 0)
            let accepted = timeline.observe(snapshot("Other meeting", room: "xyz-abcd-efg"), at: 3)
            #expect(!accepted)
            #expect(timeline.roomCode == code)
            #expect(timeline.events.isEmpty)
        }

        @Test func testReturningToHiddenTabDoesNotReplayItsOldCaptions() {
            var timeline = GoogleMeetTimeline()
            timeline.observe(snapshot(), at: 0)
            timeline.observe(snapshot("Alice"), at: 3)
            timeline.observe(nil, at: 4)
            timeline.observe(snapshot("Alice"), at: 10)
            #expect(timeline.events.last?.end == 3)
            #expect(timeline.activeName(at: 10) == nil)
            timeline.observe(snapshot("Alice", text: "New words"), at: 11)
            #expect(timeline.events.last?.end == 11)
        }

        @Test func testExplicitParticipantsPersistSeparatelyFromLegacyZoomRoster() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("nutola-meet-\(UUID())")
            defer { FilePersistence.discard(in: root); try? FileManager.default.removeItem(at: root) }
            let archive = MeetingArchive(root: root)
            let id = UUID()
            try archive.createFolder(for: id)
            #expect(archive.platformParticipants(for: id) == nil)
            archive.savePlatformParticipants([], for: id)
            #expect(archive.platformParticipants(for: id) == [])
            archive.savePlatformParticipants([PlatformParticipant(name: "Local User", isLocal: true)], for: id)
            #expect(archive.platformParticipants(for: id)?.first?.isLocal == true)
            #expect(archive.zoomRoster(for: id).isEmpty)
            archive.removePlatformParticipants(for: id)
            #expect(archive.platformParticipants(for: id) == nil)
        }
    }
}
