import Foundation
import Testing
@testable import Nutola

struct AdditionalParticipantsAnnotatorTests {
    // Always-false local check so "You" / account-holder detection is disabled
    // in tests — we want to test the calendar diff purely.
    private let neverLocal: (String) -> Bool = { _ in false }

    @Test func testNoRosterReturnsNil() {
        #expect(AdditionalParticipantsAnnotator.annotation(
            roster: [], attendees: ["Alice"], localParticipantCheck: neverLocal) == nil)
    }

    @Test func testAllRosterOnCalendarReturnsNil() {
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["Alice", "Bob"],
            attendees: ["Alice", "Bob"],
            localParticipantCheck: neverLocal)
        #expect(result == nil)
    }

    @Test func testListsExtrasNotOnCalendar() {
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["Alice", "Bob", "Lian Fernandes", "SiHun Sung"],
            attendees: ["Alice", "Bob"],
            localParticipantCheck: neverLocal)
        #expect(result != nil)
        #expect(result!.contains("Lian Fernandes"))
        #expect(result!.contains("SiHun Sung"))
        #expect(result!.contains("Additional participants"))
        #expect(result!.contains("not on the calendar invite"))
    }

    @Test func testExcludesLocalParticipant() {
        // Default local-participant check: "Taylor Morgan" is the Mac account holder.
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["Taylor Morgan", "Alice"],
            attendees: [],
            localParticipantCheck: { $0 == "Taylor Morgan" })
        #expect(result != nil)
        #expect(result!.contains("Alice"))
        #expect(!(result!.contains("Taylor Morgan")))
    }

    @Test func testCaseInsensitiveMatching() {
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["lian fernandes"],
            attendees: ["Lian Fernandes"],
            localParticipantCheck: neverLocal)
        #expect(result == nil, "Name matching should be case-insensitive")
    }

    @Test func testWhitespaceNormalized() {
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["Lian  Fernandes "],
            attendees: ["Lian Fernandes"],
            localParticipantCheck: neverLocal)
        #expect(result == nil, "Internal/trailing whitespace should not split matches")
    }

    @Test func testDedupsRoster() {
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["Lian Fernandes", "lian fernandes", "Lian Fernandes"],
            attendees: [],
            localParticipantCheck: neverLocal)
        #expect(result != nil)
        // The name appears only once in the output despite three roster entries.
        let occurrences = result!.components(separatedBy: "Lian Fernandes").count - 1
        #expect(occurrences == 1)
    }

    @Test func testEmptyAttendeesListsAllRemote() {
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["Alice", "Bob"],
            attendees: [],
            localParticipantCheck: { _ in false })
        #expect(result != nil)
        #expect(result!.contains("Alice"))
        #expect(result!.contains("Bob"))
    }

    @Test func testAnnotationFormatIsMarkdownHR() {
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["Alice"],
            attendees: [],
            localParticipantCheck: neverLocal)!
        #expect(result.hasPrefix("---"), "Annotation should start with a markdown horizontal rule")
    }
}
