import XCTest
@testable import Nutola

final class CodexCLITests: XCTestCase {
    func testAnalysisDoesNotLoadUserToolsOrBypassTheSandbox() {
        let output = URL(fileURLWithPath: "/tmp/result with spaces.json")
        let prompt = "Return JSON; don't run $(anything)."
        let args = CodexCLI.buildArgs(prompt: prompt, outputFile: output, analysisOnly: true)
        XCTAssertTrue(args.contains("--ignore-user-config"))
        XCTAssertTrue(args.contains("--no-daemon"))
        XCTAssertTrue(args.contains("--ignore-rules"))
        XCTAssertTrue(args.contains("--sandbox"))
        XCTAssertTrue(args.contains("read-only"))
        XCTAssertTrue(args.contains("web_search=\"disabled\""))
        XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
        for feature in ["shell_tool", "plugins", "apps", "multi_agent", "view_image", "image_generation", "computer_use"] {
            let index = args.firstIndex(of: feature)!
            XCTAssertEqual(args[index - 1], "--disable")
        }
        XCTAssertEqual(args.last, prompt)
        XCTAssertTrue(args.contains(output.path))
    }

    func testExistingInvocationsKeepTheirArguments() {
        let args = CodexCLI.buildArgs(prompt: "Ask", outputFile: URL(fileURLWithPath: "/tmp/result.md"))
        XCTAssertEqual(args, ["exec", "--dangerously-bypass-approvals-and-sandbox", "-s", "read-only",
                              "--ephemeral", "--skip-git-repo-check", "--output-last-message", "/tmp/result.md", "Ask"])
    }
}
