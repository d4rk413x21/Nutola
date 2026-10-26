import Foundation
import Testing
@testable import Nutola

struct TalkTimeAggregatorTests {
    // MARK: - Single speaker, single meeting

    @Test func testSingleSpeakerSingleMeeting() throws {
        let meeting = Meeting(title: "M1", createdAt: Date(), duration: 60)
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 60, text: "talking alone"),
        ]

        let summaries = TalkTimeAggregator.aggregate(
            meetings: [meeting],
            transcripts: [(meeting.id, segments)],
            speakers: [(meeting.id, speakers)])

        #expect(summaries.count == 1)
        let s = try #require(summaries.first)
        #expect(s.speakerID == "me")
        #expect(s.name == "Me")
        #expect(abs((s.totalTalkTime) - (60)) <= 0.001)
        #expect(s.meetingCount == 1)
        #expect(abs((s.avgTalkTimePerMeeting) - (60)) <= 0.001)
        #expect(abs((s.percentageOfTotal) - (100)) <= 0.001)
    }

    // MARK: - Multiple speakers aggregated across meetings

    @Test func testMultipleSpeakersAggregated() throws {
        let m1 = Meeting(title: "M1", createdAt: Date(), duration: 60)
        let m2 = Meeting(title: "M2", createdAt: Date(), duration: 60)
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
        ]

        // M1: me 30s, Alice 30s
        let seg1 = [
            TranscriptSegment(speakerID: "me", start: 0, end: 30, text: "hi"),
            TranscriptSegment(speakerID: "s1", start: 30, end: 60, text: "hello"),
        ]
        // M2: me 20s, Alice 40s
        let seg2 = [
            TranscriptSegment(speakerID: "me", start: 0, end: 20, text: "yo"),
            TranscriptSegment(speakerID: "s1", start: 20, end: 60, text: "hey"),
        ]

        let summaries = TalkTimeAggregator.aggregate(
            meetings: [m1, m2],
            transcripts: [(m1.id, seg1), (m2.id, seg2)],
            speakers: [(m1.id, speakers), (m2.id, speakers)])

        let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.speakerID, $0) })
        #expect(summaries.count == 2)
        let me = try #require(byID["me"])
        let alice = try #require(byID["alice"])
        #expect(abs((me.totalTalkTime) - (50)) <= 0.001)
        #expect(abs((alice.totalTalkTime) - (70)) <= 0.001)
        #expect(me.meetingCount == 2)
        #expect(alice.meetingCount == 2)
    }

    // MARK: - Average per meeting

    @Test func testAvgPerMeeting() throws {
        let m1 = Meeting(title: "M1", createdAt: Date(), duration: 60)
        let m2 = Meeting(title: "M2", createdAt: Date(), duration: 90)
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]

        // M1: 30s, M2: 60s → total 90s across 2 meetings → avg 45s
        let seg1 = [TranscriptSegment(speakerID: "me", start: 0, end: 30, text: "x")]
        let seg2 = [TranscriptSegment(speakerID: "me", start: 0, end: 60, text: "y")]

        let summaries = TalkTimeAggregator.aggregate(
            meetings: [m1, m2],
            transcripts: [(m1.id, seg1), (m2.id, seg2)],
            speakers: [(m1.id, speakers), (m2.id, speakers)])

        let s = try #require(summaries.first)
        #expect(abs((s.totalTalkTime) - (90)) <= 0.001)
        #expect(s.meetingCount == 2)
        #expect(abs((s.avgTalkTimePerMeeting) - (45)) <= 0.001)
    }

    // MARK: - Percentage of total

    @Test func testPercentageOfTotal() throws {
        let meeting = Meeting(title: "M1", createdAt: Date(), duration: 60)
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
        ]
        // me: 10s, s1: 30s → total 40s → me 25%, s1 75%
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 10, text: "a"),
            TranscriptSegment(speakerID: "s1", start: 10, end: 40, text: "b c d"),
        ]

        let summaries = TalkTimeAggregator.aggregate(
            meetings: [meeting],
            transcripts: [(meeting.id, segments)],
            speakers: [(meeting.id, speakers)])

        let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.speakerID, $0) })
        let me = try #require(byID["me"])
        let alice = try #require(byID["alice"])
        #expect(abs((me.percentageOfTotal) - (25)) <= 0.001)
        #expect(abs((alice.percentageOfTotal) - (75)) <= 0.001)
        // Percentages should sum to 100.
        let total = summaries.reduce(0) { $0 + $1.percentageOfTotal }
        #expect(abs((total) - (100)) <= 0.001)
    }

    // MARK: - Empty input

    @Test func testEmptyInput() {
        let summaries = TalkTimeAggregator.aggregate(
            meetings: [],
            transcripts: [],
            speakers: [])
        #expect(summaries.isEmpty)
    }

    // MARK: - Meeting without transcript is skipped

    @Test func testMeetingWithoutTranscript() throws {
        let m1 = Meeting(title: "M1", createdAt: Date(), duration: 60)
        let m2 = Meeting(title: "M2", createdAt: Date(), duration: 0)
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let seg1 = [TranscriptSegment(speakerID: "me", start: 0, end: 30, text: "x")]

        // m2 has no transcript entry and no segments — should be skipped, not counted.
        let summaries = TalkTimeAggregator.aggregate(
            meetings: [m1, m2],
            transcripts: [(m1.id, seg1)],
            speakers: [(m1.id, speakers), (m2.id, speakers)])

        #expect(summaries.count == 1)
        let s = try #require(summaries.first)
        #expect(s.speakerID == "me")
        #expect(s.meetingCount == 1)
        #expect(abs((s.totalTalkTime) - (30)) <= 0.001)
    }

    // MARK: - Sorting by talk time descending

    @Test func testSortingByTalkTimeDescending() {
        let m1 = Meeting(title: "M1", createdAt: Date(), duration: 60)
        let m2 = Meeting(title: "M2", createdAt: Date(), duration: 60)
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
            Speaker(id: "s2", name: "Bob"),
        ]

        // M1: me 10s, s1 30s, s2 20s
        let seg1 = [
            TranscriptSegment(speakerID: "me", start: 0, end: 10, text: "a"),
            TranscriptSegment(speakerID: "s1", start: 10, end: 40, text: "b"),
            TranscriptSegment(speakerID: "s2", start: 40, end: 60, text: "c"),
        ]
        // M2: me 50s, s1 10s
        let seg2 = [
            TranscriptSegment(speakerID: "me", start: 0, end: 50, text: "d"),
            TranscriptSegment(speakerID: "s1", start: 50, end: 60, text: "e"),
        ]
        // Totals: me 60s, s1 40s, s2 20s → sorted [me, s1, s2]

        let summaries = TalkTimeAggregator.aggregate(
            meetings: [m1, m2],
            transcripts: [(m1.id, seg1), (m2.id, seg2)],
            speakers: [(m1.id, speakers), (m2.id, speakers)])

        #expect(summaries.map { $0.speakerID } == ["me", "alice", "bob"])
        #expect(abs((summaries[0].totalTalkTime) - (60)) <= 0.001)
        #expect(abs((summaries[1].totalTalkTime) - (40)) <= 0.001)
        #expect(abs((summaries[2].totalTalkTime) - (20)) <= 0.001)
    }

    // MARK: - Same display name across meetings collapses (the bug fix)

    @Test func testSameDisplayNameAcrossMeetingsMerges() throws {
        // The original bug: SpeakerLabeler resets IDs per meeting, so "Gui Lima"
        // appears as s1 in M1 and s2 in M2 — the aggregator used to emit two
        // rows. With name-based keying they should collapse into one.
        let m1 = Meeting(title: "M1", createdAt: Date(), duration: 60)
        let m2 = Meeting(title: "M2", createdAt: Date(), duration: 60)
        let speakersM1 = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Gui Lima")]
        let speakersM2 = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s2", name: "Gui Lima")]

        let seg1 = [
            TranscriptSegment(speakerID: "me", start: 0, end: 10, text: "a"),
            TranscriptSegment(speakerID: "s1", start: 10, end: 40, text: "b"),
        ]
        let seg2 = [
            TranscriptSegment(speakerID: "me", start: 0, end: 10, text: "c"),
            TranscriptSegment(speakerID: "s2", start: 10, end: 30, text: "d"),
        ]

        let summaries = TalkTimeAggregator.aggregate(
            meetings: [m1, m2],
            transcripts: [(m1.id, seg1), (m2.id, seg2)],
            speakers: [(m1.id, speakersM1), (m2.id, speakersM2)])

        // Two rows: "Me" and "Gui Lima" — NOT three.
        #expect(summaries.count == 2)
        let gui = try #require(summaries.first { $0.name == "Gui Lima" })
        // 30s (M1) + 20s (M2) = 50s, across 2 meetings.
        #expect(abs((gui.totalTalkTime) - (50)) <= 0.001)
        #expect(gui.meetingCount == 2)
    }

    @Test func testNameKeyNormalizes() {
        // Case + whitespace differences collapse to one key.
        #expect(TalkTimeAggregator.nameKey("Gui Lima") == TalkTimeAggregator.nameKey("gui lima"))
        #expect(TalkTimeAggregator.nameKey("Gui  Lima ") == TalkTimeAggregator.nameKey("Gui Lima"))
        #expect(TalkTimeAggregator.nameKey("  ") == "")
    }
}
