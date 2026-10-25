import XCTest
@testable import Nutola

final class PlatformSpeakerTests: XCTestCase {
    func testParseSpeakingLabels() {
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseSpeakingLabel("Jimmy Veloso, unmuted"),
            "Jimmy Veloso")
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseZoomParticipantDescription(
                "Gui Lima, Computer audio unmuted, Video on"),
            "Gui Lima")
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseSpeakingLabel("Acquila Santos Rocha is speaking"),
            "Acquila Santos Rocha")
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseSpeakingLabel("Speaking: Gui Lima"),
            "Gui Lima")
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseZoomTileDescription(
                "Paulo Henrique Paulin, Computer audio unmuted, Video on, active speaker"),
            "Paulo Henrique Paulin")
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseZoomTileDescription(
                "Gui Lima, Computer audio unmuted, Video on"),
            nil)
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel("Mute"))
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel("Participants"))
        // Regression: unmuted gallery tiles are roster metadata, not speaking labels.
        XCTAssertNil(
            ZoomActiveSpeakerReader.parseSpeakingLabel(
                "Gui Lima, Computer audio unmuted, Video on"))
        XCTAssertNil(
            ZoomActiveSpeakerReader.parseSpeakingLabel(
                "Acquila Santos Rocha, Computer audio unmuted, Video on"))
    }

    func testIsLocalParticipantFilteredFromActive() {
        let full = NSFullUserName()
        guard !full.isEmpty else { return }
        XCTAssertTrue(ZoomActiveSpeakerReader.isLocalParticipant(full))
        let first = full.split(separator: " ").prefix(2).joined(separator: " ")
        if first != full {
            XCTAssertTrue(ZoomActiveSpeakerReader.isLocalParticipant(first))
        }
        XCTAssertFalse(ZoomActiveSpeakerReader.isLocalParticipant("Totally Different Person"))
    }

    func testActiveSpeakerIgnoresUnmutedGalleryTiles() {
        let tiles = [
            "Acquila Santos Rocha, Computer audio unmuted, Video on",
            "Gui Lima, Computer audio unmuted, Video on",
            "Victor Moura de Britto, Computer audio unmuted, Video on, active speaker",
            "Paulo Henrique Paulin, Computer audio unmuted, Video on",
        ]
        let roster = tiles.compactMap { ZoomActiveSpeakerReader.parseZoomParticipantDescription($0) }
        let active = tiles.compactMap { ZoomActiveSpeakerReader.parseZoomTileDescription($0) }
        XCTAssertEqual(roster.count, 4)
        XCTAssertEqual(active, ["Victor Moura de Britto"])
    }

    func testActiveSpeakerNamesFromZoomTileDescriptions() {
        // Regression: Zoom Workplace exposes active speaker on AXTabGroup descriptions.
        let samples = [
            "Taylor Morgan, Computer audio unmuted, Video on",
            "Gui Lima, Computer audio unmuted, Video on",
            "Paulo Henrique Paulin, Computer audio unmuted, Video on, active speaker",
        ]
        let names = samples.compactMap { ZoomActiveSpeakerReader.parseZoomTileDescription($0) }
        XCTAssertEqual(names, ["Paulo Henrique Paulin"])
    }

    func testNormalizedMergesAdjacentSameName() {
        let events = [
            PlatformSpeakerEvent(name: "Alice", start: 0, end: 2),
            PlatformSpeakerEvent(name: "Alice", start: 2.2, end: 5),
            PlatformSpeakerEvent(name: "Bob", start: 6, end: 8),
        ]
        let out = PlatformSpeakerTurnBuilder.normalized(events)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].name, "Alice")
        XCTAssertEqual(out[0].start, 0)
        XCTAssertEqual(out[0].end, 5)
        XCTAssertEqual(out[1].name, "Bob")
    }

    func testNamedSpeakersUseDisplayNames() {
        let system = TranscriptionOutput(
            words: [
                TranscribedWord(text: "hello", start: 0.0, end: 0.5),
                TranscribedWord(text: "there", start: 0.6, end: 1.0),
                TranscribedWord(text: "hi", start: 3.0, end: 3.4),
            ],
            segments: []
        )
        let turns = [
            DiarizedTurn(speaker: "Jimmy Veloso", start: 0, end: 2),
            DiarizedTurn(speaker: "Gui Lima", start: 2.5, end: 4),
        ]
        let (_, speakers) = SpeakerLabeler.label(
            mic: nil,
            system: system,
            systemTurns: turns,
            myName: "Me",
            namedSpeakers: true)

        XCTAssertEqual(speakers.map(\.name), ["Jimmy Veloso", "Gui Lima"])
    }

    func testParseZoomCaptionLine() {
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseZoomCaptionLine("Gui Lima: hello everyone")?.name,
            "Gui Lima")
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseZoomCaptionLine("Paulo said: let's ship it")?.name,
            "Paulo")
        XCTAssertNil(ZoomActiveSpeakerReader.parseZoomCaptionLine("Mute"))
    }

    func testParseParticipantRow() {
        XCTAssertEqual(ZoomActiveSpeakerReader.parseParticipantRow("Victor Moura"), "Victor Moura")
        XCTAssertNil(ZoomActiveSpeakerReader.parseParticipantRow("Participants (5)"))
        XCTAssertNil(
            ZoomActiveSpeakerReader.parseParticipantRow(
                "Gui Lima, Computer audio unmuted, Video on"))
    }

    // MARK: - #88: parser edge cases

    func testParseSpeakingLabelEdgeCases() {
        // Empty / whitespace-only input → nil (guard before regex).
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel(""))
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel("   "))
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel("\n\t"))

        // Ignored exact-match strings (Zoom UI labels, not names).
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel("Mute"))
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel("Unmute"))
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel("Participants"))
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel("Host"))

        // Single-character "names" fail the min-length (>= 2) check.
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel("A is speaking"))

        // All-whitespace "names" are rejected by `cleaned`.
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel("    is speaking"))

        // "zoom"-prefixed strings are rejected (Zoom UI, not a participant).
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel("Zoom Host is speaking"))

        // Names with @ are rejected (looks like an email / meeting ID).
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel("user@example.com is speaking"))

        // Each of the six supported label shapes must still parse.
        XCTAssertEqual(ZoomActiveSpeakerReader.parseSpeakingLabel("Alice Rivera, unmuted"), "Alice Rivera")
        XCTAssertEqual(ZoomActiveSpeakerReader.parseSpeakingLabel("Alice Rivera, unmuted audio"), "Alice Rivera")
        XCTAssertEqual(ZoomActiveSpeakerReader.parseSpeakingLabel("Bob is speaking"), "Bob")
        XCTAssertEqual(ZoomActiveSpeakerReader.parseSpeakingLabel("Bob is talking"), "Bob")
        XCTAssertEqual(ZoomActiveSpeakerReader.parseSpeakingLabel("Speaking: Carol"), "Carol")
        XCTAssertEqual(ZoomActiveSpeakerReader.parseSpeakingLabel("Active Speaker: Dan"), "Dan")
        XCTAssertEqual(ZoomActiveSpeakerReader.parseSpeakingLabel("Eve, speaking"), "Eve")

        // Case-insensitive: "SPEAKING:" prefix matches.
        XCTAssertEqual(ZoomActiveSpeakerReader.parseSpeakingLabel("SPEAKING: Frank"), "Frank")

        // Gallery tile descriptions (with "Computer audio" / "Video on") are
        // roster metadata, NOT speaking labels — must be rejected.
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel(
            "Gui Lima, Computer audio unmuted, Video on"))
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel(
            "Acquila Santos Rocha, Computer audio unmuted, Video on, active speaker"))
    }

    func testParseZoomCaptionLineEdgeCases() {
        // Empty / whitespace-only input → nil.
        XCTAssertNil(ZoomActiveSpeakerReader.parseZoomCaptionLine(""))
        XCTAssertNil(ZoomActiveSpeakerReader.parseZoomCaptionLine("   \n  "))

        // Ignored exact-match names (Zoom UI labels) → nil.
        XCTAssertNil(ZoomActiveSpeakerReader.parseZoomCaptionLine("Mute"))
        XCTAssertNil(ZoomActiveSpeakerReader.parseZoomCaptionLine("Participants: hello"))

        // Tile descriptions are NOT caption lines (contain "Computer audio").
        XCTAssertNil(ZoomActiveSpeakerReader.parseZoomCaptionLine(
            "Gui Lima, Computer audio unmuted, Video on"))

        // Body too short (< 2 chars) → nil. The caption must have real content
        // after the colon, not just punctuation.
        XCTAssertNil(ZoomActiveSpeakerReader.parseZoomCaptionLine("Alice: "))
        XCTAssertNil(ZoomActiveSpeakerReader.parseZoomCaptionLine("Alice: x"))

        // Well-formed caption lines parse name + body.
        let caption = ZoomActiveSpeakerReader.parseZoomCaptionLine("Gui Lima: hello everyone")
        XCTAssertEqual(caption?.name, "Gui Lima")
        XCTAssertEqual(caption?.text, "hello everyone")

        // "said:" variant captures a different speaker prefix.
        let said = ZoomActiveSpeakerReader.parseZoomCaptionLine("Paulo said: let's ship it")
        XCTAssertEqual(said?.name, "Paulo")
        XCTAssertEqual(said?.text, "let's ship it")

        // Surrounding whitespace on the raw line is trimmed before matching.
        let trimmed = ZoomActiveSpeakerReader.parseZoomCaptionLine("  Bob Chen: hi there  ")
        XCTAssertEqual(trimmed?.name, "Bob Chen")
        XCTAssertEqual(trimmed?.text, "hi there")

        // Single-character "name" → nil (min-length 2 in `cleaned`).
        XCTAssertNil(ZoomActiveSpeakerReader.parseZoomCaptionLine("A: hello there"))

        // All-numeric "name" (a phone/meeting ID) → nil.
        XCTAssertNil(ZoomActiveSpeakerReader.parseZoomCaptionLine("12345: hello there"))
    }
}
