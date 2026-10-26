import Foundation
import Testing
@testable import Nutola

struct MeetingTemplateResolverTests {

    // MARK: - Title-based detection

    @Test func testStandupDetection() {
        let type = MeetingTemplateResolver.resolve(
            title: "Daily Standup",
            attendees: [],
            transcriptKeywords: [])
        #expect(type == .standup)
    }

    @Test func testStandupMatchesDailyAndSync() {
        #expect(MeetingTemplateResolver.resolve(title: "Daily Sync", attendees: [], transcriptKeywords: []) == .standup)
        #expect(MeetingTemplateResolver.resolve(title: "Team sync", attendees: [], transcriptKeywords: []) == .standup)
        #expect(MeetingTemplateResolver.resolve(title: "Stand-up", attendees: [], transcriptKeywords: []) == .standup)
    }

    @Test func testInterviewDetection() {
        let type = MeetingTemplateResolver.resolve(
            title: "Technical Screen Interview",
            attendees: [],
            transcriptKeywords: [])
        #expect(type == .interview)
    }

    @Test func testInterviewMatchesScreen() {
        #expect(MeetingTemplateResolver.resolve(title: "Coding Screen", attendees: [], transcriptKeywords: []) == .interview)
    }

    @Test func testOneOnOneDetection() {
        let type = MeetingTemplateResolver.resolve(
            title: "Victor/Taylor 1:1",
            attendees: [],
            transcriptKeywords: [])
        #expect(type == .oneOnOne)
    }

    @Test func testOneOnOneMatchesVariants() {
        #expect(MeetingTemplateResolver.resolve(title: "Victor / Taylor 1-on-1", attendees: [], transcriptKeywords: []) == .oneOnOne)
        #expect(MeetingTemplateResolver.resolve(title: "one on one with Dana", attendees: [], transcriptKeywords: []) == .oneOnOne)
    }

    @Test func testReviewDetection() {
        let type = MeetingTemplateResolver.resolve(
            title: "Weekly Execution Review",
            attendees: [],
            transcriptKeywords: [])
        #expect(type == .review)
    }

    @Test func testReviewMatchesRetro() {
        #expect(MeetingTemplateResolver.resolve(title: "Sprint Retro", attendees: [], transcriptKeywords: []) == .review)
    }

    @Test func testPresentationDetection() {
        #expect(MeetingTemplateResolver.resolve(title: "Roadmap Presentation", attendees: [], transcriptKeywords: []) == .presentation)
        #expect(MeetingTemplateResolver.resolve(title: "Product Demo", attendees: [], transcriptKeywords: []) == .presentation)
    }

    @Test func testBrainstormDetection() {
        #expect(MeetingTemplateResolver.resolve(title: "Architecture Brainstorm", attendees: [], transcriptKeywords: []) == .brainstorm)
        #expect(MeetingTemplateResolver.resolve(title: "Design session", attendees: [], transcriptKeywords: []) == .brainstorm)
    }

    @Test func testGenericFallback() {
        let type = MeetingTemplateResolver.resolve(
            title: "Random Meeting",
            attendees: [],
            transcriptKeywords: [])
        #expect(type == .generic)
    }

    // MARK: - Transcript keywords

    @Test func testTranscriptKeywordsBrainstorm() {
        let type = MeetingTemplateResolver.resolve(
            title: "Untitled",
            attendees: [],
            transcriptKeywords: ["roadmap", "planning"])
        #expect(type == .brainstorm)
    }

    @Test func testTranscriptKeywordsStandup() {
        let type = MeetingTemplateResolver.resolve(
            title: "Untitled",
            attendees: [],
            transcriptKeywords: ["blocker", "yesterday"])
        #expect(type == .standup)
    }

    @Test func testTranscriptKeywordsDoNotOverrideTitle() {
        // Title wins over keywords: a presentation with brainstorm-y words
        // in the transcript is still a presentation.
        let type = MeetingTemplateResolver.resolve(
            title: "Q3 Roadmap Presentation",
            attendees: [],
            transcriptKeywords: ["roadmap", "planning", "brainstorm"])
        #expect(type == .presentation)
    }

    // MARK: - External detection

    @Test func testExternalDetection() {
        let type = MeetingTemplateResolver.resolve(
            title: "Vendor Call",
            attendees: ["alex@stripe.com"],
            transcriptKeywords: [])
        #expect(type == .external)
    }

    @Test func testInternalAttendeeDoesNotTripExternal() {
        let type = MeetingTemplateResolver.resolve(
            title: "Random Meeting",
            attendees: ["alex@doordash.com", "Dana"],
            transcriptKeywords: [])
        #expect(type == .generic)
    }

    @Test func testExternalAttendeeLosesToTitleSignal() {
        // A standup with an outside guest is still a standup — title wins.
        let type = MeetingTemplateResolver.resolve(
            title: "Daily Standup",
            attendees: ["vendor@acme.io"],
            transcriptKeywords: [])
        #expect(type == .standup)
    }

    @Test func testBareNamesAreNotTreatedAsExternal() {
        // Names without "@" don't reveal affiliation, so they must not trip
        // external even when they look domain-y.
        let type = MeetingTemplateResolver.resolve(
            title: "Random Meeting",
            attendees: ["Alice", "Bob Stripe"],
            transcriptKeywords: [])
        #expect(type == .generic)
    }

    // MARK: - resolve(for:)

    @Test func testResolveForMeetingUsesCalendarTitleFirst() {
        var meeting = Meeting(title: "Meeting", createdAt: Date())
        meeting.calendarEventTitle = "Daily Standup"
        meeting.attendees = []
        #expect(MeetingTemplateResolver.resolve(for: meeting) == .standup)
    }

    @Test func testResolveForMeetingFallsBackToMeetingTitle() {
        var meeting = Meeting(title: "Sprint Retro", createdAt: Date())
        meeting.attendees = []
        #expect(MeetingTemplateResolver.resolve(for: meeting) == .review)
    }

    // MARK: - templateName / summaryFocus

    @Test func testTemplateNameNonEmptyForEachType() {
        for type in MeetingType.allCases {
            let name = MeetingTemplateResolver.templateName(for: type)
            #expect(!(name.isEmpty), "template name empty for \(type)")
        }
    }

    @Test func testTemplateNameMapsKnownTypes() {
        #expect(MeetingTemplateResolver.templateName(for: .oneOnOne) == "1-on-1")
        #expect(MeetingTemplateResolver.templateName(for: .interview) == "Interview")
        // Types without a bespoke template fall back to the default "Meeting Notes"
        // so callers can hand the name straight to TemplateStore.template(named:).
        #expect(MeetingTemplateResolver.templateName(for: .standup) == "Meeting Notes")
        #expect(MeetingTemplateResolver.templateName(for: .generic) == "Meeting Notes")
    }

    @Test func testTemplateNameResolvesToABuiltinTemplate() throws {
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
            #expect(store.template(named: name) != nil, "no template named \(name) for \(type)")
        }
    }

    @Test func testSummaryFocusNonEmptyForEachType() {
        for type in MeetingType.allCases {
            let focus = MeetingTemplateResolver.summaryFocus(for: type)
            #expect(!(focus.isEmpty), "focus empty for \(type)")
        }
    }

    @Test func testSummaryFocusMatchesSpec() {
        #expect(MeetingTemplateResolver.summaryFocus(for: .standup) == "Focus on blockers and updates")
        #expect(MeetingTemplateResolver.summaryFocus(for: .interview) == "Format as Q&A")
    }

    // MARK: - MeetingType metadata

    @Test func testDisplayNameAndSymbolNonEmptyForEachType() {
        for type in MeetingType.allCases {
            #expect(!(type.displayName.isEmpty), "displayName empty for \(type)")
            #expect(!(type.symbolName.isEmpty), "symbolName empty for \(type)")
        }
    }
}
