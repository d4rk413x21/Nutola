import Foundation

/// Only expose engines with a real inference path. Old Soniqo/Nemotron
/// choices are migrated to Apple rather than silently falling back.
enum TranscriptionModel: String, CaseIterable, Identifiable, Hashable {
    case apple
    case parakeetRedux
    case parakeetUltra

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple Speech"
        case .parakeetRedux: "Parakeet Redux (lightweight)"
        case .parakeetUltra: "Parakeet Ultra (accuracy)"
        }
    }

    var detail: String {
        switch self {
        case .apple:
            "Apple's built-in live and batch speech recognition."
        case .parakeetRedux:
            "Multilingual (includes Italian). Compact Core ML model (~220 MB). Runs on the complete audio after recording. Live preview uses Apple Speech."
        case .parakeetUltra:
            "Multilingual (includes Italian). Larger Core ML model (~630 MB), optimized for accuracy. Live uses overlapping windows; final audio is transcribed again."
        }
    }

    var isDownloadable: Bool { self != .apple }
    var isAvailable: Bool { true }
    var supportsLiveTranscription: Bool { self == .apple }
    var isModelInstalled: Bool { FluidParakeetModels.isInstalled(self) }

    var modelInstalledBytes: Int64 { FluidParakeetModels.installedBytes(self) }

    var modelTotalBytes: Int64 {
        switch self {
        case .apple: 0
        case .parakeetRedux: 220_000_000
        case .parakeetUltra: 630_000_000
        }
    }

    func downloadModel(progress: @Sendable @escaping (Double) -> Void) async throws {
        guard self != .apple else { return }
        try await FluidParakeetModels.download(self)
        progress(1)
    }

    @discardableResult
    func deleteModel() throws -> Int64 { try FluidParakeetModels.delete(self) }

    func revealModelInFinder() { FluidParakeetModels.reveal(self) }

    func logModelEvent(_ message: String) {
        switch self {
        case .apple: NutolaConsoleLog.transcribe(message)
        case .parakeetRedux, .parakeetUltra: NutolaConsoleLog.transcribe("\(rawValue): \(message)")
        }
    }

    static func formatBytes(_ bytes: Int64) -> String { RemoteModelDownloader.formatBytes(bytes) }
}
