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

    static func directory(for model: TranscriptionModel) -> URL {
        MeetingArchive.defaultRoot
            .appendingPathComponent("Models/FluidParakeet", isDirectory: true)
            .appendingPathComponent(model.rawValue, isDirectory: true)
    }

    static func isInstalled(_ model: TranscriptionModel) -> Bool {
        guard model != .apple else { return true }
        return AsrModels.modelsExist(at: directory(for: model), version: version(for: model))
    }

    static func download(_ model: TranscriptionModel) async throws {
        guard model != .apple else { return }
        _ = try await AsrModels.download(to: directory(for: model), version: version(for: model))
    }

    static func installedBytes(_ model: TranscriptionModel) -> Int64 {
        guard model != .apple else { return 0 }
        guard let enumerator = FileManager.default.enumerator(
            at: directory(for: model), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var bytes: Int64 = 0
        for case let file as URL in enumerator {
            let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if attributes?.isRegularFile == true { bytes += Int64(attributes?.fileSize ?? 0) }
        }
        return bytes
    }

    @discardableResult
    static func delete(_ model: TranscriptionModel) throws -> Int64 {
        guard model != .apple else { return 0 }
        let dir = directory(for: model)
        let bytes = installedBytes(model)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        return bytes
    }

    static func reveal(_ model: TranscriptionModel) {
        let dir = directory(for: model)
        NSWorkspace.shared.activateFileViewerSelecting([
            FileManager.default.fileExists(atPath: dir.path)
                ? dir : dir.deletingLastPathComponent()
        ])
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
