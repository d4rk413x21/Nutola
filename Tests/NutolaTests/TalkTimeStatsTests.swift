import Foundation
import Testing
@testable import Nutola

struct TalkTimeStatsTests {
    // MARK: - Single speaker

    @Test func testSingleSpeaker() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 10, text: "Hello there"),
            TranscriptSegment(speakerID: "me", start: 10, end: 20, text: "world"),
        ]

        let stats = TalkTimeStats.compute(segments: segments, speakers: speakers)

        #expect(stats.count == 1)
        #expect(stats[0].speakerID == "me")
        #expect(abs((stats[0].talkTime) - (20)) <= 0.001)
        #expect(stats[0].segmentCount == 2)
        #expect(abs((stats[0].percentage) - (100)) <= 0.001)
    }

    // MARK: - Balanced split

    @Test func testTwoSpeakersBalanced() {
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
        ]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 30, text: "one two three four five"),
            TranscriptSegment(speakerID: "s1", start: 30, end: 60, text: "six seven eight nine ten"),
        ]

        let stats = TalkTimeStats.compute(segments: segments, speakers: speakers)

        #expect(stats.count == 2)
        for s in stats {
            #expect(abs((s.percentage) - (50)) <= 0.001)
        }
        #expect(abs((stats[0].talkTime) - (30)) <= 0.001)
        #expect(abs((stats[1].talkTime) - (30)) <= 0.001)
    }

    // MARK: - Word counting

    @Test func testWordCount() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "one two three"),
            TranscriptSegment(speakerID: "me", start: 1, end: 2, text: "four   five"),
            TranscriptSegment(speakerID: "me", start: 2, end: 3, text: "  six  "),
        ]

        let stats = TalkTimeStats.compute(segments: segments, speakers: speakers)

        #expect(stats.count == 1)
        #expect(stats[0].wordCount == 6)
    }

    @Test func testWordCountHelper() {
        #expect(TalkTimeStats.wordCount(in: "") == 0)
        #expect(TalkTimeStats.wordCount(in: "   ") == 0)
        #expect(TalkTimeStats.wordCount(in: "one") == 1)
        #expect(TalkTimeStats.wordCount(in: "one two three") == 3)
        #expect(TalkTimeStats.wordCount(in: "  one\ttwo\nthree  ") == 3)
    }

    // MARK: - Empty

    @Test func testEmptySegments() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        #expect(TalkTimeStats.compute(segments: [], speakers: speakers) == [])
    }

    // MARK: - Percentage

    @Test func testPercentageCalculation() throws {
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
            Speaker(id: "s2", name: "Bob"),
        ]
        // me: 10s (25%), s1: 20s (50%), s2: 10s (25%) → total 40s
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 10, text: "a b c"),
            TranscriptSegment(speakerID: "s1", start: 10, end: 30, text: "d e f g h"),
            TranscriptSegment(speakerID: "s2", start: 30, end: 40, text: "i j"),
        ]

        let stats = TalkTimeStats.compute(segments: segments, speakers: speakers)
        let byID = Dictionary(uniqueKeysWithValues: stats.map { ($0.speakerID, $0) })

        #expect(stats.count == 3)
        let me = try #require(byID["me"], "missing stats for 'me'")
        let alice = try #require(byID["s1"], "missing stats for 's1'")
        let bob = try #require(byID["s2"], "missing stats for 's2'")
        #expect(abs((me.percentage) - (25)) <= 0.001)
        #expect(abs((alice.percentage) - (50)) <= 0.001)
        #expect(abs((bob.percentage) - (25)) <= 0.001)
        // Percentages should sum to 100.
        let total = stats.reduce(0) { $0 + $1.percentage }
        #expect(abs((total) - (100)) <= 0.001)
    }

    // MARK: - Sorting

    @Test func testSortingByTalkTimeDescending() {
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
            Speaker(id: "s2", name: "Bob"),
        ]
        // Bob (s2) talks longest, then Me, then Alice — order should reflect that.
        let segments = [
            TranscriptSegment(speakerID: "s1", start: 0, end: 5, text: "hi"),
            TranscriptSegment(speakerID: "s2", start: 5, end: 25, text: "hello again"),
            TranscriptSegment(speakerID: "me", start: 25, end: 35, text: "ok"),
        ]

        let stats = TalkTimeStats.compute(segments: segments, speakers: speakers)

        #expect(stats.count == 3)
        #expect(stats.map { $0.speakerID } == ["s2", "me", "s1"])
        #expect(stats[0].name == "Bob")
        #expect(stats[1].name == "Me")
        #expect(stats[2].name == "Alice")
        // Strictly non-increasing.
        for i in 1..<stats.count {
            #expect(stats[i].talkTime <= stats[i - 1].talkTime)
        }
    }

    // MARK: - Unknown speaker uses ID as name

    @Test func testUnknownSpeakerFallsBackToID() {
        let segments = [TranscriptSegment(speakerID: "ghost", start: 0, end: 5, text: "boo")]
        let stats = TalkTimeStats.compute(segments: segments, speakers: [])
        #expect(stats.count == 1)
        #expect(stats[0].name == "ghost")
    }

    // MARK: - Zero-duration total does not divide by zero

    @Test func testZeroDurationTotalDoesNotDivideByZero() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        // All segments have end == start → zero talk time total.
        let segments = [
            TranscriptSegment(speakerID: "me", start: 5, end: 5, text: "hi"),
            TranscriptSegment(speakerID: "me", start: 5, end: 5, text: "there"),
        ]

        let stats = TalkTimeStats.compute(segments: segments, speakers: speakers)

        #expect(stats.count == 1)
        #expect(stats[0].talkTime == 0)
        #expect(stats[0].percentage == 0)
    }
}
