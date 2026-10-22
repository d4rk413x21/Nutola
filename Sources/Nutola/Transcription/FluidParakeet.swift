import AppKit
import FluidAudio
import Foundation

/// FluidAudio-compatible multilingual Core ML models.
/// The legacy Soniqo downloads use a different bundle structure and are NOT
/// consumed by FluidAudio.
enum FluidParakeetModels {
    static func version(for model: TranscriptionModel) -> AsrModelVersion {
        switch model {
        case .parakeetRedux: return .redux
        case .parakeetUltra: return .ultra
        case .apple: return .redux // Never used for Apple Speech.
        }
    }

    // FluidAudio's ModelHub interprets the argument to AsrModels.download(to:)
    // as a repo-specific directory, but saves models under that directory's
    // parent using Repo.folderName. Return that exact location everywhere:
    // downloading, checking installation, displaying size, revealing and deleting.
    static func directory(for model: TranscriptionModel) -> URL {
        let repoFolder: String
        switch model {
        case .parakeetRedux: repoFolder = "parakeet-redux-coreml"
        case .parakeetUltra: repoFolder = "parakeet-ultra-coreml"
        case .apple: repoFolder = "apple"
        }
        return MeetingArchive.defaultRoot
            .appendingPathComponent("Models/FluidParakeet", isDirectory: true)
            .appendingPathComponent(repoFolder, isDirectory: true)
    }

    static func isInstalled(_ model: TranscriptionModel) -> Bool {
        guard model != .apple else { return true }
        return AsrModels.modelsExist(at: directory(for: model), version: version(for: model))
    }

    static func download(
        _ model: TranscriptionModel,
        progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        guard model != .apple else { return }
        // Do not re-download intact weights already present in the correct
        // FluidAudio cache directory (including assets downloaded by older Nutola).
        if isInstalled(model) {
            progress(1)
            return
        }
        _ = try await AsrModels.download(
            to: directory(for: model),
            version: version(for: model),
            progressHandler: { update in
                progress(min(0.99, max(0, update.fractionCompleted)))
            }
        )
        guard isInstalled(model) else {
            throw AsrModelsError.loadingFailed("The Parakeet model download finished, but required files were not found.")
        }
        progress(1)
    }

    /// AsrModels.download(to:) takes a *hint* directory, and ModelHub resolves
    /// its actual cache to a sibling folder. Different FluidAudio releases have
    /// used both names. The working model files on existing Macs can therefore
    /// be in "parakeet-ultra" or "parakeet-ultra-coreml" (and likewise Redux).
    ///
    /// Only these model-specific, whitelisted directories are ever measured or
    /// removed. FluidAudio's shared diarization cache is not included.
    static func storageDirectories(
        for model: TranscriptionModel,
        root: URL = MeetingArchive.defaultRoot
    ) -> [URL] {
        let basename: String
        switch model {
        case .parakeetRedux: basename = "parakeet-redux"
        case .parakeetUltra: basename = "parakeet-ultra"
        case .apple: return []
        }
        let parent = root.appendingPathComponent("Models/FluidParakeet", isDirectory: true)
        return [
            parent.appendingPathComponent(basename, isDirectory: true),
            parent.appendingPathComponent(basename + "-coreml", isDirectory: true),
        ]
    }

    static func installedBytes(
        _ model: TranscriptionModel,
        root: URL = MeetingArchive.defaultRoot
    ) -> Int64 {
        let fm = FileManager.default
        var bytes: Int64 = 0
        for directory in storageDirectories(for: model, root: root) {
            guard let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            ) else { continue }
            for case let file as URL in enumerator {
                let properties = try? file.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey])
                if properties?.isRegularFile == true {
                    bytes += Int64(properties?.fileSize ?? 0)
                }
            }
        }
        return bytes
    }

    @discardableResult
    static func delete(
        _ model: TranscriptionModel,
        root: URL = MeetingArchive.defaultRoot
    ) throws -> Int64 {
        let fm = FileManager.default
        let freedBytes = installedBytes(model, root: root)
        for directory in storageDirectories(for: model, root: root) {
            if fm.fileExists(atPath: directory.path) {
                try fm.removeItem(at: directory)
                NutolaConsoleLog.transcribe("removed \(model.rawValue) cache at \(directory.path)")
            }
        }
        return freedBytes
    }

    static func reveal(_ model: TranscriptionModel) {
        let fm = FileManager.default
        let directories = storageDirectories(for: model)
        let selected = directories.first { fm.fileExists(atPath: $0.path) }
            ?? directory(for: model).deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([selected])
    }

    /// Does not delete any user data until explicitly invoked from Settings.
    static func legacyBytes() -> Int64 {
        SoniqoModelStore.installedBytes(.parakeetStreaming)
            + SoniqoModelStore.installedBytes(.parakeetBatch)
            + NemotronModelStore.installedBytes
    }

    @discardableResult
    static func deleteLegacyDownloads() throws -> Int64 {
        let a = try SoniqoModelStore.delete(.parakeetStreaming)
        let b = try SoniqoModelStore.delete(.parakeetBatch)
        let c = try NemotronModelStore.delete()
        return a + b + c
    }
}

/// Shares loaded model instances between microphone and system-audio streams,
/// avoiding two separate large Core ML model loads.
actor FluidParakeetModelCache {
    static let shared = FluidParakeetModelCache()
    private var loaded: [TranscriptionModel: AsrModels] = [:]

    /// Release the in-memory model after a user explicitly removes its files.
    func evict(_ model: TranscriptionModel) {
        loaded.removeValue(forKey: model)
    }

    func get(_ model: TranscriptionModel) async throws -> AsrModels {
        if let hit = loaded[model] { return hit }
        guard model != .apple else { throw TranscriberError.modelUnavailable }
        let models = try await AsrModels.downloadAndLoad(
            to: FluidParakeetModels.directory(for: model),
            version: FluidParakeetModels.version(for: model)
        )
        loaded[model] = models
        return models
    }
}

/// Actual Parakeet ASR inference for a completed recording.
enum FluidParakeetTranscriber {
    static func transcribeFile(at url: URL, model: TranscriptionModel) async throws -> TranscriptionOutput {
        let models = try await FluidParakeetModelCache.shared.get(model)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        var state = try TdtDecoderState(decoderLayers: 2)
        let result = try await manager.transcribe(url, decoderState: &state)
        let recognized = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recognized.isEmpty else { throw TranscriberError.emptyAudio }

        let words = wordsFromTimings(result.tokenTimings ?? [])
        let segments = words.isEmpty
            ? [TranscribedWord(text: recognized, start: 0, end: max(0, result.duration))]
            : groupPhrases(words)
        NutolaConsoleLog.transcribe("FluidAudio \(model.rawValue) → \(recognized.count) characters")
        return TranscriptionOutput(words: words.isEmpty ? segments : words, segments: segments)
    }

    /// Join SentencePiece subwords without inserting spaces inside words.
    private static func wordsFromTimings(_ timings: [TokenTiming]) -> [TranscribedWord] {
        var result: [TranscribedWord] = []
        var current = ""
        var first: TimeInterval = 0
        var last: TimeInterval = 0
        func flush() {
            let word = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty { result.append(TranscribedWord(text: word, start: first, end: last)) }
            current = ""
        }
        for item in timings {
            let raw = item.token
            let startsWord = raw.hasPrefix("▁") || raw.hasPrefix(" ")
            if startsWord && !current.isEmpty { flush() }
            if current.isEmpty { first = item.startTime }
            current += raw.replacingOccurrences(of: "▁", with: " ")
            last = item.endTime
        }
        flush()
        return result
    }

    private static func groupPhrases(_ words: [TranscribedWord]) -> [TranscribedWord] {
        var output: [TranscribedWord] = []
        var group: [TranscribedWord] = []
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            output.append(TranscribedWord(
                text: group.map(\.text).joined(separator: " "),
                start: first.start, end: last.end
            ))
            group.removeAll()
        }
        for word in words {
            if let last = group.last, word.start - last.end > 1.5 { flush() }
            group.append(word)
            if group.count >= 14 || word.text.hasSuffix(".") || word.text.hasSuffix("?") {
                flush()
            }
        }
        flush()
        return output
    }
}
