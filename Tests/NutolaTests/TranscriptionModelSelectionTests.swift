import XCTest
@testable import Nutola

final class TranscriptionModelSelectionTests: XCTestCase {
    func testSelectionRoutesToActualEngine() {
        XCTAssertEqual(Transcriber.resolveEngine(for: .apple), .apple)
        XCTAssertEqual(Transcriber.resolveEngine(for: .parakeetRedux), .parakeet(.parakeetRedux))
        XCTAssertEqual(Transcriber.resolveEngine(for: .parakeetUltra), .parakeet(.parakeetUltra))
    }

    func testSelectedEngineTracksStoredPreference() {
        for model in TranscriptionModel.allCases {
            UserDefaults.standard.set(model.rawValue, forKey: SettingsKey.transcriptionModel)
            XCTAssertEqual(Transcriber.resolveEngine(), Transcriber.resolveEngine(for: model))
        }
        UserDefaults.standard.removeObject(forKey: SettingsKey.transcriptionModel)
    }
}
