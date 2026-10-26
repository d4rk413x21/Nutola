import Foundation
import Testing
@testable import Nutola

struct SpeakerTurnMergerTests {
    private func turn(_ speaker: String, _ start: TimeInterval, _ end: TimeInterval) -> DiarizedTurn {
        DiarizedTurn(speaker: speaker, start: start, end: end)
    }

    private func event(
        _ name: String, _ start: TimeInterval, _ end: TimeInterval,
        source: PlatformSpeakerSource = .activeSpeaker
    ) -> PlatformSpeakerEvent {
        PlatformSpeakerEvent(name: name, start: start, end: end, source: source)
    }

    @Test func testPlatformOnlyWhenNoDiarization() {
        let events = [event("Alice", 0, 5), event("Bob", 6, 10)]
        let result = SpeakerTurnMerger.merge(platformEvents: events, diarized: [])
        #expect(result.turns.map(\.speaker) == ["Alice", "Bob"])
        #expect(result.hasNamedSpeakers)
    }

    @Test func testDiarizationOnlyWhenNoPlatform() {
        let diarized = [turn("S1", 0, 4), turn("S2", 5, 9)]
        let result = SpeakerTurnMerger.merge(platformEvents: [], diarized: diarized)
        #expect(result.turns.count == 2)
        #expect(!(result.hasNamedSpeakers))
    }

    @Test func testHybridFillsGapsWithMappedClusters() {
        // Zoom caught Alice 0-3s; diarization has S1 0-10 and S2 10-20.
        let events = [event("Alice", 0, 3)]
        let diarized = [turn("S1", 0, 10), turn("S2", 10, 20)]
        let result = SpeakerTurnMerger.merge(platformEvents: events, diarized: diarized)

        #expect(result.turns.contains { $0.speaker == "Alice" && $0.start == 0 && $0.end == 10 })
        #expect(result.turns.contains { $0.speaker == "S2" && $0.start == 10 })
        #expect(result.hasNamedSpeakers)
    }

    @Test func testPlatformWinsOnOverlap() {
        let events = [event("Alice", 2, 6)]
        let diarized = [turn("S1", 0, 8)]
        let result = SpeakerTurnMerger.merge(platformEvents: events, diarized: diarized)

        // S1 maps to Alice via overlap; the whole cluster inherits the Zoom name.
        #expect(result.turns.count == 1)
        #expect(result.turns[0].speaker == "Alice")
        #expect(result.turns[0].start == 0)
        #expect(result.turns[0].end == 8)
    }

    @Test func testCaptionEventsMapClusters() {
        let events = [
            event("Bob", 5, 6, source: .caption),
            event("Bob", 12, 13, source: .caption),
        ]
        let diarized = [turn("S1", 0, 20)]
        let result = SpeakerTurnMerger.merge(platformEvents: events, diarized: diarized)
        #expect(result.turns.allSatisfy { $0.speaker == "Bob" })
    }

    @Test func testRosterHintMapsSingleLeftoverCluster() {
        let events = [event("Alice", 0, 5)]
        let diarized = [turn("S1", 0, 5), turn("S2", 6, 12)]
        let result = SpeakerTurnMerger.merge(
            platformEvents: events, diarized: diarized, roster: ["Alice", "Bob"], attendees: [])
        #expect(result.turns.contains { $0.speaker == "Bob" && $0.start >= 6 })
    }
}
