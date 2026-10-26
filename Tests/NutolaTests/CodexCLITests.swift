import Foundation
import Testing
@testable import Nutola

struct CodexCLITests {
    @Test func testLoginProbeReadsStderrAndRejectsLoggedOutStatus() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex login \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("codex")
        for (status, message, expected) in [(0, "Logged in using ChatGPT", true), (1, "Not logged in", false), (0, "Not logged in", false)] {
            let script = "#!/bin/sh\nprintf '%s' \(CLIExecutable.quote(message)) >&2\nexit \(status)\n"
            try Data(script.utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            #expect(CodexCLI.probeLoggedIn(executable: binary) == expected)
        }
    }

    @Test func testAnalysisDoesNotLoadUserToolsOrBypassTheSandbox() {
        let output = URL(fileURLWithPath: "/tmp/result with spaces.json")
        let prompt = "Return JSON; don't run $(anything)."
        let args = CodexCLI.buildArgs(prompt: prompt, outputFile: output, analysisOnly: true)
        #expect(args.contains("--ignore-user-config"))
        #expect(args.contains("--no-daemon"))
        #expect(args.contains("--ignore-rules"))
        #expect(args.contains("--sandbox"))
        #expect(args.contains("read-only"))
        #expect(args.contains("web_search=\"disabled\""))
        #expect(!(args.contains("--dangerously-bypass-approvals-and-sandbox")))
        for feature in ["shell_tool", "plugins", "apps", "multi_agent", "view_image", "image_generation", "computer_use"] {
            let index = args.firstIndex(of: feature)!
            #expect(args[index - 1] == "--disable")
        }
        #expect(args.last == prompt)
        #expect(args.contains(output.path))
    }

    @Test func testExistingInvocationsKeepTheirArguments() {
        let args = CodexCLI.buildArgs(prompt: "Ask", outputFile: URL(fileURLWithPath: "/tmp/result.md"))
        #expect(args == ["exec", "--dangerously-bypass-approvals-and-sandbox", "-s", "read-only",
                              "--ephemeral", "--skip-git-repo-check", "--output-last-message", "/tmp/result.md", "Ask"])
    }
}
