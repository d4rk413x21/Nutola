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

    func testFluidAudioModelDirectoriesUseRealRepositoryNames() {
        let redux = FluidParakeetModels.directory(for: .parakeetRedux)
        let ultra = FluidParakeetModels.directory(for: .parakeetUltra)
        XCTAssertEqual(redux.lastPathComponent, "parakeet-redux-coreml")
        XCTAssertEqual(ultra.lastPathComponent, "parakeet-ultra-coreml")
        XCTAssertEqual(redux.deletingLastPathComponent(), ultra.deletingLastPathComponent())
    }

    func testParakeetStorageIncludesLegacyAndCurrentRepositoryNames() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-model-storage-\(UUID().uuidString)")
        let ultra = FluidParakeetModels.storageDirectories(for: .parakeetUltra, root: root)
        let redux = FluidParakeetModels.storageDirectories(for: .parakeetRedux, root: root)
        XCTAssertEqual(Set(ultra.map(\.lastPathComponent)), Set(["parakeet-ultra", "parakeet-ultra-coreml"]))
        XCTAssertEqual(Set(redux.map(\.lastPathComponent)), Set(["parakeet-redux", "parakeet-redux-coreml"]))
        XCTAssertTrue(FluidParakeetModels.storageDirectories(for: .apple, root: root).isEmpty)
    }

    func testParakeetModelUsageAndDeletionOnlyTargetSelectedModel() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("nutola-model-storage-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let ultraDirectories = FluidParakeetModels.storageDirectories(for: .parakeetUltra, root: root)
        let reduxDirectory = FluidParakeetModels.storageDirectories(for: .parakeetRedux, root: root)[0]
        let diarization = root.appendingPathComponent("Models/FluidParakeet/speaker-diarization")

        for folder in ultraDirectories + [reduxDirectory, diarization] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data(repeating: 42, count: 101).write(
            to: ultraDirectories[0].appendingPathComponent("weights.bin"))
        try Data(repeating: 42, count: 202).write(
            to: ultraDirectories[1].appendingPathComponent("weights.bin"))
        try Data(repeating: 42, count: 303).write(
            to: reduxDirectory.appendingPathComponent("weights.bin"))
        try Data(repeating: 42, count: 404).write(
            to: diarization.appendingPathComponent("diarizer.bin"))

        XCTAssertEqual(FluidParakeetModels.installedBytes(.parakeetUltra, root: root), 303)
        XCTAssertEqual(FluidParakeetModels.installedBytes(.parakeetRedux, root: root), 303)
        XCTAssertEqual(try FluidParakeetModels.delete(.parakeetUltra, root: root), 303)
        XCTAssertEqual(FluidParakeetModels.installedBytes(.parakeetUltra, root: root), 0)
        XCTAssertTrue(fm.fileExists(atPath: reduxDirectory.path))
        XCTAssertTrue(fm.fileExists(atPath: diarization.path))
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
