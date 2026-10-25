import XCTest
@testable import Nutola

final class AIAskRoutingTests: XCTestCase {
    private func setProvider(_ provider: AIProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: SettingsKey.preferredAIProvider)
    }

    func testProviderDisplayNames() {
        XCTAssertFalse(AIProvider.claude.displayName.isEmpty)
        XCTAssertFalse(AIProvider.codex.displayName.isEmpty)
        XCTAssertFalse(AIProvider.apple.displayName.isEmpty)
        XCTAssertEqual(AIProvider.opencode.displayName, "OpenCode")
        XCTAssertEqual(AIProvider.vibe.displayName, "Mistral Vibe")
    }

    func testAdditionalProvidersAreCLIOnlyEvenWhenAppModeWasSaved() {
        let savedProvider = AppSettings.preferredAIProvider
        let savedMode = UserDefaults.standard.object(forKey: SettingsKey.askDeliveryMode)
        defer {
            setProvider(savedProvider)
            if let savedMode { UserDefaults.standard.set(savedMode, forKey: SettingsKey.askDeliveryMode) }
            else { UserDefaults.standard.removeObject(forKey: SettingsKey.askDeliveryMode) }
        }
        UserDefaults.standard.set(AskDeliveryMode.app.rawValue, forKey: SettingsKey.askDeliveryMode)
        for provider in [AIProvider.opencode, .vibe] {
            setProvider(provider)
            XCTAssertEqual(AppSettings.preferredAIProvider, provider)
            XCTAssertEqual(AppSettings.askDeliveryMode, .cli)
            XCTAssertEqual(provider.deliveryModes, [.cli])
            XCTAssertFalse(AIAsk.isAvailable(for: .app, provider: provider))
            XCTAssertFalse(AIAsk.open(prompt: "Do not launch anything"))
            XCTAssertTrue(AIProvider.askChoices.contains(provider))
        }
    }

    func testAppleOpenReturnsFalse() {
        let saved = AppSettings.preferredAIProvider
        setProvider(.apple)
        defer { setProvider(saved) }
        XCTAssertFalse(AIAsk.open(prompt: "test"))
    }

    func testAppleAnswerRoutesToAppleSummarizer() async throws {
        guard AppleSummarizer.isAvailable else {
            throw XCTSkip("Apple Intelligence not available on this device")
        }
        let saved = AppSettings.preferredAIProvider
        setProvider(.apple)
        defer { setProvider(saved) }
        do {
            _ = try await AIAsk.answer(prompt: "Say hello")
        } catch is AIAskError {
            XCTFail("Should not throw AIAskError for .apple provider")
        } catch {
            // Other errors (model unavailable, rate limit) are acceptable
        }
    }
}
