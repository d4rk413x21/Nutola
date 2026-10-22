import AppKit
import SwiftUI

/// Settings tab for choosing the transcription (ASR) engine and managing downloadable
/// models: pick Apple vs Soniqo Parakeet vs Nemotron, download weights into
/// Application Support with a live progress bar, and remove to reclaim disk space.
struct TranscriptionSettings: View {
    @Environment(\.nutolaActionColor) private var actionColor
    @AppStorage(SettingsKey.transcriptionModel) private var model: TranscriptionModel = .apple

    @State private var installed = false
    @State private var installedBytes: Int64 = 0
    @State private var downloading = false
    @State private var progress: Double = 0
    @State private var error: String?
    @State private var legacyBytes: Int64 = 0
    @State private var legacyRemovalError: String?
    @State private var pendingRemove = false
    @State private var freedBytes: Int64 = 0
    @State private var downloadTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Speech recognition") {
                Picker("Transcription engine", selection: $model) {
                    ForEach(TranscriptionModel.allCases) { option in
                        if option.isAvailable {
                            Text(option.displayName).tag(option)
                        } else {
                            // Unselectable: the inference engine isn't wired yet.
                            // Shown greyed with a "coming soon" suffix so the user
                            // sees what's coming but can't pick an inert engine.
                            Text("\(option.displayName) — coming soon")
                                .foregroundStyle(.secondary)
                                .tag(model)
                        }
                    }
                }
                Text(currentModel.detail)
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
                if !currentModel.isAvailable {
                    Text("This engine isn't wired up yet — Nutola transcribes with Apple Speech until it ships. You can't download or select it today.")
                        .font(.nutola(11))
                        .foregroundStyle(.secondary)
                }
                if currentModel.isAvailable && currentModel.isDownloadable {
                    Text(currentModel.supportsLiveTranscription
                         ? "Mode: live preview and final transcription"
                         : "Mode: final transcription only; live preview uses Apple Speech")
                        .font(.nutola(11))
                        .foregroundStyle(.secondary)
                }
            }

            if legacyBytes > 0 {
                Section("Unused legacy downloads") {
                    Text("The old Soniqo Parakeet and NVIDIA .nemo downloads are not used by the new FluidAudio engines.")
                        .font(.nutola(11))
                        .foregroundStyle(.secondary)
                    Button("Delete unused legacy models (\(TranscriptionModel.formatBytes(legacyBytes)))", role: .destructive) {
                        do {
                            _ = try FluidParakeetModels.deleteLegacyDownloads()
                            legacyBytes = FluidParakeetModels.legacyBytes()
                            legacyRemovalError = nil
                        } catch {
                            legacyRemovalError = error.localizedDescription
                        }
                    }
                    if let legacyRemovalError {
                        Text(legacyRemovalError).foregroundStyle(.red)
                    }
                }
            }

            if currentModel.isAvailable && currentModel.isDownloadable {
                Section("\(model.displayName) model") {
                    modelStatusRow
                    if downloading || !installed {
                        downloadRow
                    }
                    if installed {
                        removeModelRow
                    }
                    if let error {
                        Text(error)
                            .font(.nutola(11))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: model) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    /// Concrete snapshot of the selected model, read off the @AppStorage wrapper.
    /// Some `model.foo` accesses inside ViewBuilder conditions resolve `model` as a
    /// `Binding` (dynamic-member lookup), so we route through this plain value.
    private var currentModel: TranscriptionModel { model }

    // MARK: - Rows

    private var modelStatusRow: some View {
        HStack(alignment: .firstTextBaseline) {
            StatusDot(ok: installed ? true : (downloading ? nil : false))
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.nutola(12, .medium))
                Text(statusDetail)
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if installed {
                Button("Reveal in Finder") { model.revealModelInFinder() }
                    .controlSize(.small)
            }
        }
    }

    private var statusTitle: String {
        if installed { "Installed on this Mac" }
        else if downloading { "Downloading…" }
        else { "Not downloaded yet" }
    }

    private var statusDetail: String {
        if installed {
            "Uses \(TranscriptionModel.formatBytes(installedBytes)) of disk space"
        } else if downloading {
            "\(Int(progress * 100))% complete"
        } else {
            "About \(TranscriptionModel.formatBytes(model.modelTotalBytes)) from Hugging Face"
        }
    }

    private var downloadRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if downloading {
                ProgressView(value: progress) {
                    Text("Downloading \(model.displayName)…")
                        .font(.nutola(11))
                }
                Button("Cancel download") { cancelDownload() }
                    .controlSize(.small)
            } else {
                Button("Download model") { startDownload() }
                    .buttonStyle(.borderedProminent)
                    .tint(actionColor)
                    .controlSize(.small)
                Text("Downloads once to this Mac and stays available for future meetings until you remove it.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var removeModelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if pendingRemove {
                Text("Remove this model? You'll free up \(TranscriptionModel.formatBytes(installedBytes)). You can download it again anytime.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Remove", role: .destructive) {
                        Task { await confirmRemove() }
                    }
                    .controlSize(.small)
                    Button("Cancel") { pendingRemove = false }
                        .controlSize(.small)
                }
            } else {
                Button("Remove model") { pendingRemove = true }
                    .controlSize(.small)
                if freedBytes > 0 {
                    Text("Freed \(TranscriptionModel.formatBytes(freedBytes)).")
                        .font(.nutola(11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func refresh() async {
        legacyBytes = FluidParakeetModels.legacyBytes()
        installed = model.isModelInstalled
        installedBytes = model.modelInstalledBytes
        if installed {
            progress = 1
            downloading = false
        }
    }

    private func startDownload() {
        downloading = true
        progress = 0
        error = nil
        model.logModelEvent("starting download")
        downloadTask = Task {
            do {
                try await model.downloadModel { fraction in
                    Task { @MainActor in progress = fraction }
                }
                await MainActor.run {
                    Task { await refresh() }
                    model.logModelEvent("model installed")
                }
            } catch is CancellationError {
                model.logModelEvent("download cancelled")
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
                model.logModelEvent("download failed — \(error.localizedDescription)")
            }
            await MainActor.run {
                downloading = false
                downloadTask = nil
            }
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloading = false
        progress = 0
        Task { await refresh() }
    }

    private func confirmRemove() async {
        do {
            freedBytes = try model.deleteModel()
            pendingRemove = false
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
