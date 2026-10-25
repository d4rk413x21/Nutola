import Foundation

/// Persistent file logger. Writes every `NutolaConsoleLog` line to
/// `~/Library/Application Support/Nutola/Logs/nutola.log` so the app's own
/// runtime activity survives a crash or hang — unlike `os.Logger` at `.info`
/// level, which macOS does not persist to disk, and unlike `AIDebugLog`,
/// which is an in-memory ring buffer lost when the process dies.
///
/// Thread-safe (a serial dispatch queue serializes all writes). Always on —
/// not gated on Developer mode — because the whole point is having logs to
/// read after a hang/crash. A daily rotation keeps a bounded history
/// (`nutola-YYYY-MM-DD.log`, pruned to `maxRetainedFiles`).
enum NutolaFileLog {
    private static let queue = DispatchQueue(label: "io.github.d4rk413x21.Nutola.filelog")
    private static let maxRetainedFiles = 14
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// Resolved once at first use so the logging path is stable.
    private static var logDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Nutola/Logs", isDirectory: true)
    }

    /// Current log file: `nutola-YYYY-MM-DD.log` (one per day).
    private static var currentLogFile: URL {
        logDirectory.appendingPathComponent("nutola-\(fileFormatter.string(from: Date())).log")
    }

    private static var hasPrepared = false

    /// Creates the log directory and prunes old files. Called once per process
    /// lifetime, on the serial queue, before the first write.
    private static func prepare() {
        guard !hasPrepared else { return }
        hasPrepared = true
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        prune()
    }

    private static func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return }
        let logs = files.filter { $0.pathExtension == "log" }
        guard logs.count > maxRetainedFiles else { return }
        let sorted = logs.sorted { (lhs: URL, rhs: URL) in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }
        for file in sorted.prefix(logs.count - maxRetainedFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Appends a single log line. Safe from any thread; never blocks the caller
    /// (the write is dispatched async to the serial queue).
    static func log(_ category: String, _ message: String) {
        let stamp = dateFormatter.string(from: Date())
        let line = "\(stamp) [\(category)] \(message)\n"
        queue.async {
            prepare()
            let url = currentLogFile
            guard let data = line.data(using: .utf8) else { return }
            // Append; create if missing. FileManager handles don't support append
            // atomically, so we use a FileHandle for the append path.
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Returns the path to the current log directory, for the Export button.
    static var logDirectoryURL: URL { logDirectory }

    /// Concatenates all retained log files into a single string for export.
    /// Newest last so the user reads down to the most recent activity.
    static func exportAll() -> String {
        var result = ""
        queue.sync {
            prepare()
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: logDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
            else { return }
            let logs = files.filter { $0.pathExtension == "log" }
                .sorted { (lhs: URL, rhs: URL) in
                    let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhsDate < rhsDate
                }
            for file in logs {
                if let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) {
                    if !result.isEmpty { result += "\n" }
                    result += "=== \(file.lastPathComponent) ===\n\(text)"
                }
            }
        }
        return result
    }
}
