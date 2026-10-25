import XCTest
@testable import Nutola

final class AdditionalParticipantsAnnotatorTests: XCTestCase {
    // Always-false local check so "You" / account-holder detection is disabled
    // in tests — we want to test the calendar diff purely.
    private let neverLocal: (String) -> Bool = { _ in false }

    func testNoRosterReturnsNil() {
        XCTAssertNil(AdditionalParticipantsAnnotator.annotation(
            roster: [], attendees: ["Alice"], localParticipantCheck: neverLocal))
    }

    func testAllRosterOnCalendarReturnsNil() {
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["Alice", "Bob"],
            attendees: ["Alice", "Bob"],
            localParticipantCheck: neverLocal)
        XCTAssertNil(result)
    }

    func testListsExtrasNotOnCalendar() {
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["Alice", "Bob", "Lian Fernandes", "SiHun Sung"],
            attendees: ["Alice", "Bob"],
            localParticipantCheck: neverLocal)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Lian Fernandes"))
        XCTAssertTrue(result!.contains("SiHun Sung"))
        XCTAssertTrue(result!.contains("Additional participants"))
        XCTAssertTrue(result!.contains("not on the calendar invite"))
    }

    func testExcludesLocalParticipant() {
        // Default local-participant check: "Taylor Morgan" is the Mac account holder.
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["Taylor Morgan", "Alice"],
            attendees: [],
            localParticipantCheck: { $0 == "Taylor Morgan" })
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Alice"))
        XCTAssertFalse(result!.contains("Taylor Morgan"))
    }

    func testCaseInsensitiveMatching() {
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["lian fernandes"],
            attendees: ["Lian Fernandes"],
            localParticipantCheck: neverLocal)
        XCTAssertNil(result, "Name matching should be case-insensitive")
    }

    func testWhitespaceNormalized() {
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["Lian  Fernandes "],
            attendees: ["Lian Fernandes"],
            localParticipantCheck: neverLocal)
        XCTAssertNil(result, "Internal/trailing whitespace should not split matches")
    }

    func testDedupsRoster() {
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["Lian Fernandes", "lian fernandes", "Lian Fernandes"],
            attendees: [],
            localParticipantCheck: neverLocal)
        XCTAssertNotNil(result)
        // The name appears only once in the output despite three roster entries.
        let occurrences = result!.components(separatedBy: "Lian Fernandes").count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testEmptyAttendeesListsAllRemote() {
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["Alice", "Bob"],
            attendees: [],
            localParticipantCheck: { _ in false })
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Alice"))
        XCTAssertTrue(result!.contains("Bob"))
    }

    func testAnnotationFormatIsMarkdownHR() {
        let result = AdditionalParticipantsAnnotator.annotation(
            roster: ["Alice"],
            attendees: [],
            localParticipantCheck: neverLocal)!
        XCTAssertTrue(result.hasPrefix("---"), "Annotation should start with a markdown horizontal rule")
    }
}
