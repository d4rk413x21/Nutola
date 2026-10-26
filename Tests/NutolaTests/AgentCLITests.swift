import Foundation
import Testing
@testable import Nutola

struct AgentCLITests {
    @Test func testOpenCodeReadsOnlyCompletedTextEvents() throws {
        let output = """
        {"type":"step_start","part":{}}
        {"type":"reasoning","part":{"text":"Private reasoning"}}
        {"type":"text","part":{"text":"Meeting "}}
        {"type":"text","part":{"text":"summary"}}
        {"type":"step_finish","part":{"reason":"stop"}}
        """
        #expect(try AgentCLI.response(from: Data(output.utf8), provider: .opencode) == "Meeting summary")
    }

    @Test func testOpenCodeRejectsErrorsAndTruncatedAnswersEvenAfterText() {
        for end in [#"{"type":"error","error":{"data":{"message":"Invalid model"}}}"#,
                    #"{"type":"step_finish","part":{"reason":"length"}}"#] {
            let output = #"{"type":"text","part":{"text":"Partial answer"}}"# + "\n" + end
            #expect(throws: (any Error).self) { try AgentCLI.response(from: Data(output.utf8), provider: .opencode) }
        }
    }

    @Test func testVibeSelectsLastAssistantMessageAndIgnoresReasoningAndTools() throws {
        let output = #"[{"role":"system","content":"Instructions"},{"role":"user","content":"Transcript"},{"role":"assistant","content":"Old answer"},{"role":"tool","content":"Tool output"},{"role":"assistant","content":"Final answer","reasoning_content":"Private reasoning"}]"#
        #expect(try AgentCLI.response(from: Data(output.utf8), provider: .vibe) == "Final answer")
    }

    @Test func testVibeSupportsCurrentHistoryBlocksAndSkipsDiscardedReplies() throws {
        let output = #"[{"type":"message","role":"assistant","content":[{"type":"reasoning","text":"Hidden"},{"type":"text","text":"First"},{"type":"text","text":"Second"}]},{"type":"message","role":"assistant","outcome":{"type":"discarded","cause":"retry"},"content":[{"type":"text","text":"Discarded"}]}]"#
        #expect(try AgentCLI.response(from: Data(output.utf8), provider: .vibe) == "First\n\nSecond")
    }

    @Test func testRejectsMalformedEmptyAndNonAssistantOutput() {
        for provider in [AIProvider.opencode, .vibe] {
            for output in ["", "not JSON", "{}", "[]", #"[{"role":"user","content":"Not an answer"}]"#] {
                #expect(throws: (any Error).self) { try AgentCLI.response(from: Data(output.utf8), provider: provider) }
            }
        }
    }

    @Test func testHeadlessInvocationsDisableToolsAndUseStdin() throws {
        #expect(AgentCLI.arguments(for: .opencode) == ["run", "--format", "json", "--agent", "nutola-analysis"])
        let vibe = AgentCLI.arguments(for: .vibe)
        let disabled = try #require(vibe.firstIndex(of: "--disabled-tools"))
        #expect(vibe[disabled + 1] == "*")
        #expect(vibe.last == "-p")
        #expect(!(vibe.contains("--auto-approve")))
        let env = try AgentCLI.environment(for: .opencode, base: [:])
        let config = try #require(env["OPENCODE_CONFIG_CONTENT"])
        let json = try JSONSerialization.jsonObject(with: Data(config.utf8)) as! [String: Any]
        let agents = json["agent"] as! [String: [String: Any]]
        let agent = try #require(agents["nutola-analysis"])
        #expect(agent["permission"] as? [String: String] == ["*": "deny"])
        #expect(agent["tools"] as? [String: Bool] == ["*": false])
        #expect(json["share"] as? String == "disabled")
    }

    @Test func testOpenCodePreservesInlineModelConfigurationWithoutAllowingTools() throws {
        let inline = #"{"model":"provider/my-model","agent":{"other":{"description":"keep"}}}"#
        let env = try AgentCLI.environment(for: .opencode, base: ["OPENCODE_CONFIG_CONTENT": inline, "USER": "example"])
        let data = try #require(env["OPENCODE_CONFIG_CONTENT"]).data(using: .utf8)!
        let config = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(config["model"] as? String == "provider/my-model")
        #expect((config["agent"] as? [String: Any])?["other"] != nil)
        #expect(env["USER"] == "example")
        #expect(env["OPENCODE_PERMISSION"] == #"{"*":"deny"}"#)
        #expect(throws: (any Error).self) { try AgentCLI.environment(for: .opencode, base: ["OPENCODE_CONFIG_CONTENT": "invalid JSON"]) }
    }

    @Test func testFindsOpenCodeAndVibeStandardUserInstalls() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for (provider, path) in [(AIProvider.opencode, ".opencode/bin/opencode"), (.vibe, ".local/bin/vibe")] {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            #expect(AgentCLI.fastProbe(provider, home: home) == url)
        }
    }
}
