import Foundation
import Testing
@testable import Nutola

struct TranscriptTurnBuilderTests {
    @Test func testTurnsGroupConsecutiveSameSpeaker() {
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Hi"),
            TranscriptSegment(speakerID: "me", start: 1, end: 2, text: "there"),
            TranscriptSegment(speakerID: "s1", start: 2, end: 3, text: "Hello"),
            TranscriptSegment(speakerID: "me", start: 3, end: 4, text: "again"),
        ]
        let turns = TranscriptTurnBuilder.turns(from: segments)
        #expect(turns.count == 3)
        #expect(turns[0].id == "me-0")
        #expect(turns[0].speakerID == "me")
        #expect(turns[0].text == "Hi there")
        #expect(turns[0].start == 0)
        #expect(turns[0].end == 2)
        #expect(turns[0].segmentCount == 2)
        #expect(turns[1].speakerID == "s1")
        #expect(turns[1].text == "Hello")
        #expect(turns[1].end == 3)
        #expect(turns[2].text == "again")
        #expect(turns[2].start == 3)
        #expect(turns[2].end == 4)
    }

    @Test func testTurnsEmpty() {
        #expect(TranscriptTurnBuilder.turns(from: []).isEmpty)
    }

    @Test func testTurnEndTimeUsesLastSegment() {
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 5, text: "a"),
            TranscriptSegment(speakerID: "me", start: 5, end: 12, text: "b"),
        ]
        let turns = TranscriptTurnBuilder.turns(from: segments)
        #expect(turns.count == 1)
        #expect(turns[0].end == 12)
        #expect(turns[0].segmentCount == 2)
    }

    // MARK: - #86: edge cases for overlapping and out-of-order segments

    @Test func testOverlappingSegments() {
        // Overlapping time bounds for the same speaker are still merged into
        // one turn — the builder trusts segment order, not interval math, and
        // extends `end` to the last segment's end.
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 4, text: "alpha"),
            TranscriptSegment(speakerID: "me", start: 1, end: 3, text: "beta"),  // nested overlap
            TranscriptSegment(speakerID: "me", start: 5, end: 6, text: "gamma"),
        ]
        let turns = TranscriptTurnBuilder.turns(from: segments)
        #expect(turns.count == 1)
        #expect(turns[0].speakerID == "me")
        #expect(turns[0].text == "alpha beta gamma")
        #expect(turns[0].start == 0)
        #expect(turns[0].end == 6)
        #expect(turns[0].segmentCount == 3)
    }

    @Test func testOutOfOrderSegments() {
        // Segments are grouped by consecutive speakerID; a later segment with an
        // earlier start time still appends in list order (the builder does not
        // re-sort). Verifies the grouping is position-based, not time-based.
        let segments = [
            TranscriptSegment(speakerID: "me", start: 10, end: 12, text: "late"),
            TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "early"),  // out-of-order time
        ]
        let turns = TranscriptTurnBuilder.turns(from: segments)
        #expect(turns.count == 1)
        #expect(turns[0].text == "late early")
        // Start is taken from the first segment in list order, not the min.
        #expect(turns[0].start == 10)
        // End is the last segment's end.
        #expect(turns[0].end == 1)
        #expect(turns[0].segmentCount == 2)
    }
}
