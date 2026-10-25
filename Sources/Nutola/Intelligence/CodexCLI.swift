import AppKit
import Foundation

enum CodexCLIError: LocalizedError {
    case notInstalled
    case notLoggedIn
    case failed(status: Int32, stderr: String)
    case badOutput

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Codex CLI not found. Install it from chatgpt.com/codex."
        case .notLoggedIn:
            return "Codex is not signed in. Run `codex login` in Terminal once."
        case .failed(let status, let stderr):
            return stderr.isEmpty
                ? "Codex exited with status \(status)."
                : "Codex failed (status \(status)): \(stderr)"
        case .badOutput:
            return "Codex returned unexpected output."
        }
    }
}

struct CodexCLI {
    struct RunResult: Sendable {
        let text: String
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedResolution: URL??
    private static let authCacheLock = NSLock()
    nonisolated(unsafe) private static var cachedLoggedIn: Bool?
    private static let processLock = NSLock()
    nonisolated(unsafe) private static var runningProcess: Process?

    private static func fastProbe() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/codex",
            "\(home)/.codex/packages/standalone/current/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // npm/nvm installs — common on dev Macs, invisible to a bare GUI PATH.
        let nvmBase = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
            for version in versions.sorted().reversed() {
                let path = "\(nvmBase)/\(version)/bin/codex"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }

    private static func shellProbe() -> URL? {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        sh.arguments = ["-lc", "command -v codex"]
        let pipe = Pipe()
        sh.standardOutput = pipe
        sh.standardError = FileHandle.nullDevice
        guard (try? sh.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        sh.waitUntilExit()
        guard sh.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func resolveBlocking() -> URL? {
        cacheLock.lock()
        if let cached = cachedResolution, let binary = cached,
           FileManager.default.isExecutableFile(atPath: binary.path) {
            cacheLock.unlock()
            return binary
        }
        cacheLock.unlock()
        let found = fastProbe() ?? shellProbe() ?? CLIExecutable.bundled("codex")
        cacheLock.lock()
        cachedResolution = .some(found)
        cacheLock.unlock()
        return found
    }

    static var isInstalled: Bool {
        cacheLock.lock()
        let cached = cachedResolution
        cacheLock.unlock()
        if let cached, let binary = cached,
           FileManager.default.isExecutableFile(atPath: binary.path) { return true }
        return fastProbe() != nil || CLIExecutable.bundled("codex") != nil
    }

    /// Shells out to `codex --version`. Call off the main thread; returns nil if
    /// the CLI is missing or the version can't be parsed.
    static func version() -> String? {
        guard let cli = resolveBlocking() else { return nil }
        let proc = Process()
        proc.executableURL = cli
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }


    static var isReady: Bool { isInstalled && isLoggedIn() }

    static var workDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Nutola/codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func codexHome() -> URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    static func authFromDisk() -> Bool {
        let url = codexHome().appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any]
        else { return false }
        let access = (tokens["access_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !access.isEmpty
    }

    static func warmAuthCache() {
        let loggedIn = probeLoggedIn()
        authCacheLock.lock()
        cachedLoggedIn = loggedIn
        authCacheLock.unlock()
    }

    static func isLoggedIn() -> Bool {
        if authFromDisk() {
            authCacheLock.lock()
            cachedLoggedIn = true
            authCacheLock.unlock()
            return true
        }
        if Thread.isMainThread {
            authCacheLock.lock()
            let cached = cachedLoggedIn
            authCacheLock.unlock()
            return cached ?? false
        }
        let loggedIn = probeLoggedIn()
        authCacheLock.lock()
        cachedLoggedIn = loggedIn
        authCacheLock.unlock()
        return loggedIn
    }

    private static func probeLoggedIn() -> Bool {
        if authFromDisk() { return true }
        guard let cli = resolveBlocking() else { return false }
        return probeLoggedIn(executable: cli)
    }

    static func probeLoggedIn(executable cli: URL) -> Bool {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        sh.arguments = ["-lc", CLIExecutable.command(executable: cli, arguments: ["login", "status"], directory: workDir)]
        sh.standardInput = FileHandle.nullDevice
        let out = Pipe()
        sh.standardOutput = out
        sh.standardError = out // Codex reports successful login status on stderr.
        guard (try? sh.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        sh.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sh.terminationStatus == 0
            && !text.localizedCaseInsensitiveContains("not logged in")
            && !text.isEmpty
    }

    static func openLogin() {
        if let cli = resolveBlocking() {
            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
            sh.arguments = ["-lc", CLIExecutable.command(executable: cli, arguments: ["login"], directory: workDir)]
            try? sh.run()
            return
        }
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex")!)
    }

    static func cancelRunning() {
        processLock.lock()
        defer { processLock.unlock() }
        runningProcess?.terminate()
        runningProcess = nil
    }

    /// Non-interactive run via `codex exec`. Runs through a login shell so nvm/npm
    /// wrappers get `node` on PATH — a bare Process() launch fails in GUI apps.
    static func run(
        prompt: String,
        stdin: String? = nil,
        systemPrompt: String? = nil,
        analysisOnly: Bool = false
    ) async throws -> RunResult {
        guard let cli = resolveBlocking() else { throw CodexCLIError.notInstalled }
        guard isLoggedIn() else { throw CodexCLIError.notLoggedIn }

        let outFile = workDir.appendingPathComponent("last-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: outFile) }

        var fullPrompt = prompt
        if let systemPrompt {
            fullPrompt = "\(systemPrompt)\n\n\(prompt)"
        }

        let arguments = buildArgs(prompt: fullPrompt, outputFile: outFile, analysisOnly: analysisOnly)
        let cmd = CLIExecutable.command(executable: cli, arguments: arguments, directory: workDir)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", cmd]

        let stderrPipe = Pipe()
        let stdinPipe = stdin == nil ? nil : Pipe()
        if let stdinPipe {
            process.standardInput = stdinPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        async let stderrData = readToEnd(stderrPipe.fileHandleForReading)

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                processLock.lock()
                defer { processLock.unlock() }
                process.terminationHandler = { proc in
                    processLock.lock()
                    if runningProcess === proc { runningProcess = nil }
                    processLock.unlock()
                    continuation.resume(returning: proc.terminationStatus)
                }
                do {
                    try Task.checkCancellation()
                    runningProcess = process
                    try process.run()
                    if let stdin, let stdinPipe {
                        DispatchQueue.global(qos: .utility).async {
                            let writer = stdinPipe.fileHandleForWriting
                            try? writer.write(contentsOf: Data(stdin.utf8))
                            try? writer.close()
                        }
                    }
                } catch {
                    process.terminationHandler = nil
                    if runningProcess === process { runningProcess = nil }
                    try? stderrPipe.fileHandleForWriting.close()
                    if error is CancellationError {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: CodexCLIError.failed(status: -1, stderr: error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            processLock.lock()
            defer { processLock.unlock() }
            if process.isRunning { process.terminate() }
        }

        let err = await stderrData
        try Task.checkCancellation()
        guard status == 0 else {
            throw CodexCLIError.failed(status: status, stderr: tail(String(decoding: err, as: UTF8.self)))
        }
        let text = (try? String(contentsOf: outFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw CodexCLIError.badOutput }
        return RunResult(text: text)
    }

    static func buildArgs(prompt: String, outputFile: URL, analysisOnly: Bool = false) -> [String] {
        var args: [String]
        if analysisOnly {
            // Analyze untrusted meeting text without loading connectors, hooks, or shell tools.
            args = ["--no-daemon", "--ask-for-approval", "never", "exec",
                    "--ignore-user-config", "--ignore-rules", "--sandbox", "read-only",
                    "--config", "web_search=\"disabled\""]
            for feature in ["shell_tool", "plugins", "apps", "multi_agent", "view_image", "image_generation", "computer_use"] {
                args += ["--disable", feature]
            }
        } else {
            // Preserve the existing Ask/summarization invocation, which may use configured connectors.
            args = ["exec", "--dangerously-bypass-approvals-and-sandbox", "-s", "read-only"]
        }
        return args + ["--ephemeral", "--skip-git-repo-check", "--output-last-message", outputFile.path, prompt]
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }

    private static func tail(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2000))
    }
}
