import AppKit
import SwiftUI

struct DevelopmentTasksSheet: View {
    let meeting: Meeting
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var provider: AIProvider = AppSettings.preferredAIProvider.isCloud
        ? AppSettings.preferredAIProvider : .claude
    @State private var review = DevelopmentTaskReview()
    @State private var savedReview = DevelopmentTaskReview()
    @State private var selectedIDs: Set<UUID> = []
    @State private var currentFingerprint = ""
    @State private var extraction: Task<Void, Never>?
    @State private var isExtracting = false
    @State private var progress = ""
    @State private var error: String?
    @State private var loadFailed = false
    @State private var confirmReplace = false

    private var hasChanges: Bool { review != savedReview }
    private var isStale: Bool {
        !review.transcriptFingerprint.isEmpty && review.transcriptFingerprint != currentFingerprint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Development tasks").font(.title2.bold())
                    Text(meeting.title).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save & Close") {
                    if save() { dismiss() }
                }
                .disabled(isExtracting || loadFailed)
                .keyboardShortcut(.defaultAction)
                if loadFailed {
                    Button("Close") { dismiss() }
                }
            }

            HStack {
                Picker("Analyze with", selection: $provider) {
                    Text("Claude CLI").tag(AIProvider.claude)
                    Text("Codex CLI").tag(AIProvider.codex)
                }
                .frame(width: 240)
                .disabled(isExtracting)
                if isExtracting {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout)
                    Button("Stop") { extraction?.cancel() }
                } else {
                    Button(review.transcriptFingerprint.isEmpty ? "Extract tasks" : "Extract again") {
                        if review.transcriptFingerprint.isEmpty {
                            extract()
                        } else {
                            confirmReplace = true
                        }
                    }
                    .disabled(loadFailed || currentFingerprint.isEmpty)
                }
            }
            Text("The saved transcript is sent through your signed-in CLI. Review the drafts before using them in Linear.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if isStale {
                Label("The transcript has changed. These drafts refer to the earlier version.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }

            Divider()
            ScrollView {
                if review.tasks.isEmpty {
                    Text(review.transcriptFingerprint.isEmpty
                         ? "Extract development tasks from this meeting's full transcript."
                         : "No concrete development tasks were found in this meeting.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach($review.tasks) { $draft in
                            draftEditor($draft)
                        }
                    }
                    .padding(2)
                    .disabled(isExtracting || loadFailed)
                }
            }
            HStack {
                Text("\(selectedIDs.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Copy selected drafts") {
                    guard save() else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        review.markdown(meeting: meeting, selectedIDs: selectedIDs), forType: .string)
                }
                .disabled(selectedIDs.isEmpty || isExtracting || loadFailed)
            }
        }
        .padding(24)
        .frame(width: 760, height: 680)
        .interactiveDismissDisabled(isExtracting || hasChanges)
        .task { load() }
        .onDisappear { extraction?.cancel() }
        .confirmationDialog("Replace the saved drafts and any edits?", isPresented: $confirmReplace) {
            Button("Replace drafts", role: .destructive) { extract() }
        } message: {
            Text("Existing drafts stay unchanged if analysis fails or is stopped.")
        }
    }

    private func draftEditor(_ draft: Binding<DevelopmentTaskDraft>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Include task", isOn: Binding(
                    get: { selectedIDs.contains(draft.wrappedValue.id) },
                    set: { if $0 { selectedIDs.insert(draft.wrappedValue.id) } else { selectedIDs.remove(draft.wrappedValue.id) } }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Remove", role: .destructive) {
                    let id = draft.wrappedValue.id
                    selectedIDs.remove(id)
                    review.tasks.removeAll { $0.id == id }
                }
            }
            TextField("Task title", text: draft.title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Task title")
            TextEditor(text: draft.detail)
                .font(.body)
                .frame(minHeight: 130)
                .border(.quaternary)
                .accessibilityLabel("Task description")
            TextField("Owner (leave empty if unassigned)", text: Binding(
                get: { draft.wrappedValue.owner ?? "" },
                set: { draft.wrappedValue.owner = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Task owner")
            DisclosureGroup("Transcript evidence") {
                ForEach(draft.wrappedValue.evidence) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(speakerName(segment.speakerID)) @ \(MeetingArchive.timestamp(segment.start))")
                            .font(.caption.bold())
                        Text(segment.text).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            Divider()
        }
    }

    private func speakerName(_ id: String) -> String {
        meeting.speakers.first { $0.id == id }?.name ?? id
    }

    private func load() {
        do {
            if let saved = try app.store.archive.developmentTasks(for: meeting.id) {
                review = saved
                savedReview = saved
                selectedIDs = Set(saved.tasks.map(\.id))
            }
            let transcript = app.store.transcript(for: meeting.id)
            currentFingerprint = transcript.isEmpty ? "" : try DevelopmentTaskReview.fingerprint(transcript)
            if transcript.isEmpty { error = DevelopmentTaskError.noTranscript.localizedDescription }
        } catch {
            loadFailed = true
            self.error = "Could not load saved drafts: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard hasChanges else { return true }
        guard review.tasks.allSatisfy({
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            error = "Each task needs a title and description."
            return false
        }
        do {
            try app.store.archive.saveDevelopmentTasks(review, for: meeting.id)
            savedReview = review
            error = nil
            return true
        } catch {
            self.error = "Could not save drafts: \(error.localizedDescription)"
            return false
        }
    }

    private func extract() {
        let provider = self.provider
        let transcript = app.store.transcript(for: meeting.id)
        let state = app.store.meeting(id: meeting.id)?.state
        guard state == .ready || state == .failed else {
            error = "Wait until recording and transcript processing have finished."
            return
        }
        isExtracting = true
        error = nil
        extraction = Task { @MainActor in
            defer { isExtracting = false; extraction = nil }
            do {
                let result = try await DevelopmentTaskExtractor.extract(
                    meeting: meeting, transcript: transcript,
                    analyze: { prompt, input in
                        try await DevelopmentTaskExtractor.analyze(prompt: prompt, input: input, provider: provider)
                    },
                    onProgress: { part, total in progress = "Analyzing part \(part) of \(total)…" })
                try Task.checkCancellation()
                let latest = app.store.transcript(for: meeting.id)
                guard try DevelopmentTaskReview.fingerprint(latest) == result.transcriptFingerprint else {
                    throw DevelopmentTaskError.transcriptChanged
                }
                try app.store.archive.saveDevelopmentTasks(result, for: meeting.id)
                review = result
                savedReview = result
                currentFingerprint = result.transcriptFingerprint
                selectedIDs = Set(result.tasks.map(\.id))
            } catch is CancellationError {
                // Keep the saved drafts and the user's current edits.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
