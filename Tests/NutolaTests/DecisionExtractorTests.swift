import Foundation
import Testing
@testable import Nutola

struct DecisionExtractorTests {
    private let speakers = [
        Speaker(id: "me", name: "Me", isMe: true),
        Speaker(id: "s1", name: "Alice"),
    ]

    // MARK: - Phrase matching

    @Test func testExtractLetsGoWith() {
        let segments = [TranscriptSegment(speakerID: "me", start: 0, end: 2, text: "let's go with option A")]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        #expect(decisions.count == 1)
        #expect(decisions.first?.quote == "let's go with option A")
    }

    @Test func testExtractWeDecided() {
        let segments = [TranscriptSegment(speakerID: "s1", start: 10, end: 14, text: "we decided to launch next week")]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        #expect(decisions.count == 1)
        #expect(decisions.first?.quote == "we decided to launch next week")
    }

    @Test func testExtractMultipleDecisions() {
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "let's go with option A"),
            TranscriptSegment(speakerID: "s1", start: 5, end: 6, text: "we decided to launch next week"),
            TranscriptSegment(speakerID: "me", start: 10, end: 11, text: "let's do the migration on Friday"),
        ]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        #expect(decisions.count == 3)
    }

    @Test func testNoDecisionInRegularText() {
        let segments = [TranscriptSegment(speakerID: "me", start: 0, end: 2, text: "I think the weather is nice today")]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        #expect(decisions.isEmpty)
    }

    @Test func testCaseInsensitive() {
        let segments = [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "LET'S GO WITH PLAN B")]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        #expect(decisions.count == 1)
    }

    // MARK: - Metadata

    @Test func testSpeakerNameResolved() {
        let segments = [TranscriptSegment(speakerID: "s1", start: 0, end: 1, text: "we should use the new framework")]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        #expect(decisions.count == 1)
        #expect(decisions.first?.speakerName == "Alice")
        #expect(decisions.first?.speakerID == "s1")
    }

    @Test func testTimestampExtracted() {
        let segments = [TranscriptSegment(speakerID: "me", start: 125, end: 130, text: "the plan is to ship in Q3")]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        #expect(decisions.first?.timestamp == 125)
    }

    // MARK: - Deduplication

    @Test func testDeduplication() {
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "let's go with option A for the redesign"),
            TranscriptSegment(speakerID: "s1", start: 30, end: 31, text: "let's go with option A for the redesign"),
        ]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        #expect(decisions.count == 1)
    }
}
