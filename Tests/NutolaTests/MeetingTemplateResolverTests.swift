import XCTest
@testable import Nutola

final class MeetingTemplateResolverTests: XCTestCase {

    // MARK: - Title-based detection

    func testStandupDetection() {
        let type = MeetingTemplateResolver.resolve(
            title: "Daily Standup",
            attendees: [],
            transcriptKeywords: [])
        XCTAssertEqual(type, .standup)
    }

    func testStandupMatchesDailyAndSync() {
        XCTAssertEqual(
            MeetingTemplateResolver.resolve(title: "Daily Sync", attendees: [], transcriptKeywords: []),
            .standup)
        XCTAssertEqual(
            MeetingTemplateResolver.resolve(title: "Team sync", attendees: [], transcriptKeywords: []),
            .standup)
        XCTAssertEqual(
            MeetingTemplateResolver.resolve(title: "Stand-up", attendees: [], transcriptKeywords: []),
            .standup)
    }

    func testInterviewDetection() {
        let type = MeetingTemplateResolver.resolve(
            title: "Technical Screen Interview",
            attendees: [],
            transcriptKeywords: [])
        XCTAssertEqual(type, .interview)
    }

    func testInterviewMatchesScreen() {
        XCTAssertEqual(
            MeetingTemplateResolver.resolve(title: "Coding Screen", attendees: [], transcriptKeywords: []),
            .interview)
    }

    func testOneOnOneDetection() {
        let type = MeetingTemplateResolver.resolve(
            title: "Victor/Taylor 1:1",
            attendees: [],
            transcriptKeywords: [])
        XCTAssertEqual(type, .oneOnOne)
    }

    func testOneOnOneMatchesVariants() {
        XCTAssertEqual(
            MeetingTemplateResolver.resolve(title: "Victor / Taylor 1-on-1", attendees: [], transcriptKeywords: []),
            .oneOnOne)
        XCTAssertEqual(
            MeetingTemplateResolver.resolve(title: "one on one with Dana", attendees: [], transcriptKeywords: []),
            .oneOnOne)
    }

    func testReviewDetection() {
        let type = MeetingTemplateResolver.resolve(
            title: "Weekly Execution Review",
            attendees: [],
            transcriptKeywords: [])
        XCTAssertEqual(type, .review)
    }

    func testReviewMatchesRetro() {
        XCTAssertEqual(
            MeetingTemplateResolver.resolve(title: "Sprint Retro", attendees: [], transcriptKeywords: []),
            .review)
    }

    func testPresentationDetection() {
        XCTAssertEqual(
            MeetingTemplateResolver.resolve(title: "Roadmap Presentation", attendees: [], transcriptKeywords: []),
            .presentation)
        XCTAssertEqual(
            MeetingTemplateResolver.resolve(title: "Product Demo", attendees: [], transcriptKeywords: []),
            .presentation)
    }

    func testBrainstormDetection() {
        XCTAssertEqual(
            MeetingTemplateResolver.resolve(title: "Architecture Brainstorm", attendees: [], transcriptKeywords: []),
            .brainstorm)
        XCTAssertEqual(
            MeetingTemplateResolver.resolve(title: "Design session", attendees: [], transcriptKeywords: []),
            .brainstorm)
    }

    func testGenericFallback() {
        let type = MeetingTemplateResolver.resolve(
            title: "Random Meeting",
            attendees: [],
            transcriptKeywords: [])
        XCTAssertEqual(type, .generic)
    }

    // MARK: - Transcript keywords

    func testTranscriptKeywordsBrainstorm() {
        let type = MeetingTemplateResolver.resolve(
            title: "Untitled",
            attendees: [],
            transcriptKeywords: ["roadmap", "planning"])
        XCTAssertEqual(type, .brainstorm)
    }

    func testTranscriptKeywordsStandup() {
        let type = MeetingTemplateResolver.resolve(
            title: "Untitled",
            attendees: [],
            transcriptKeywords: ["blocker", "yesterday"])
        XCTAssertEqual(type, .standup)
    }

    func testTranscriptKeywordsDoNotOverrideTitle() {
        // Title wins over keywords: a presentation with brainstorm-y words
        // in the transcript is still a presentation.
        let type = MeetingTemplateResolver.resolve(
            title: "Q3 Roadmap Presentation",
            attendees: [],
            transcriptKeywords: ["roadmap", "planning", "brainstorm"])
        XCTAssertEqual(type, .presentation)
    }

    // MARK: - External detection

    func testExternalDetection() {
        let type = MeetingTemplateResolver.resolve(
            title: "Vendor Call",
            attendees: ["alex@stripe.com"],
            transcriptKeywords: [])
        XCTAssertEqual(type, .external)
    }

    func testInternalAttendeeDoesNotTripExternal() {
        let type = MeetingTemplateResolver.resolve(
            title: "Random Meeting",
            attendees: ["alex@doordash.com", "Dana"],
            transcriptKeywords: [])
        XCTAssertEqual(type, .generic)
    }

    func testExternalAttendeeLosesToTitleSignal() {
        // A standup with an outside guest is still a standup — title wins.
        let type = MeetingTemplateResolver.resolve(
            title: "Daily Standup",
            attendees: ["vendor@acme.io"],
            transcriptKeywords: [])
        XCTAssertEqual(type, .standup)
    }

    func testBareNamesAreNotTreatedAsExternal() {
        // Names without "@" don't reveal affiliation, so they must not trip
        // external even when they look domain-y.
        let type = MeetingTemplateResolver.resolve(
            title: "Random Meeting",
            attendees: ["Alice", "Bob Stripe"],
            transcriptKeywords: [])
        XCTAssertEqual(type, .generic)
    }

    // MARK: - resolve(for:)

    func testResolveForMeetingUsesCalendarTitleFirst() {
        var meeting = Meeting(title: "Meeting", createdAt: Date())
        meeting.calendarEventTitle = "Daily Standup"
        meeting.attendees = []
        XCTAssertEqual(MeetingTemplateResolver.resolve(for: meeting), .standup)
    }

    func testResolveForMeetingFallsBackToMeetingTitle() {
        var meeting = Meeting(title: "Sprint Retro", createdAt: Date())
        meeting.attendees = []
        XCTAssertEqual(MeetingTemplateResolver.resolve(for: meeting), .review)
    }

    // MARK: - templateName / summaryFocus

    func testTemplateNameNonEmptyForEachType() {
        for type in MeetingType.allCases {
            let name = MeetingTemplateResolver.templateName(for: type)
            XCTAssertFalse(name.isEmpty, "template name empty for \(type)")
        }
    }

    func testTemplateNameMapsKnownTypes() {
        XCTAssertEqual(MeetingTemplateResolver.templateName(for: .oneOnOne), "1-on-1")
        XCTAssertEqual(MeetingTemplateResolver.templateName(for: .interview), "Interview")
        // Types without a bespoke template fall back to the default "Meeting Notes"
        // so callers can hand the name straight to TemplateStore.template(named:).
        XCTAssertEqual(MeetingTemplateResolver.templateName(for: .standup), "Meeting Notes")
        XCTAssertEqual(MeetingTemplateResolver.templateName(for: .generic), "Meeting Notes")
    }

    func testTemplateNameResolvesToABuiltinTemplate() throws {
        // Every name we return must resolve to a real TemplateStore template —
        // otherwise a smart-templates start would hand the summarizer a nil body.
        // Use an isolated temp dir so the test doesn't depend on the real user
        // Templates directory (which may have had builtins deleted).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-template-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TemplateStore(root: tmp)
        for type in MeetingType.allCases {
            let name = MeetingTemplateResolver.templateName(for: type)
            XCTAssertNotNil(store.template(named: name), "no template named \(name) for \(type)")
        }
    }

    func testSummaryFocusNonEmptyForEachType() {
        for type in MeetingType.allCases {
            let focus = MeetingTemplateResolver.summaryFocus(for: type)
            XCTAssertFalse(focus.isEmpty, "focus empty for \(type)")
        }
    }

    func testSummaryFocusMatchesSpec() {
        XCTAssertEqual(MeetingTemplateResolver.summaryFocus(for: .standup), "Focus on blockers and updates")
        XCTAssertEqual(MeetingTemplateResolver.summaryFocus(for: .interview), "Format as Q&A")
    }

    // MARK: - MeetingType metadata

    func testDisplayNameAndSymbolNonEmptyForEachType() {
        for type in MeetingType.allCases {
            XCTAssertFalse(type.displayName.isEmpty, "displayName empty for \(type)")
            XCTAssertFalse(type.symbolName.isEmpty, "symbolName empty for \(type)")
        }
    }
}
