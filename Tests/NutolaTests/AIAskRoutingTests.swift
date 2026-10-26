import Foundation
import Testing
@testable import Nutola

extension SharedStateTests {
    struct AIAskRoutingTests {
        private func setProvider(_ provider: AIProvider) {
            UserDefaults.standard.set(provider.rawValue, forKey: SettingsKey.preferredAIProvider)
        }

        @Test func testProviderDisplayNames() {
            #expect(!(AIProvider.claude.displayName.isEmpty))
            #expect(!(AIProvider.codex.displayName.isEmpty))
            #expect(!(AIProvider.apple.displayName.isEmpty))
            #expect(AIProvider.opencode.displayName == "OpenCode")
            #expect(AIProvider.vibe.displayName == "Mistral Vibe")
        }

        @Test func testAdditionalProvidersAreCLIOnlyEvenWhenAppModeWasSaved() {
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
                #expect(AppSettings.preferredAIProvider == provider)
                #expect(AppSettings.askDeliveryMode == .cli)
                #expect(provider.deliveryModes == [.cli])
                #expect(!(AIAsk.isAvailable(for: .app, provider: provider)))
                #expect(!(AIAsk.open(prompt: "Do not launch anything")))
                #expect(AIProvider.askChoices.contains(provider))
            }
        }

        @Test func testAppleOpenReturnsFalse() {
            let saved = AppSettings.preferredAIProvider
            setProvider(.apple)
            defer { setProvider(saved) }
            #expect(!(AIAsk.open(prompt: "test")))
        }

        @Test(.enabled(if: AppleSummarizer.isAvailable, "Requires Apple Intelligence"))
        func testAppleAnswerRoutesToAppleSummarizer() async throws {
            let saved = AppSettings.preferredAIProvider
            setProvider(.apple)
            defer { setProvider(saved) }
            do {
                _ = try await AIAsk.answer(prompt: "Say hello")
            } catch is AIAskError {
                Issue.record("Should not throw AIAskError for .apple provider")
            } catch {
                // Other errors (model unavailable, rate limit) are acceptable
            }
        }
    }
}
