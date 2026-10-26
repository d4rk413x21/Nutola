import Foundation
import Testing
@testable import Nutola

struct TranscriptChapterizerTests {
    // MARK: - Helpers

    /// Build a turn with sensible defaults; `end` defaults to `start + 4`.
    private func turn(
        id: String,
        speakerID: String = "me",
        start: TimeInterval,
        end: TimeInterval? = nil,
        text: String = "A short turn."
    ) -> TranscriptTurn {
        TranscriptTurn(
            id: id, speakerID: speakerID, start: start,
            end: end ?? start + 4, text: text, segmentCount: 1)
    }

    /// A long-ish single-speaker transcript with no pauses or topic shifts —
    /// one continuous chapter.
    private func singleChapterTurns() -> [TranscriptTurn] {
        (0..<8).map { i in
            turn(id: "t\(i)", start: TimeInterval(i * 10),
                 text: "Turn number \(i) keeps the conversation going.")
        }
    }

    // MARK: - Tests

    @Test func testSingleChapter() {
        let chapters = TranscriptChapterizer.chapterize(turns: singleChapterTurns())
        #expect(chapters.count == 1)
        #expect(chapters[0].turnIndices == 0..<8)
        #expect(chapters[0].startTime == 0)
        #expect(chapters[0].endTime == 74) // last turn start 70 + 4
    }

    @Test func testPauseSplit() {
        // Two clusters separated by a >30s gap → two chapters.
        let turns = [
            turn(id: "a0", start: 0, text: "First cluster opening."),
            turn(id: "a1", start: 5, text: "First cluster continued."),
            // 30s+ gap after turn a1 (end=9, next start=45 → gap=36s).
            turn(id: "b0", start: 45, text: "Second cluster opening after the pause."),
            turn(id: "b1", start: 50, text: "Second cluster continued."),
        ]
        let chapters = TranscriptChapterizer.chapterize(turns: turns, minChapterDuration: 1)
        #expect(chapters.count == 2)
        #expect(chapters[0].turnIndices == 0..<2)
        #expect(chapters[1].turnIndices == 2..<4)
    }

    @Test func testTopicShiftSplit() {
        // No pause between turns, but the third turn opens with "let's talk
        // about" → a new chapter starts at the third turn.
        let turns = [
            turn(id: "a0", start: 0, text: "Welcome everyone, let's get started."),
            turn(id: "a1", start: 8, text: "First we review last week."),
            turn(id: "b0", start: 16, text: "Now let's talk about the roadmap for Q3."),
            turn(id: "b1", start: 24, text: "The roadmap has three milestones."),
            turn(id: "b2", start: 32, text: "First milestone ships in August."),
        ]
        let chapters = TranscriptChapterizer.chapterize(turns: turns, minChapterDuration: 1)
        #expect(chapters.count >= 2)
        // The chapter break must land at the topic-shift turn (index 2).
        #expect(chapters.contains { $0.turnIndices.lowerBound == 2 })
        // The chapter starting at index 2 should be titled from the keyword.
        if let shiftChapter = chapters.first(where: { $0.turnIndices.lowerBound == 2 }) {
            #expect(!(shiftChapter.title.isEmpty))
        }
    }

    @Test func testMinChapterDuration() {
        // A very short middle chapter (<60s) gets merged into the previous one
        // so we end up with fewer chapters than the raw pause-based split.
        let turns = [
            // Long first chapter: 0..40s.
            turn(id: "a0", start: 0, text: "Long opening discussion part one."),
            turn(id: "a1", start: 20, text: "Long opening discussion part two."),
            // Short middle chapter: 100..108s (only 8s long, < 60s).
            turn(id: "b0", start: 100, text: "Brief aside here."),
            // Long final chapter: 200..240s, well over 60s.
            turn(id: "c0", start: 200, text: "A substantial new topic with real content."),
            turn(id: "c1", start: 220, text: "Continuing the substantial new topic."),
            turn(id: "c2", start: 232, text: "More on the substantial new topic."),
        ]
        // With a 30s+ pause between each cluster, the raw split would give 3
        // chapters. With minChapterDuration=60, the 8s middle chapter merges
        // into the first chapter.
        let merged = TranscriptChapterizer.chapterize(turns: turns, minChapterDuration: 60)
        let unmerged = TranscriptChapterizer.chapterize(turns: turns, minChapterDuration: 1)

        #expect(unmerged.count > merged.count)
        // The short middle chapter must be absorbed, so we keep turn coverage.
        let mergedCount = merged.reduce(0) { $0 + $1.turnIndices.count }
        #expect(mergedCount == turns.count)
        // No leftover chapter should be shorter than the minimum.
        for c in merged.dropFirst() {
            #expect(c.endTime - c.startTime >= 60)
        }
    }

    @Test func testEmptyTurns() {
        #expect(TranscriptChapterizer.chapterize(turns: []) == [])
    }

    @Test func testChapterTitle() {
        let chapters = TranscriptChapterizer.chapterize(turns: singleChapterTurns())
        #expect(chapters.count == 1)
        #expect(!(chapters[0].title.isEmpty))
        // Title should derive from the opening turn's first words.
        #expect(chapters[0].title.lowercased().contains("turn"))
    }

    @Test func testMultipleSpeakers() {
        // 6 turns by "me" (a monologue of ≥5), then a speaker switch to "s1".
        // The speaker change after the monologue opens a new chapter.
        var turns: [TranscriptTurn] = []
        for i in 0..<6 {
            turns.append(turn(id: "me-\(i)", speakerID: "me",
                             start: TimeInterval(i * 8),
                             text: "I am explaining point \(i) at length."))
        }
        for i in 0..<3 {
            turns.append(turn(id: "s1-\(i)", speakerID: "s1",
                             start: TimeInterval(48 + i * 8),
                             text: "Now I have a question about point \(i)."))
        }
        let chapters = TranscriptChapterizer.chapterize(turns: turns, minChapterDuration: 1)
        #expect(chapters.count >= 2)
        // The new chapter must begin exactly where the speaker changes (index 6).
        #expect(chapters.contains { $0.turnIndices.lowerBound == 6 })
    }

    @Test func testChapterTimeRange() {
        // The chapter's start must equal the first turn's start and its end
        // must equal the last turn's end.
        let turns = [
            turn(id: "x0", start: 12, end: 18, text: "Opening turn."),
            turn(id: "x1", start: 20, end: 27, text: "Middle turn."),
            turn(id: "x2", start: 30, end: 41, text: "Closing turn."),
        ]
        let chapters = TranscriptChapterizer.chapterize(turns: turns, minChapterDuration: 1)
        #expect(chapters.count == 1)
        #expect(chapters[0].startTime == 12)
        #expect(chapters[0].endTime == 41)
        #expect(chapters[0].turnIndices == 0..<3)
    }

    @Test func testAlwaysAtLeastOneChapter() {
        // A single turn yields exactly one chapter.
        let turns = [turn(id: "solo", start: 0, end: 2, text: "Hello world.")]
        let chapters = TranscriptChapterizer.chapterize(turns: turns)
        #expect(chapters.count == 1)
        #expect(chapters[0].turnIndices == 0..<1)
    }

    @Test func testKeywordTitlePreferredOverLeadingWords() {
        // When a topic-shift keyword is present, the chapter title should come
        // from the keyword rather than the leading words of the turn.
        let turns = [
            turn(id: "a0", start: 0, text: "Quick intro before we move on."),
            turn(id: "b0", start: 10, text: "Now let's talk about the budget forecast."),
            turn(id: "b1", start: 20, text: "The budget forecast looks healthy."),
        ]
        let chapters = TranscriptChapterizer.chapterize(turns: turns, minChapterDuration: 1)
        #expect(chapters.count >= 2)
        if let shiftChapter = chapters.first(where: { $0.turnIndices.lowerBound == 1 }) {
            // Title should derive from "let's talk about" rather than the
            // literal leading words "Now let's talk about the budget forecast."
            #expect(shiftChapter.title.lowercased().contains("talk about"))
        }
    }

    @Test func testChaptersCoverAllTurnsExactlyOnce() {
        // Across a mixed transcript, the union of chapter turn-ranges must
        // equal the full turn range with no gaps or overlaps.
        let turns: [TranscriptTurn] = [
            turn(id: "a0", start: 0, text: "Welcome and kickoff."),
            turn(id: "a1", start: 10, text: "Agenda item one discussion."),
            turn(id: "b0", start: 120, text: "Let's move on to the next item."),
            turn(id: "b1", start: 130, text: "Discussing the next item in detail now."),
            turn(id: "c0", start: 240, text: "Final remarks and wrap up."),
        ]
        let chapters = TranscriptChapterizer.chapterize(turns: turns, minChapterDuration: 30)
        #expect(!(chapters.isEmpty))
        // Ranges are contiguous and cover every turn.
        var cursor = 0
        for c in chapters {
            #expect(c.turnIndices.lowerBound == cursor)
            cursor = c.turnIndices.upperBound
        }
        #expect(cursor == turns.count)
    }
}
