import Foundation
import os

/// Unified debug logging. Writes to unified log (Console.app:
/// subsystem `io.github.d4rk413x21.Nutola`). When Developer mode is on,
/// also mirrors to the in-app Debug panel and stderr.
enum NutolaConsoleLog {
    private static let zoom = Logger(subsystem: AppIdentity.bundleIdentifier, category: "platform")
    private static let recording = Logger(subsystem: AppIdentity.bundleIdentifier, category: "recording")
    private static let pipeline = Logger(subsystem: AppIdentity.bundleIdentifier, category: "pipeline")
    private static let detection = Logger(subsystem: AppIdentity.bundleIdentifier, category: "detection")
    private static let live = Logger(subsystem: AppIdentity.bundleIdentifier, category: "live")
    private static let transcribe = Logger(subsystem: AppIdentity.bundleIdentifier, category: "transcribe")
    private static let speakers = Logger(subsystem: AppIdentity.bundleIdentifier, category: "speakers")
    private static let calendar = Logger(subsystem: AppIdentity.bundleIdentifier, category: "calendar")
    private static let app = Logger(subsystem: AppIdentity.bundleIdentifier, category: "app")
    private static let ask = Logger(subsystem: AppIdentity.bundleIdentifier, category: "ask")
    private static let diarizer = Logger(subsystem: AppIdentity.bundleIdentifier, category: "diarizer")
    private static let locales = Logger(subsystem: AppIdentity.bundleIdentifier, category: "locales")
    private static let notification = Logger(subsystem: AppIdentity.bundleIdentifier, category: "notification")
    private static let processing = Logger(subsystem: AppIdentity.bundleIdentifier, category: "processing")
    private static let intelligence = Logger(subsystem: AppIdentity.bundleIdentifier, category: "intelligence")
    private static let nemotron = Logger(subsystem: AppIdentity.bundleIdentifier, category: "nemotron")
    private static let soniqo = Logger(subsystem: AppIdentity.bundleIdentifier, category: "soniqo")

    static func zoom(_ message: String) { emit(zoom, "zoom", message) }
    static func recording(_ message: String) { emit(recording, "recording", message) }
    static func pipeline(_ message: String) { emit(pipeline, "pipeline", message) }
    static func detection(_ message: String) { emit(detection, "detection", message) }
    static func live(_ message: String) { emit(live, "live", message) }
    static func transcribe(_ message: String) { emit(transcribe, "transcribe", message) }
    static func speakers(_ message: String) { emit(speakers, "speakers", message) }
    static func calendar(_ message: String) { emit(calendar, "calendar", message) }
    static func app(_ message: String) { emit(app, "app", message) }
    static func ask(_ message: String) { emit(ask, "ask", message) }
    static func diarizer(_ message: String) { emit(diarizer, "diarizer", message) }
    static func locales(_ message: String) { emit(locales, "locales", message) }
    static func notification(_ message: String) { emit(notification, "notification", message) }
    static func processing(_ message: String) { emit(processing, "processing", message) }
    static func intelligence(_ message: String) { emit(intelligence, "intelligence", message) }
    static func nemotron(_ message: String) { emit(nemotron, "nemotron", message) }
    static func soniqo(_ message: String) { emit(soniqo, "soniqo", message) }

    private static func emit(_ logger: Logger, _ category: String, _ message: String) {
        logger.info("\(message, privacy: .public)")
        NutolaFileLog.log(category, message)
        mirror(category, message)
    }

    private static func mirror(_ category: String, _ message: String) {
        guard AppSettings.developerMode else { return }
        let line = "\(category): \(message)"
        fputs("[Nutola] \(line)\n", stderr)
        AIDebugLog.log(line)
    }
}
