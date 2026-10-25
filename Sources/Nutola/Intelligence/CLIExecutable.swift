import Foundation

enum CLIExecutable {
    // shortcut: editor bundle layouts are internal; update these paths when extension packages change.
    static func bundled(_ name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let prefix: String
        let paths: [String]
        #if arch(arm64)
        let platform = "arm64"
        let codexPaths = ["bin/macos-aarch64/codex", "bin/aarch64-apple-darwin/codex"]
        #else
        let platform = "x64"
        let codexPaths = ["bin/macos-x64/codex", "bin/x86_64-apple-darwin/codex"]
        #endif
        switch name {
        case "codex":
            prefix = "openai.chatgpt-"
            paths = codexPaths
        case "claude":
            prefix = "anthropic.claude-code-"
            paths = ["resources/native-binary/claude"]
        default:
            return nil
        }
        let fm = FileManager.default
        let extensions = [".vscode/extensions", ".vscode-insiders/extensions"].flatMap { directory in
            (try? fm.contentsOfDirectory(at: home.appendingPathComponent(directory), includingPropertiesForKeys: nil)) ?? []
        }.filter { url in
            let folder = url.lastPathComponent
            return folder.hasPrefix(prefix)
                && folder.dropFirst(prefix.count).first?.isNumber == true
                && !folder.contains("-linux-") && !folder.contains("-win32-")
                && (!folder.contains("-darwin-") || folder.hasSuffix("-darwin-\(platform)"))
        }.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        for directory in extensions {
            for path in paths {
                let binary = directory.appendingPathComponent(path)
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: binary.path, isDirectory: &isDirectory),
                   !isDirectory.boolValue, fm.isExecutableFile(atPath: binary.path) {
                    return binary
                }
            }
        }
        return nil
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func command(executable: URL, arguments: [String], directory: URL) -> String {
        "cd \(quote(directory.path)) && exec \(quote(executable.path)) \(arguments.map(quote).joined(separator: " "))"
    }
}
