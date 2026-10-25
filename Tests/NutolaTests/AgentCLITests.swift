import XCTest
@testable import Nutola

final class AgentCLITests: XCTestCase {
    func testOpenCodeReadsOnlyCompletedTextEvents() throws {
        let output = """
        {"type":"step_start","part":{}}
        {"type":"reasoning","part":{"text":"Private reasoning"}}
        {"type":"text","part":{"text":"Meeting "}}
        {"type":"text","part":{"text":"summary"}}
        {"type":"step_finish","part":{"reason":"stop"}}
        """
        XCTAssertEqual(try AgentCLI.response(from: Data(output.utf8), provider: .opencode), "Meeting summary")
    }

    func testOpenCodeRejectsErrorsAndTruncatedAnswersEvenAfterText() {
        for end in [#"{"type":"error","error":{"data":{"message":"Invalid model"}}}"#,
                    #"{"type":"step_finish","part":{"reason":"length"}}"#] {
            let output = #"{"type":"text","part":{"text":"Partial answer"}}"# + "\n" + end
            XCTAssertThrowsError(try AgentCLI.response(from: Data(output.utf8), provider: .opencode))
        }
    }

    func testVibeSelectsLastAssistantMessageAndIgnoresReasoningAndTools() throws {
        let output = #"[{"role":"system","content":"Instructions"},{"role":"user","content":"Transcript"},{"role":"assistant","content":"Old answer"},{"role":"tool","content":"Tool output"},{"role":"assistant","content":"Final answer","reasoning_content":"Private reasoning"}]"#
        XCTAssertEqual(try AgentCLI.response(from: Data(output.utf8), provider: .vibe), "Final answer")
    }

    func testVibeSupportsCurrentHistoryBlocksAndSkipsDiscardedReplies() throws {
        let output = #"[{"type":"message","role":"assistant","content":[{"type":"reasoning","text":"Hidden"},{"type":"text","text":"First"},{"type":"text","text":"Second"}]},{"type":"message","role":"assistant","outcome":{"type":"discarded","cause":"retry"},"content":[{"type":"text","text":"Discarded"}]}]"#
        XCTAssertEqual(try AgentCLI.response(from: Data(output.utf8), provider: .vibe), "First\n\nSecond")
    }

    func testRejectsMalformedEmptyAndNonAssistantOutput() {
        for provider in [AIProvider.opencode, .vibe] {
            for output in ["", "not JSON", "{}", "[]", #"[{"role":"user","content":"Not an answer"}]"#] {
                XCTAssertThrowsError(try AgentCLI.response(from: Data(output.utf8), provider: provider))
            }
        }
    }

    func testHeadlessInvocationsDisableToolsAndUseStdin() throws {
        XCTAssertEqual(AgentCLI.arguments(for: .opencode), ["run", "--format", "json", "--agent", "nutola-analysis"])
        let vibe = AgentCLI.arguments(for: .vibe)
        let disabled = try XCTUnwrap(vibe.firstIndex(of: "--disabled-tools"))
        XCTAssertEqual(vibe[disabled + 1], "*")
        XCTAssertEqual(vibe.last, "-p")
        XCTAssertFalse(vibe.contains("--auto-approve"))
        let env = try AgentCLI.environment(for: .opencode, base: [:])
        let config = try XCTUnwrap(env["OPENCODE_CONFIG_CONTENT"])
        let json = try JSONSerialization.jsonObject(with: Data(config.utf8)) as! [String: Any]
        let agents = json["agent"] as! [String: [String: Any]]
        let agent = try XCTUnwrap(agents["nutola-analysis"])
        XCTAssertEqual(agent["permission"] as? [String: String], ["*": "deny"])
        XCTAssertEqual(agent["tools"] as? [String: Bool], ["*": false])
        XCTAssertEqual(json["share"] as? String, "disabled")
    }

    func testOpenCodePreservesInlineModelConfigurationWithoutAllowingTools() throws {
        let inline = #"{"model":"provider/my-model","agent":{"other":{"description":"keep"}}}"#
        let env = try AgentCLI.environment(for: .opencode, base: ["OPENCODE_CONFIG_CONTENT": inline, "USER": "example"])
        let data = try XCTUnwrap(env["OPENCODE_CONFIG_CONTENT"]).data(using: .utf8)!
        let config = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(config["model"] as? String, "provider/my-model")
        XCTAssertNotNil((config["agent"] as? [String: Any])?["other"])
        XCTAssertEqual(env["USER"], "example")
        XCTAssertEqual(env["OPENCODE_PERMISSION"], #"{"*":"deny"}"#)
        XCTAssertThrowsError(try AgentCLI.environment(for: .opencode, base: ["OPENCODE_CONFIG_CONTENT": "invalid JSON"]))
    }

    func testFindsOpenCodeAndVibeStandardUserInstalls() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for (provider, path) in [(AIProvider.opencode, ".opencode/bin/opencode"), (.vibe, ".local/bin/vibe")] {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            XCTAssertEqual(AgentCLI.fastProbe(provider, home: home), url)
        }
    }
}
