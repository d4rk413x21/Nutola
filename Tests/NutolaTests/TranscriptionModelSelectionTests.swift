import Foundation
import Testing
@testable import Nutola

extension SharedStateTests {
    struct TranscriptionModelSelectionTests {
        @Test func testSelectionRoutesToActualEngine() {
            #expect(Transcriber.resolveEngine(for: .apple) == .apple)
            #expect(Transcriber.resolveEngine(for: .parakeetRedux) == .parakeet(.parakeetRedux))
            #expect(Transcriber.resolveEngine(for: .parakeetUltra) == .parakeet(.parakeetUltra))
        }

        @Test func testSelectedEngineTracksStoredPreference() {
            let key = SettingsKey.transcriptionModel
            let previous = UserDefaults.standard.object(forKey: key)
            defer {
                if let previous { UserDefaults.standard.set(previous, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            for model in TranscriptionModel.allCases {
                UserDefaults.standard.set(model.rawValue, forKey: SettingsKey.transcriptionModel)
                #expect(Transcriber.resolveEngine() == Transcriber.resolveEngine(for: model))
            }
        }
    }
}
