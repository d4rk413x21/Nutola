import AppKit
import Foundation

/// Core Audio requests system-audio access when its process tap starts.
/// macOS exposes no public preflight API for this permission.
enum SystemAudioPermission {
    static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture")!
    static let statusLabel = "not queryable through public APIs"

    static func guidance(previouslyCaptured: Bool) -> String {
        let history = previouslyCaptured ? "Call audio was captured in a previous recording. " : ""
        return history + "macOS does not expose the current permission status. Request access, then check Nutola in System Settings if call audio is missing."
    }

    @MainActor
    static func request() async throws {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.detached(priority: .userInitiated) {
            let tap = SystemAudioTap()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("nutola-permission-probe-\(UUID().uuidString).m4a")
            defer {
                tap.stop()
                try? FileManager.default.removeItem(at: url)
            }
            try tap.start(writingTo: url)
            try await Task.sleep(for: .seconds(2))
        }.value
    }
}
