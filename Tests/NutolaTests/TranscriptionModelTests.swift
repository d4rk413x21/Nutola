import XCTest
@testable import Nutola

final class TranscriptionModelTests: XCTestCase {
    func testAvailableChoicesHaveSupportedInferencePaths() {
        XCTAssertEqual(Set(TranscriptionModel.allCases), Set([.apple, .parakeetRedux, .parakeetUltra]))
        for model in TranscriptionModel.allCases {
            XCTAssertTrue(model.isAvailable)
            XCTAssertFalse(model.displayName.isEmpty)
            XCTAssertFalse(model.detail.isEmpty)
        }
    }

    func testLegacyChoicesAreNotExposed() {
        XCTAssertNil(TranscriptionModel(rawValue: "parakeetStreaming"))
        XCTAssertNil(TranscriptionModel(rawValue: "parakeetBatch"))
        XCTAssertNil(TranscriptionModel(rawValue: "nemotron"))
    }

    func testLiveAndBatchSupport() {
        XCTAssertFalse(TranscriptionModel.parakeetRedux.supportsLiveTranscription)
        XCTAssertFalse(TranscriptionModel.parakeetUltra.supportsLiveTranscription)
        XCTAssertTrue(TranscriptionModel.apple.supportsLiveTranscription)
    }

    func testModelVersions() {
        XCTAssertEqual(TranscriptionModel.parakeetRedux.modelTotalBytes, 220_000_000)
        XCTAssertEqual(TranscriptionModel.parakeetUltra.modelTotalBytes, 630_000_000)
        XCTAssertFalse(TranscriptionModel.apple.isDownloadable)
        XCTAssertTrue(TranscriptionModel.parakeetRedux.isDownloadable)
    }

    func testModelSettingRoundTrips() {
        for model in TranscriptionModel.allCases {
            UserDefaults.standard.set(model.rawValue, forKey: SettingsKey.transcriptionModel)
            XCTAssertEqual(AppSettings.transcriptionModel, model)
        }
        UserDefaults.standard.set("parakeetStreaming", forKey: SettingsKey.transcriptionModel)
        XCTAssertEqual(AppSettings.transcriptionModel, .apple)
        UserDefaults.standard.removeObject(forKey: SettingsKey.transcriptionModel)
    }
}
