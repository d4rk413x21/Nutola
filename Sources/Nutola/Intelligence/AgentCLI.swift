import Foundation

enum AgentCLIError: LocalizedError {
    case notInstalled(String)
    case failed(String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name): "\(name) CLI was not found. Install it and configure an account/model in the CLI first."
        case .failed(let message): message
        case .badOutput(let name): "\(name) did not return a complete assistant response."
        }
    }
}

/// Headless text-only invocations for OpenCode and Mistral Vibe.
enum AgentCLI {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var binaries: [AIProvider: URL] = [:]

    private static func name(_ provider: AIProvider) -> String? {
        switch provider {
        case .opencode: "opencode"
        case .vibe: "vibe"
        default: nil
        }
    }

    static func fastProbe(_ provider: AIProvider, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard let name = name(provider) else { return nil }
        var candidates = [home.appendingPathComponent(".local/bin/\(name)"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
                          URL(fileURLWithPath: "/usr/local/bin/\(name)")]
        if provider == .opencode { candidates.insert(home.appendingPathComponent(".opencode/bin/opencode"), at: 1) }
        let fm = FileManager.default
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) { return found }
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        for version in ((try? fm.contentsOfDirectory(atPath: nvm.path)) ?? []).sorted(by: {
            $0.compare($1, options: .numeric) == .orderedDescending
        }) {
            let path = nvm.appendingPathComponent("\(version)/bin/\(name)")
            if fm.isExecutableFile(atPath: path.path) { return path }
        }
        return nil
    }

    static func isInstalled(_ provider: AIProvider) -> Bool {
        lock.lock()
        let cached = binaries[provider]
        lock.unlock()
        return cached.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true
            || fastProbe(provider) != nil
    }

    static func resolveBlocking(_ provider: AIProvider) -> URL? {
        guard let name = name(provider) else { return nil }
        lock.lock()
        let cached = binaries[provider]
        lock.unlock()
        if let cached, FileManager.default.isExecutableFile(atPath: cached.path) { return cached }
        var found = fastProbe(provider)
        if found == nil {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "command -v \(name)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0, path.hasPrefix("/"),
                   FileManager.default.isExecutableFile(atPath: path) { found = URL(fileURLWithPath: path) }
            }
        }
        lock.lock()
        binaries[provider] = found
        lock.unlock()
        return found
    }

    static func arguments(for provider: AIProvider) -> [String] {
        switch provider {
        case .opencode: ["run", "--format", "json", "--agent", "nutola-analysis"]
        case .vibe: ["--output", "json", "--max-turns", "1", "--disabled-tools", "*", "--trust", "-p"]
        default: []
        }
    }

    static func environment(for provider: AIProvider, base: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: String] {
        var env = base
        env["HOME"] = env["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        env["USER"] = env["USER"] ?? NSUserName()
        env["PATH"] = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["NO_COLOR"] = "1"
        if provider == .opencode {
            var config: [String: Any] = [:]
            if let inline = env["OPENCODE_CONFIG_CONTENT"], !inline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let existing = try JSONSerialization.jsonObject(with: Data(inline.utf8)) as? [String: Any] else {
                    throw AgentCLIError.failed("OPENCODE_CONFIG_CONTENT must be a JSON object.")
                }
                config = existing
            }
            config["share"] = "disabled"
            var agents = config["agent"] as? [String: Any] ?? [:]
            agents["nutola-analysis"] = ["description": "Analyze supplied meeting text only",
                                         "mode": "primary", "permission": ["*": "deny"], "tools": ["*": false]]
            config["agent"] = agents
            env["OPENCODE_CONFIG_CONTENT"] = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
            env["OPENCODE_PERMISSION"] = #"{"*":"deny"}"#
            env["OPENCODE_DISABLE_PROJECT_CONFIG"] = "true"
            env["OPENCODE_DISABLE_CLAUDE_CODE"] = "true"
            env["OPENCODE_DISABLE_EXTERNAL_SKILLS"] = "true"
        }
        return env
    }

    static func run(provider: AIProvider, prompt: String, stdin: String? = nil, systemPrompt: String? = nil) async throws -> String {
        guard let binary = resolveBlocking(provider) else { throw AgentCLIError.notInstalled(provider.displayName) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nutola-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = [systemPrompt, prompt, stdin].compactMap { $0 }.joined(separator: "\n\n")
        let process = Process()
        let lifecycleLock = NSLock()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", CLIExecutable.command(executable: binary, arguments: arguments(for: provider), directory: directory)]
        process.environment = try environment(for: provider)
        let inputPipe = Pipe(), outputPipe = Pipe(), errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        async let stdout = read(outputPipe.fileHandleForReading)
        async let stderr = read(errorPipe.fileHandleForReading)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lifecycleLock.lock()
                defer { lifecycleLock.unlock() }
                process.terminationHandler = { child in
                    continuation.resume(returning: child.terminationStatus)
                }
                do {
                    try Task.checkCancellation()
                    try process.run()
                    DispatchQueue.global(qos: .utility).async {
                        try? inputPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                        try? inputPipe.fileHandleForWriting.close()
                    }
                } catch {
                    process.terminationHandler = nil
                    try? outputPipe.fileHandleForWriting.close()
                    try? errorPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            if process.isRunning { process.terminate() }
        }
        let out = await stdout, err = await stderr
        try Task.checkCancellation()
        guard status == 0 else {
            let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentCLIError.failed("\(provider.displayName): \(message.isEmpty ? "CLI exited with status \(status). Check its account/model setup." : String(message.suffix(2000)))")
        }
        return try response(from: out, provider: provider)
    }

    static func response(from data: Data, provider: AIProvider) throws -> String {
        var text = ""
        switch provider {
        case .opencode:
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    throw AgentCLIError.badOutput(provider.displayName)
                }
                let type = event["type"] as? String
                let part = event["part"] as? [String: Any]
                if type == "error" {
                    let error = event["error"] as? [String: Any]
                    let data = error?["data"] as? [String: Any]
                    let message = data?["message"] as? String ?? error?["message"] as? String
                    throw AgentCLIError.failed(message ?? "OpenCode reported an error. Check its account and model configuration.")
                }
                if type == "step_finish" && ["length", "error"].contains(part?["reason"] as? String ?? "") {
                    throw AgentCLIError.badOutput(provider.displayName)
                }
                if type == "text", let content = part?["text"] as? String { text += content }
            }
        case .vibe:
            guard let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw AgentCLIError.badOutput(provider.displayName)
            }
            for message in messages.reversed() where message["role"] as? String == "assistant" {
                if let outcome = message["outcome"] as? [String: Any], outcome["type"] as? String == "discarded" { continue }
                if let content = message["content"] as? String {
                    text = content
                } else if let blocks = message["content"] as? [[String: Any]] {
                    text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            }
        default:
            throw AgentCLIError.badOutput(provider.displayName)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentCLIError.badOutput(provider.displayName) }
        return text
    }

    private static func read(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }
}
