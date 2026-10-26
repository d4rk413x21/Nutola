import Foundation
import Testing
@testable import Nutola

struct SentimentAnalyzerTests {
    // MARK: - Positive

    @Test func testPositiveSentiment() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 5,
                             text: "This is great, excellent work today."),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)

        #expect(results.count == 1)
        #expect(results[0].sentiment == .positive)
        #expect(results[0].speakerID == "me")
        #expect(results[0].speakerName == "Me")
        #expect(results[0].segmentIndex == 0)
    }

    // MARK: - Negative

    @Test func testNegativeSentiment() {
        let speakers = [Speaker(id: "s1", name: "Alice")]
        let segments = [
            TranscriptSegment(speakerID: "s1", start: 0, end: 5,
                             text: "I have a problem and a real concern with this."),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)

        #expect(results.count == 1)
        #expect(results[0].sentiment == .negative)
        #expect(results[0].speakerName == "Alice")
    }

    // MARK: - Critical (precedence over negative and positive)

    @Test func testCriticalSentiment() {
        let speakers = [Speaker(id: "s1", name: "Alice")]
        let segments = [
            TranscriptSegment(speakerID: "s1", start: 0, end: 5,
                             text: "This is urgent, a blocker and a real risk for the launch."),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)

        #expect(results.count == 1)
        #expect(results[0].sentiment == .critical)
    }

    @Test func testCriticalBeatsNegativeWhenBothPresent() {
        // Precedence: critical > negative > positive. A segment mentioning
        // "problem" (negative) and "blocker" (critical) reads critical.
        let speakers = [Speaker(id: "s1", name: "Alice")]
        let segments = [
            TranscriptSegment(speakerID: "s1", start: 0, end: 5,
                             text: "We have a problem and this is a blocker."),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)
        #expect(results[0].sentiment == .critical)
    }

    // MARK: - Neutral default

    @Test func testNeutralDefault() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 5,
                             text: "Let's talk about the agenda for today."),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)

        #expect(results.count == 1)
        #expect(results[0].sentiment == .neutral)
        #expect(abs((results[0].score) - (0)) <= 0.0001)
    }

    // MARK: - Score calculation

    @Test func testScoreCalculation() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        // 6 words, 2 positive keywords → score = 2/6 ≈ 0.333.
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 5,
                             text: "great love the meeting notes today"),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)

        #expect(results.count == 1)
        #expect(results[0].sentiment == .positive)
        #expect(abs((results[0].score) - (2.0 / 6.0)) <= 0.0001)
        // Bounded in [0, 1].
        #expect(results[0].score >= 0)
        #expect(results[0].score <= 1)
    }

    @Test func testScoreIsBounded() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        // Every word is a keyword → score should be 1.0, never above.
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 5,
                             text: "great love agree"),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)
        #expect(abs((results[0].score) - (1.0)) <= 0.0001)
    }

    // MARK: - Empty input

    @Test func testEmptySegments() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let results = SentimentAnalyzer.analyze(segments: [], speakers: speakers)
        #expect(results.isEmpty)
    }

    @Test func testEmptySpeakersStillClassifies() {
        // No speakers list — name falls back to speakerID.
        let segments = [
            TranscriptSegment(speakerID: "ghost", start: 0, end: 3, text: "great point"),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: [])
        #expect(results.count == 1)
        #expect(results[0].sentiment == .positive)
        #expect(results[0].speakerName == "ghost")
    }

    // MARK: - Multiple speakers

    @Test func testMultipleSpeakers() {
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
            Speaker(id: "s2", name: "Bob"),
        ]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 5,
                             text: "This is excellent, great plan."),
            TranscriptSegment(speakerID: "s1", start: 5, end: 10,
                             text: "I disagree, this is wrong."),
            TranscriptSegment(speakerID: "s2", start: 10, end: 15,
                             text: "Let's review the notes."),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)

        #expect(results.count == 3)
        #expect(results[0].speakerID == "me")
        #expect(results[0].sentiment == .positive)
        #expect(results[1].speakerID == "s1")
        #expect(results[1].sentiment == .negative)
        #expect(results[2].speakerID == "s2")
        #expect(results[2].sentiment == .neutral)

        // Names resolved from the speakers list, not bare IDs.
        #expect(results[0].speakerName == "Me")
        #expect(results[1].speakerName == "Alice")
        #expect(results[2].speakerName == "Bob")

        // Segment indices track the input order.
        #expect(results.map(\.segmentIndex) == [0, 1, 2])
    }

    // MARK: - Punctuation robustness

    @Test func testPunctuationStripped() {
        // "great!" and "love," should still register as keywords.
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 3,
                             text: "great! love, agree."),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)
        #expect(results[0].sentiment == .positive)
        #expect(abs((results[0].score) - (1.0)) <= 0.0001)
    }

    // MARK: - Identifiable

    @Test func testSpeakerSentimentID() {
        let entry = SpeakerSentiment(
            speakerID: "s1", speakerName: "Alice",
            sentiment: .positive, score: 0.5, segmentIndex: 3)
        #expect(entry.id == "s1-3")
    }

    // MARK: - Sentiment metadata

    @Test func testSentimentEmojiAndColorNonEmpty() {
        // Every case has a distinct emoji and a 6-hex color.
        for sentiment in Sentiment.allCases {
            #expect(!(sentiment.emoji.isEmpty), "emoji empty for \(sentiment)")
            #expect(sentiment.color.hasPrefix("#"), "color not hex for \(sentiment)")
            #expect(sentiment.color.count == 7, "color not 6-hex for \(sentiment)")
        }
    }
}
