import Foundation
import Testing
@testable import Nutola

final class AppIdentityTests {
    private var source: String!
    private var destination: String!
    private var defaults: UserDefaults!

    init() {
        source = "nutola.identity.old.\(UUID().uuidString)"
        destination = "nutola.identity.new.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: destination)!
    }

    deinit {
        defaults.removePersistentDomain(forName: source)
        defaults.removePersistentDomain(forName: destination)
    }

    @Test func testImportsPreviousPreferencesWithoutOverwritingCurrentChoices() {
        defaults.setPersistentDomain(["appearanceMode": "dark", "autoRecord": true, "didCompleteOnboarding": true], forName: source)
        defaults.setPersistentDomain(["appearanceMode": "light"], forName: destination)
        AppIdentity.importPreviousPreferences(defaults: defaults, from: source, to: destination)
        #expect(defaults.string(forKey: "appearanceMode") == "light")
        #expect(defaults.bool(forKey: "autoRecord"))
        #expect(defaults.bool(forKey: "didCompleteOnboarding"))
        #expect(defaults.persistentDomain(forName: source)?["appearanceMode"] as? String == "dark")
    }

    @Test func testImportRunsOnceAndDoesNotRestorePreferencesRemovedLater() {
        defaults.setPersistentDomain(["autoRecord": true], forName: source)
        AppIdentity.importPreviousPreferences(defaults: defaults, from: source, to: destination)
        defaults.removeObject(forKey: "autoRecord")
        AppIdentity.importPreviousPreferences(defaults: defaults, from: source, to: destination)
        #expect(defaults.object(forKey: "autoRecord") == nil)
    }

    @Test func testNoPreviousInstallationKeepsCurrentPreferences() {
        defaults.set("light", forKey: "appearanceMode")
        AppIdentity.importPreviousPreferences(defaults: defaults, from: source, to: destination)
        #expect(defaults.string(forKey: "appearanceMode") == "light")
    }

    @Test func testPackagingIdentityMatchesRuntimeIdentityAndRepositoryLinks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let plist = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appending(path: "packaging/Info.plist")), format: nil) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == AppIdentity.bundleIdentifier)
        #expect(plist["CFBundleExecutable"] as? String == "Nutola")
        #expect(AppIdentity.repositoryURL.absoluteString == "https://github.com/d4rk413x21/Nutola")
        #expect(AppVersion.changelogURL.absoluteString == "https://github.com/d4rk413x21/Nutola/blob/main/CHANGELOG.md")
    }
}
