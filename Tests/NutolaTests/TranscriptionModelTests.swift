import Foundation
import Testing
@testable import Nutola

extension SharedStateTests {
    struct TranscriptionModelTests {
        @Test func testAvailableChoicesHaveSupportedInferencePaths() {
            #expect(Set(TranscriptionModel.allCases) == Set([.apple, .parakeetRedux, .parakeetUltra]))
            for model in TranscriptionModel.allCases {
                #expect(model.isAvailable)
                #expect(!(model.displayName.isEmpty))
                #expect(!(model.detail.isEmpty))
            }
        }

        @Test func testLegacyChoicesAreNotExposed() {
            #expect(TranscriptionModel(rawValue: "parakeetStreaming") == nil)
            #expect(TranscriptionModel(rawValue: "parakeetBatch") == nil)
            #expect(TranscriptionModel(rawValue: "nemotron") == nil)
        }

        @Test func testLiveAndBatchSupport() {
            #expect(!(TranscriptionModel.parakeetRedux.supportsLiveTranscription))
            #expect(!(TranscriptionModel.parakeetUltra.supportsLiveTranscription))
            #expect(TranscriptionModel.apple.supportsLiveTranscription)
        }

        @Test func testModelVersions() {
            #expect(TranscriptionModel.parakeetRedux.modelTotalBytes == 220_000_000)
            #expect(TranscriptionModel.parakeetUltra.modelTotalBytes == 630_000_000)
            #expect(!(TranscriptionModel.apple.isDownloadable))
            #expect(TranscriptionModel.parakeetRedux.isDownloadable)
        }

        @Test func testFluidAudioModelDirectoriesUseRealRepositoryNames() {
            let redux = FluidParakeetModels.directory(for: .parakeetRedux)
            let ultra = FluidParakeetModels.directory(for: .parakeetUltra)
            #expect(redux.lastPathComponent == "parakeet-redux-coreml")
            #expect(ultra.lastPathComponent == "parakeet-ultra-coreml")
            #expect(redux.deletingLastPathComponent() == ultra.deletingLastPathComponent())
        }

        @Test func testParakeetStorageIncludesLegacyAndCurrentRepositoryNames() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("nutola-model-storage-\(UUID().uuidString)")
            let ultra = FluidParakeetModels.storageDirectories(for: .parakeetUltra, root: root)
            let redux = FluidParakeetModels.storageDirectories(for: .parakeetRedux, root: root)
            #expect(Set(ultra.map(\.lastPathComponent)) == Set(["parakeet-ultra", "parakeet-ultra-coreml"]))
            #expect(Set(redux.map(\.lastPathComponent)) == Set(["parakeet-redux", "parakeet-redux-coreml"]))
            #expect(FluidParakeetModels.storageDirectories(for: .apple, root: root).isEmpty)
        }

        @Test func testParakeetModelUsageAndDeletionOnlyTargetSelectedModel() throws {
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

            #expect(FluidParakeetModels.installedBytes(.parakeetUltra, root: root) == 303)
            #expect(FluidParakeetModels.installedBytes(.parakeetRedux, root: root) == 303)
            #expect(try FluidParakeetModels.delete(.parakeetUltra, root: root) == 303)
            #expect(FluidParakeetModels.installedBytes(.parakeetUltra, root: root) == 0)
            #expect(fm.fileExists(atPath: reduxDirectory.path))
            #expect(fm.fileExists(atPath: diarization.path))
        }

        @Test func testModelSettingRoundTrips() {
            let key = SettingsKey.transcriptionModel
            let previous = UserDefaults.standard.object(forKey: key)
            defer {
                if let previous { UserDefaults.standard.set(previous, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            for model in TranscriptionModel.allCases {
                UserDefaults.standard.set(model.rawValue, forKey: SettingsKey.transcriptionModel)
                #expect(AppSettings.transcriptionModel == model)
            }
            UserDefaults.standard.set("parakeetStreaming", forKey: SettingsKey.transcriptionModel)
            #expect(AppSettings.transcriptionModel == .apple)
        }
    }
}
