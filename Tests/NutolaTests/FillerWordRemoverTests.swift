import Foundation
import Testing
@testable import Nutola

struct FillerWordRemoverTests {
    @Test func testRemovesStandaloneFillers() {
        #expect(FillerWordRemover.clean("uh so I think we should um go with that") == "so I think we should go with that")
    }

    @Test func testPreservesPunctuation() {
        #expect(FillerWordRemover.clean("I, um, was thinking, uh, maybe later") == "I, was thinking, maybe later")
    }

    @Test func testDoesNotMatchSubstrings() {
        // "um" inside "album" must stay.
        #expect(FillerWordRemover.clean("the album is um amazing") == "the album is amazing")
    }

    @Test func testPortugueseFillers() {
        #expect(FillerWordRemover.clean("tipo, a gente faz assim né") == "a gente faz assim")
    }

    @Test func testCollapsesMultipleSpaces() {
        #expect(FillerWordRemover.clean("hmm let me see hmm okay") == "let me see okay")
    }

    @Test func testTrailingFiller() {
        #expect(FillerWordRemover.clean("trailing filler um") == "trailing filler")
    }
    @Test func testNoFillers() {
        let input = "no fillers here at all"
        #expect(FillerWordRemover.clean(input) == input)
    }

    @Test func testEmpty() {
        #expect(FillerWordRemover.clean("") == "")
    }

    @Test func testCustomFillerSet() {
        #expect(FillerWordRemover.clean("yknow like whatever", fillers: ["yknow", "like"]) == "whatever")
    }
}
