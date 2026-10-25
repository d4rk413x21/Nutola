import AppKit
import Foundation

/// Soniqo Parakeet CoreML models used for on-device speech recognition. Downloads Hugging Face repos
/// into `~/Library/Application Support/Nutola/Models/Soniqo/`. Inference is not
/// implemented here — this type only manages the bytes on disk.
enum SoniqoModel: String, CaseIterable, Hashable, Sendable {
    case parakeetStreaming
    case parakeetBatch

    var repoID: String {
        switch self {
        case .parakeetStreaming: "aufklarer/Parakeet-EOU-120M-CoreML-INT8"
        case .parakeetBatch: "aufklarer/Parakeet-TDT-v3-CoreML-INT8"
        }
    }

    var folderName: String {
        switch self {
        case .parakeetStreaming: "Parakeet-Streaming"
        case .parakeetBatch: "Parakeet-Batch"
        }
    }

    /// European Parakeet language coverage (ISO 639-1 base codes).
    static let languageCodes: [String] = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr",
        "hr", "hu", "it", "lt", "lv", "mt", "nl", "pl", "pt", "ro",
        "ru", "sk", "sl", "sv", "uk",
    ]

    var supportsLiveTranscription: Bool {
        self == .parakeetStreaming
    }

    var manifest: [RemoteModelFile] {
        switch self {
        case .parakeetStreaming: Self.streamingManifest
        case .parakeetBatch: Self.batchManifest
        }
    }
}

enum SoniqoModelStore {
    static func directory(for model: SoniqoModel) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Nutola/Models/Soniqo/\(model.folderName)", isDirectory: true)
    }

    static func totalSize(_ model: SoniqoModel) -> Int64 {
        RemoteModelDownloader.totalSize(model.manifest)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        RemoteModelDownloader.formatBytes(bytes)
    }

    static func isInstalled(_ model: SoniqoModel) -> Bool {
        RemoteModelDownloader.isInstalled(directory: directory(for: model), manifest: model.manifest)
    }

    static func installedBytes(_ model: SoniqoModel) -> Int64 {
        RemoteModelDownloader.installedBytes(directory: directory(for: model), manifest: model.manifest)
    }

    static func download(
        _ model: SoniqoModel,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let dir = directory(for: model)
        try await RemoteModelDownloader.download(
            repoID: model.repoID,
            directory: dir,
            manifest: model.manifest,
            onComplete: { NutolaConsoleLog.soniqo($0) },
            progress: progress
        )
    }

    @discardableResult
    static func delete(_ model: SoniqoModel) throws -> Int64 {
        let dir = directory(for: model)
        let manifest = model.manifest
        let freed = RemoteModelDownloader.installedBytes(directory: dir, manifest: manifest)
        guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
        try FileManager.default.removeItem(at: dir)
        NutolaConsoleLog.soniqo("deleted model — freed \(formatBytes(freed))")
        return freed
    }

    static func revealInFinder(_ model: SoniqoModel) {
        let dir = directory(for: model)
        let target = FileManager.default.fileExists(atPath: dir.path)
            ? dir
            : dir.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

// MARK: - Manifests (Hugging Face `main` branch, excluding README / .gitattributes)

private extension SoniqoModel {
    static let streamingManifest: [RemoteModelFile] = [
        .init(path: "config.json", size: 524, isPrimary: false),
        .init(path: "vocab.json", size: 17_437, isPrimary: false),
        .init(path: "decoder.mlmodelc/analytics/coremldata.bin", size: 243, isPrimary: false),
        .init(path: "decoder.mlmodelc/coremldata.bin", size: 403, isPrimary: false),
        .init(path: "decoder.mlmodelc/model.mil", size: 6_322, isPrimary: false),
        .init(path: "decoder.mlmodelc/weights/weight.bin", size: 7_873_600, isPrimary: false),
        .init(path: "encoder.mlmodelc/analytics/coremldata.bin", size: 243, isPrimary: false),
        .init(path: "encoder.mlmodelc/coremldata.bin", size: 670, isPrimary: false),
        .init(path: "encoder.mlmodelc/model.mil", size: 703_396, isPrimary: false),
        .init(path: "encoder.mlmodelc/weights/weight.bin", size: 106_694_848, isPrimary: true),
        .init(path: "joint.mlmodelc/analytics/coremldata.bin", size: 243, isPrimary: false),
        .init(path: "joint.mlmodelc/coremldata.bin", size: 354, isPrimary: false),
        .init(path: "joint.mlmodelc/model.mil", size: 5_058, isPrimary: false),
        .init(path: "joint.mlmodelc/weights/weight.bin", size: 2_794_182, isPrimary: false),
    ]

    static let batchManifest: [RemoteModelFile] = [
        .init(path: "config.json", size: 372, isPrimary: false),
        .init(path: "vocab.json", size: 159_466, isPrimary: false),
        .init(path: "decoder.mlmodelc/analytics/coremldata.bin", size: 243, isPrimary: false),
        .init(path: "decoder.mlmodelc/coremldata.bin", size: 403, isPrimary: false),
        .init(path: "decoder.mlmodelc/metadata.json", size: 2_852, isPrimary: false),
        .init(path: "decoder.mlmodelc/model.mil", size: 8_971, isPrimary: false),
        .init(path: "decoder.mlmodelc/weights/weight.bin", size: 23_604_992, isPrimary: false),
        .init(path: "encoder.mlmodelc/analytics/coremldata.bin", size: 243, isPrimary: false),
        .init(path: "encoder.mlmodelc/coremldata.bin", size: 364, isPrimary: false),
        .init(path: "encoder.mlmodelc/metadata.json", size: 3_321, isPrimary: false),
        .init(path: "encoder.mlmodelc/model.mil", size: 1_507_922, isPrimary: false),
        .init(path: "encoder.mlmodelc/weights/weight.bin", size: 602_638_976, isPrimary: true),
        .init(path: "encoder_15s.mlmodelc/analytics/coremldata.bin", size: 243, isPrimary: false),
        .init(path: "encoder_15s.mlmodelc/coremldata.bin", size: 364, isPrimary: false),
        .init(path: "encoder_15s.mlmodelc/model.mil", size: 875_860, isPrimary: false),
        .init(path: "encoder_15s.mlmodelc/weights/weight.bin", size: 593_446_784, isPrimary: false),
        .init(path: "encoder_5s.mlmodelc/analytics/coremldata.bin", size: 243, isPrimary: false),
        .init(path: "encoder_5s.mlmodelc/coremldata.bin", size: 363, isPrimary: false),
        .init(path: "encoder_5s.mlmodelc/model.mil", size: 685_670, isPrimary: false),
        .init(path: "encoder_5s.mlmodelc/weights/weight.bin", size: 587_302_272, isPrimary: false),
        .init(path: "joint.mlmodelc/analytics/coremldata.bin", size: 243, isPrimary: false),
        .init(path: "joint.mlmodelc/coremldata.bin", size: 392, isPrimary: false),
        .init(path: "joint.mlmodelc/metadata.json", size: 2_346, isPrimary: false),
        .init(path: "joint.mlmodelc/model.mil", size: 5_184, isPrimary: false),
        .init(path: "joint.mlmodelc/weights/weight.bin", size: 12_642_764, isPrimary: false),
    ]
}
