import Foundation
import Testing
@testable import Nutola

struct ClaudeCLITests {
    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @Test func testDefaultsDisableAllBuiltinTools() {
        let args = ClaudeCLI.buildArgs(prompt: "hello")
        #expect(Array(args.prefix(2)) == ["-p", "hello"])
        #expect(value(after: "--output-format", in: args) == "json")
        #expect(value(after: "--model", in: args) == "sonnet")
        #expect(value(after: "--max-turns", in: args) == "1")
        #expect(args.contains("--strict-mcp-config"))
        #expect(value(after: "--tools", in: args) == "")
        #expect(!(args.contains("--system-prompt")))
        #expect(!(args.contains("--resume")))
        #expect(!(args.contains("--allowedTools")))
        #expect(!(args.contains("--mcp-config")))
    }

    @Test func testSystemPromptResumeModelMaxTurns() {
        let args = ClaudeCLI.buildArgs(
            prompt: "p", systemPrompt: "be brief", model: "haiku",
            resume: "abc-123", maxTurns: 3)
        #expect(value(after: "--system-prompt", in: args) == "be brief")
        #expect(value(after: "--resume", in: args) == "abc-123")
        #expect(value(after: "--model", in: args) == "haiku")
        #expect(value(after: "--max-turns", in: args) == "3")
    }

    @Test func testBuiltinsStayDisabledWithMCPAndAllowedTools() {
        // The security-relevant invariant: enabling MCP tools must NOT re-enable
        // the built-in tool set (Bash, Write, …).
        let args = ClaudeCLI.buildArgs(
            prompt: "p", allowedTools: ["mcp__nutola__search_meetings"], mcpConfigJSON: "{}")
        #expect(value(after: "--tools", in: args) == "")
        #expect(value(after: "--allowedTools", in: args) == "mcp__nutola__search_meetings")
        #expect(value(after: "--mcp-config", in: args) == "{}")
        #expect(args.contains("--strict-mcp-config"))
    }

    @Test func testExplicitBuiltinToolsAreScoped() {
        let args = ClaudeCLI.buildArgs(
            prompt: "p",
            builtinTools: ["Read"],
            allowedTools: ["Read(//tmp/x.html)"])
        #expect(value(after: "--tools", in: args) == "Read")
        #expect(value(after: "--allowedTools", in: args) == "Read(//tmp/x.html)")
    }

    @Test func testAllowedToolsJoined() {
        let args = ClaudeCLI.buildArgs(prompt: "p", allowedTools: ["Read", "Bash(git *)"])
        #expect(value(after: "--allowedTools", in: args) == "Read,Bash(git *)")
    }
}
