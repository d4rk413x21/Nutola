import Foundation
import Testing
@testable import Nutola

@Suite(.enabled(if: AppleSummarizer.isAvailable, "Requires Apple Intelligence"))
struct AppleAskIntegrationTests {
    @Test func testAnswerLibraryQuestionWithEmbeddedContext() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-apple-ask-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let archive = MeetingArchive(root: tmp)

        let now = Date()
        var meeting = Meeting(title: "Roadmap sync", createdAt: now)
        meeting.state = .ready
        try archive.createFolder(for: meeting.id)
        try archive.save(meeting)
        try archive.saveSummary(
            "## Summary\n\nDecided to ship folders and transcript visualization by Friday.",
            for: meeting.id)

        let prompt = ClaudeDesktopPrompt.library(question: "What did we decide in Roadmap sync?")
        let enriched = AskContextBuilder.enrichForAsk(prompt, archive: archive, limits: .onDevice)

        #expect(enriched.contains("Roadmap sync"))
        #expect(enriched.contains("folders"))

        let answer = try await AppleSummarizer.answer(prompt: enriched)
        #expect(!(answer.isEmpty))
        #expect(!(answer.lowercased().contains("i'll look")))
        #expect(answer.localizedCaseInsensitiveContains("folder")
                || answer.localizedCaseInsensitiveContains("transcript")
                || answer.localizedCaseInsensitiveContains("friday"), "Expected answer to reference embedded summary, got: \(answer.prefix(200))")
    }

    @Test func testOnDeviceWeekSummaryIncludesMultipleMeetings() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-apple-week-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let archive = MeetingArchive(root: tmp)
        let now = Date()

        for (title, note) in [
            ("All Hands", "Decided to ship folders and calendar integration."),
            ("Design review", "Approved new transcript reader layout."),
            ("1:1 with Alex", "Alex owns the MCP connector docs."),
        ] {
            var meeting = Meeting(title: title, createdAt: now)
            meeting.state = .ready
            try archive.createFolder(for: meeting.id)
            try archive.save(meeting)
            try archive.saveSummary("## TL;DR\n\(note)", for: meeting.id)
        }

        let prompt = ClaudeDesktopPrompt.library(question: "Summarize my meetings this week")
        let enriched = AskContextBuilder.enrichForAsk(prompt, archive: archive, limits: .onDevice)
        let answer = try await AppleSummarizer.answer(prompt: enriched)

        #expect(!(answer.localizedCaseInsensitiveContains("meetings at")))
        #expect(answer.localizedCaseInsensitiveContains("folder")
                || answer.localizedCaseInsensitiveContains("transcript")
                || answer.localizedCaseInsensitiveContains("MCP"), "Expected substantive synthesis, got: \(answer.prefix(300))")
    }
}
