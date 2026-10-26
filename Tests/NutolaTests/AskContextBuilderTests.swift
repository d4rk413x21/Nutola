import Foundation
import Testing
@testable import Nutola

final class AskContextBuilderTests {
    var tmp: URL!
    var archive: MeetingArchive!

    init() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-ask-tests-\(UUID().uuidString)")
        archive = MeetingArchive(root: tmp)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeMeeting(title: String = "Roadmap sync") -> Meeting {
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
        var m = Meeting(title: title, createdAt: now)
        m.state = .ready
        try? archive.createFolder(for: m.id)
        return m
    }

    @Test func testEnrichLibraryPromptIncludesMeetingData() throws {
        let meeting = makeMeeting()
        try archive.save(meeting)
        try archive.saveSummary("# Roadmap sync\n\nDecided to ship folders.", for: meeting.id)

        let prompt = ClaudeDesktopPrompt.library(question: "Summarize my meetings this week")
        let enriched = AskContextBuilder.enrichForCLI(prompt, archive: archive)

        #expect(enriched.contains("Meeting data from Nutola"))
        #expect(enriched.contains("Roadmap sync"))
        #expect(enriched.contains("Decided to ship folders"))
        #expect(enriched != prompt)
    }

    @Test func testEnrichReturnsPromptWhenNoMeetings() {
        let prompt = ClaudeDesktopPrompt.library(question: "Summarize my meetings this week")
        let enriched = AskContextBuilder.enrichForCLI(prompt, archive: archive)
        #expect(enriched == prompt)
    }

    @Test func testOnDeviceIncludesSummariesNotJustList() throws {
        let withNotes = makeMeeting(title: "All Hands")
        try archive.save(withNotes)
        try archive.saveSummary("## TL;DR\nShipped folders feature.", for: withNotes.id)

        let withoutNotes = makeMeeting(title: "Empty call")
        try archive.save(withoutNotes)

        let prompt = ClaudeDesktopPrompt.library(question: "Summarize my meetings this week")
        let enriched = AskContextBuilder.enrichForAsk(prompt, archive: archive, limits: .onDevice)

        #expect(enriched.contains("Shipped folders"))
        #expect(enriched.contains("All Hands"))
        #expect(!(enriched.contains("## Recent meetings")))
    }

    @Test func testOnDeviceLimitsStayWithinBudget() throws {
        for i in 0..<12 {
            let meeting = makeMeeting(title: "Meeting \(i)")
            try archive.save(meeting)
            try archive.saveSummary(
                String(repeating: "word ", count: 200) + "decision \(i)",
                for: meeting.id)
        }

        let prompt = ClaudeDesktopPrompt.library(question: "Summarize my meetings this week")
        let enriched = AskContextBuilder.enrichForAsk(prompt, archive: archive, limits: .onDevice)

        #expect(enriched.contains("Meeting data from Nutola"))
        #expect(enriched.count <= AskContextBuilder.Limits.onDevice.maxTotalChars! + 32)
    }
}
