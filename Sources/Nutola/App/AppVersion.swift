import Foundation

/// Reads the version stamped into the app bundle's Info.plist at build time
/// by `make app` (from the `VERSION` file — the single source of truth).
/// Exposed to the UI so Settings can show "Nutola 0.0.1 (build 001)" without
/// hard-coding anything. Returns nil in test/debug contexts where the bundle
/// isn't present (e.g. `swift test`).
enum AppVersion {
    /// Short version string, e.g. "0.0.1". nil when the bundle isn't loaded.
    static var displayVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? readVersionFile()
    }

    /// Build number, e.g. "001" (version with dots stripped). "0" when
    /// unavailable so the UI has a stable value to display.
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var changelogURL: URL {
        AppIdentity.repositoryURL.appending(path: "blob/main/CHANGELOG.md")
    }

    /// Fallback for contexts where the bundle isn't present (tests, CLI runs):
    /// read the VERSION file from the package root.
    private static func readVersionFile() -> String? {
        for url in [
            Bundle.main.url(forResource: "VERSION", withExtension: nil),
            URL(fileURLWithPath: "VERSION")
        ] {
            if let url, let data = try? String(contentsOf: url, encoding: .utf8) {
                let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
