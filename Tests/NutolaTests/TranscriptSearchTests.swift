import Foundation
import Testing
@testable import Nutola

struct TranscriptSearchTests {
    private func makeTurns() -> [TranscriptTurn] {
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Hello world"),
            TranscriptSegment(speakerID: "s1", start: 1, end: 2, text: "Hi there"),
            TranscriptSegment(speakerID: "me", start: 2, end: 3, text: "Goodbye"),
        ]
        return TranscriptTurnBuilder.turns(from: segments)
    }

    @Test func testEmptySearchReturnsAll() {
        let turns = makeTurns()
        let filtered = TranscriptTurnBuilder.filter(turns: turns, by: "")
        #expect(filtered.count == turns.count)
    }

    @Test func testCaseInsensitiveMatch() {
        let turns = makeTurns()
        let filtered = TranscriptTurnBuilder.filter(turns: turns, by: "HELLO")
        #expect(filtered.count == 1)
        #expect(filtered.first?.text == "Hello world")
    }

    @Test func testPartialMatch() {
        let turns = makeTurns()
        let filtered = TranscriptTurnBuilder.filter(turns: turns, by: "good")
        #expect(filtered.count == 1)
        #expect(filtered.first?.text == "Goodbye")
    }

    @Test func testNoResults() {
        let turns = makeTurns()
        let filtered = TranscriptTurnBuilder.filter(turns: turns, by: "nonexistent")
        #expect(filtered.isEmpty)
    }

    @Test func testEmptyTurnsEmptySearch() {
        #expect(TranscriptTurnBuilder.filter(turns: [], by: "").isEmpty)
    }

    @Test func testEmptyTurnsNonEmptySearch() {
        #expect(TranscriptTurnBuilder.filter(turns: [], by: "x").isEmpty)
    }
}
