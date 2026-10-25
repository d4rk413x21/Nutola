import XCTest
@testable import Nutola

final class AppIdentityTests: XCTestCase {
    private var source: String!
    private var destination: String!
    private var defaults: UserDefaults!

    override func setUp() {
        source = "nutola.identity.old.\(UUID().uuidString)"
        destination = "nutola.identity.new.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: destination)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: source)
        defaults.removePersistentDomain(forName: destination)
    }

    func testImportsPreviousPreferencesWithoutOverwritingCurrentChoices() {
        defaults.setPersistentDomain(["appearanceMode": "dark", "autoRecord": true, "didCompleteOnboarding": true], forName: source)
        defaults.setPersistentDomain(["appearanceMode": "light"], forName: destination)
        AppIdentity.importPreviousPreferences(defaults: defaults, from: source, to: destination)
        XCTAssertEqual(defaults.string(forKey: "appearanceMode"), "light")
        XCTAssertTrue(defaults.bool(forKey: "autoRecord"))
        XCTAssertTrue(defaults.bool(forKey: "didCompleteOnboarding"))
        XCTAssertEqual(defaults.persistentDomain(forName: source)?["appearanceMode"] as? String, "dark")
    }

    func testImportRunsOnceAndDoesNotRestorePreferencesRemovedLater() {
        defaults.setPersistentDomain(["autoRecord": true], forName: source)
        AppIdentity.importPreviousPreferences(defaults: defaults, from: source, to: destination)
        defaults.removeObject(forKey: "autoRecord")
        AppIdentity.importPreviousPreferences(defaults: defaults, from: source, to: destination)
        XCTAssertNil(defaults.object(forKey: "autoRecord"))
    }

    func testNoPreviousInstallationKeepsCurrentPreferences() {
        defaults.set("light", forKey: "appearanceMode")
        AppIdentity.importPreviousPreferences(defaults: defaults, from: source, to: destination)
        XCTAssertEqual(defaults.string(forKey: "appearanceMode"), "light")
    }

    func testPackagingIdentityMatchesRuntimeIdentityAndRepositoryLinks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appending(path: "packaging/Info.plist")), format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, AppIdentity.bundleIdentifier)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Nutola")
        XCTAssertEqual(AppIdentity.repositoryURL.absoluteString, "https://github.com/d4rk413x21/Nutola")
        XCTAssertEqual(AppVersion.changelogURL.absoluteString, "https://github.com/d4rk413x21/Nutola/blob/main/CHANGELOG.md")
    }
}
