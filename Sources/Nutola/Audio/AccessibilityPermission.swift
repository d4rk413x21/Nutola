import AppKit
import ApplicationServices
import Foundation
import ExceptionCatch

/// macOS Accessibility trust — required to read Zoom's active-speaker UI.
enum AccessibilityPermission {
    static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Presents the system Accessibility consent dialog and opens Settings.
    @MainActor
    static func request() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        requestTrust()
    }

    /// Opens System Settings → Privacy & Security → Accessibility with the prompt.
    static func requestTrust() {
        _ = NutolaRequestAccessibilityTrust()
    }
}
