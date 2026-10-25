import XCTest
@testable import Nutola

final class CLIExecutableTests: XCTestCase {
    private var home: URL!
    #if arch(arm64)
    private let codexPath = "bin/macos-aarch64/codex"
    private let legacyCodexPath = "bin/aarch64-apple-darwin/codex"
    private let platform = "arm64"
    #else
    private let codexPath = "bin/macos-x64/codex"
    private let legacyCodexPath = "bin/x86_64-apple-darwin/codex"
    private let platform = "x64"
    #endif

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("nutola cli's home \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    @discardableResult
    private func binary(_ path: String, executable: Bool = true) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url.resolvingSymlinksInPath()
    }

    func testFindsCodexInVSCodeAndInsiders() throws {
        let stable = try binary(".vscode/extensions/openai.chatgpt-1.0.0-darwin-\(platform)/\(codexPath)")
        XCTAssertEqual(CLIExecutable.bundled("codex", home: home)?.resolvingSymlinksInPath(), stable)
        let insiders = try binary(".vscode-insiders/extensions/openai.chatgpt-2.0.0-darwin-\(platform)/\(codexPath)")
        XCTAssertEqual(CLIExecutable.bundled("codex", home: home)?.resolvingSymlinksInPath(), insiders)
    }

    func testFindsClaudeNativeBinaryInBothEditors() throws {
        let stable = try binary(".vscode/extensions/anthropic.claude-code-2.1.9-darwin-\(platform)/resources/native-binary/claude")
        XCTAssertEqual(CLIExecutable.bundled("claude", home: home)?.resolvingSymlinksInPath(), stable)
        try FileManager.default.removeItem(at: stable)
        let insiders = try binary(".vscode-insiders/extensions/anthropic.claude-code-2.1.10-darwin-\(platform)/resources/native-binary/claude")
        XCTAssertEqual(CLIExecutable.bundled("claude", home: home)?.resolvingSymlinksInPath(), insiders)
    }

    func testChoosesNewestExecutableVersionUsingNumericOrder() throws {
        try binary(".vscode/extensions/openai.chatgpt-1.9.0/\(codexPath)")
        let newest = try binary(".vscode/extensions/openai.chatgpt-1.10.0/\(codexPath)")
        try binary(".vscode/extensions/openai.chatgpt-1.11.0/\(codexPath)", executable: false)
        XCTAssertEqual(CLIExecutable.bundled("codex", home: home)?.resolvingSymlinksInPath(), newest)
    }

    func testSupportsLegacyCodexBundleLayout() throws {
        let expected = try binary(".vscode/extensions/openai.chatgpt-1.0.0/\(legacyCodexPath)")
        XCTAssertEqual(CLIExecutable.bundled("codex", home: home)?.resolvingSymlinksInPath(), expected)
    }

    func testIgnoresOtherExtensionsAndWrongPlatforms() throws {
        try binary(".vscode/extensions/not-openai.chatgpt-99.0.0/\(codexPath)")
        try binary(".vscode/extensions/openai.chatgpt-helper-99.0.0/\(codexPath)")
        try binary(".vscode/extensions/openai.chatgpt-99.0.0-linux-arm64/\(codexPath)")
        let other = platform == "arm64" ? "x64" : "arm64"
        try binary(".vscode/extensions/openai.chatgpt-99.0.0-darwin-\(other)/\(codexPath)")
        XCTAssertNil(CLIExecutable.bundled("codex", home: home))
        XCTAssertNil(CLIExecutable.bundled("unknown", home: home))
    }

    func testRescansAfterExtensionUpdateAndDoesNotTreatDirectoriesAsBinaries() throws {
        let old = try binary(".vscode/extensions/openai.chatgpt-1.0.0/\(codexPath)")
        XCTAssertEqual(CLIExecutable.bundled("codex", home: home)?.resolvingSymlinksInPath(), old)
        try FileManager.default.removeItem(at: old)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        XCTAssertNil(CLIExecutable.bundled("codex", home: home))
        let updated = try binary(".vscode/extensions/openai.chatgpt-2.0.0/\(codexPath)")
        XCTAssertEqual(CLIExecutable.bundled("codex", home: home)?.resolvingSymlinksInPath(), updated)
    }

    func testLaunchUsesResolvedPathAndQuotesPromptAndDirectory() throws {
        let executable = home.appendingPathComponent("a ' cli")
        try Data("#!/bin/sh\nprintf '%s' \"$1\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let prompt = "a ' quote $(touch should-not-exist) `touch should-not-exist` $HOME"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", CLIExecutable.command(executable: executable, arguments: [prompt], directory: home)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), prompt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("should-not-exist").path))
    }
}
