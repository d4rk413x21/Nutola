import Foundation
import Testing
@testable import Nutola

struct PlatformSpeakerTests {
    @Test func testParseSpeakingLabels() {
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Jimmy Veloso, unmuted") == "Jimmy Veloso")
        #expect(ZoomActiveSpeakerReader.parseZoomParticipantDescription(
                "Gui Lima, Computer audio unmuted, Video on") == "Gui Lima")
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Acquila Santos Rocha is speaking") == "Acquila Santos Rocha")
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Speaking: Gui Lima") == "Gui Lima")
        #expect(ZoomActiveSpeakerReader.parseZoomTileDescription(
                "Paulo Henrique Paulin, Computer audio unmuted, Video on, active speaker") == "Paulo Henrique Paulin")
        #expect(ZoomActiveSpeakerReader.parseZoomTileDescription(
                "Gui Lima, Computer audio unmuted, Video on") == nil)
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Mute") == nil)
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Participants") == nil)
        // Regression: unmuted gallery tiles are roster metadata, not speaking labels.
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel(
                "Gui Lima, Computer audio unmuted, Video on") == nil)
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel(
                "Acquila Santos Rocha, Computer audio unmuted, Video on") == nil)
    }

    @Test func testIsLocalParticipantFilteredFromActive() {
        let full = NSFullUserName()
        guard !full.isEmpty else { return }
        #expect(ZoomActiveSpeakerReader.isLocalParticipant(full))
        let first = full.split(separator: " ").prefix(2).joined(separator: " ")
        if first != full {
            #expect(ZoomActiveSpeakerReader.isLocalParticipant(first))
        }
        #expect(!(ZoomActiveSpeakerReader.isLocalParticipant("Totally Different Person")))
    }

    @Test func testActiveSpeakerIgnoresUnmutedGalleryTiles() {
        let tiles = [
            "Acquila Santos Rocha, Computer audio unmuted, Video on",
            "Gui Lima, Computer audio unmuted, Video on",
            "Victor Moura de Britto, Computer audio unmuted, Video on, active speaker",
            "Paulo Henrique Paulin, Computer audio unmuted, Video on",
        ]
        let roster = tiles.compactMap { ZoomActiveSpeakerReader.parseZoomParticipantDescription($0) }
        let active = tiles.compactMap { ZoomActiveSpeakerReader.parseZoomTileDescription($0) }
        #expect(roster.count == 4)
        #expect(active == ["Victor Moura de Britto"])
    }

    @Test func testActiveSpeakerNamesFromZoomTileDescriptions() {
        // Regression: Zoom Workplace exposes active speaker on AXTabGroup descriptions.
        let samples = [
            "Taylor Morgan, Computer audio unmuted, Video on",
            "Gui Lima, Computer audio unmuted, Video on",
            "Paulo Henrique Paulin, Computer audio unmuted, Video on, active speaker",
        ]
        let names = samples.compactMap { ZoomActiveSpeakerReader.parseZoomTileDescription($0) }
        #expect(names == ["Paulo Henrique Paulin"])
    }

    @Test func testNormalizedMergesAdjacentSameName() {
        let events = [
            PlatformSpeakerEvent(name: "Alice", start: 0, end: 2),
            PlatformSpeakerEvent(name: "Alice", start: 2.2, end: 5),
            PlatformSpeakerEvent(name: "Bob", start: 6, end: 8),
        ]
        let out = PlatformSpeakerTurnBuilder.normalized(events)
        #expect(out.count == 2)
        #expect(out[0].name == "Alice")
        #expect(out[0].start == 0)
        #expect(out[0].end == 5)
        #expect(out[1].name == "Bob")
    }

    @Test func testNamedSpeakersUseDisplayNames() {
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

        #expect(speakers.map(\.name) == ["Jimmy Veloso", "Gui Lima"])
    }

    @Test func testParseZoomCaptionLine() {
        #expect(ZoomActiveSpeakerReader.parseZoomCaptionLine("Gui Lima: hello everyone")?.name == "Gui Lima")
        #expect(ZoomActiveSpeakerReader.parseZoomCaptionLine("Paulo said: let's ship it")?.name == "Paulo")
        #expect(ZoomActiveSpeakerReader.parseZoomCaptionLine("Mute") == nil)
    }

    @Test func testParseParticipantRow() {
        #expect(ZoomActiveSpeakerReader.parseParticipantRow("Victor Moura") == "Victor Moura")
        #expect(ZoomActiveSpeakerReader.parseParticipantRow("Participants (5)") == nil)
        #expect(ZoomActiveSpeakerReader.parseParticipantRow(
                "Gui Lima, Computer audio unmuted, Video on") == nil)
    }

    // MARK: - #88: parser edge cases

    @Test func testParseSpeakingLabelEdgeCases() {
        // Empty / whitespace-only input → nil (guard before regex).
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("") == nil)
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("   ") == nil)
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("\n\t") == nil)

        // Ignored exact-match strings (Zoom UI labels, not names).
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Mute") == nil)
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Unmute") == nil)
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Participants") == nil)
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Host") == nil)

        // Single-character "names" fail the min-length (>= 2) check.
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("A is speaking") == nil)

        // All-whitespace "names" are rejected by `cleaned`.
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("    is speaking") == nil)

        // "zoom"-prefixed strings are rejected (Zoom UI, not a participant).
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Zoom Host is speaking") == nil)

        // Names with @ are rejected (looks like an email / meeting ID).
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("user@example.com is speaking") == nil)

        // Each of the six supported label shapes must still parse.
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Alice Rivera, unmuted") == "Alice Rivera")
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Alice Rivera, unmuted audio") == "Alice Rivera")
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Bob is speaking") == "Bob")
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Bob is talking") == "Bob")
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Speaking: Carol") == "Carol")
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Active Speaker: Dan") == "Dan")
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("Eve, speaking") == "Eve")

        // Case-insensitive: "SPEAKING:" prefix matches.
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel("SPEAKING: Frank") == "Frank")

        // Gallery tile descriptions (with "Computer audio" / "Video on") are
        // roster metadata, NOT speaking labels — must be rejected.
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel(
            "Gui Lima, Computer audio unmuted, Video on") == nil)
        #expect(ZoomActiveSpeakerReader.parseSpeakingLabel(
            "Acquila Santos Rocha, Computer audio unmuted, Video on, active speaker") == nil)
    }

    @Test func testParseZoomCaptionLineEdgeCases() {
        // Empty / whitespace-only input → nil.
        #expect(ZoomActiveSpeakerReader.parseZoomCaptionLine("") == nil)
        #expect(ZoomActiveSpeakerReader.parseZoomCaptionLine("   \n  ") == nil)

        // Ignored exact-match names (Zoom UI labels) → nil.
        #expect(ZoomActiveSpeakerReader.parseZoomCaptionLine("Mute") == nil)
        #expect(ZoomActiveSpeakerReader.parseZoomCaptionLine("Participants: hello") == nil)

        // Tile descriptions are NOT caption lines (contain "Computer audio").
        #expect(ZoomActiveSpeakerReader.parseZoomCaptionLine(
            "Gui Lima, Computer audio unmuted, Video on") == nil)

        // Body too short (< 2 chars) → nil. The caption must have real content
        // after the colon, not just punctuation.
        #expect(ZoomActiveSpeakerReader.parseZoomCaptionLine("Alice: ") == nil)
        #expect(ZoomActiveSpeakerReader.parseZoomCaptionLine("Alice: x") == nil)

        // Well-formed caption lines parse name + body.
        let caption = ZoomActiveSpeakerReader.parseZoomCaptionLine("Gui Lima: hello everyone")
        #expect(caption?.name == "Gui Lima")
        #expect(caption?.text == "hello everyone")

        // "said:" variant captures a different speaker prefix.
        let said = ZoomActiveSpeakerReader.parseZoomCaptionLine("Paulo said: let's ship it")
        #expect(said?.name == "Paulo")
        #expect(said?.text == "let's ship it")

        // Surrounding whitespace on the raw line is trimmed before matching.
        let trimmed = ZoomActiveSpeakerReader.parseZoomCaptionLine("  Bob Chen: hi there  ")
        #expect(trimmed?.name == "Bob Chen")
        #expect(trimmed?.text == "hi there")

        // Single-character "name" → nil (min-length 2 in `cleaned`).
        #expect(ZoomActiveSpeakerReader.parseZoomCaptionLine("A: hello there") == nil)

        // All-numeric "name" (a phone/meeting ID) → nil.
        #expect(ZoomActiveSpeakerReader.parseZoomCaptionLine("12345: hello there") == nil)
    }
}
