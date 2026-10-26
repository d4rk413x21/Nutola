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
    @State private var confirmDiscard = false

    @State private var isPublishing = false
    @State private var publication: Task<Void, Never>?
    @State private var linearClient: LinearClient?
    @State private var workspace: LinearWorkspace?
    @State private var teams: [LinearTeam] = []
    @State private var projects: [LinearProject] = []
    @State private var teamID = ""
    @State private var projectID = ""
    @State private var loadingLinear = false
    @State private var loadingProjects = false
    @State private var showLinearSettings = false

    private var busy: Bool { isExtracting || isPublishing }
    private var hasExports: Bool { review.tasks.contains { $0.linearExport != nil } }
    private var publishCount: Int {
        review.tasks.filter { selectedIDs.contains($0.id) && $0.linearExport?.url == nil }.count
    }
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
                .disabled(busy || loadFailed)
                .keyboardShortcut(.defaultAction)
                if hasChanges && !busy {
                    Button("Discard changes") { confirmDiscard = true }
                        .keyboardShortcut(.cancelAction)
                }
                if loadFailed {
                    Button("Close") { dismiss() }
                }
            }

            HStack {
                Picker("Analyze with", selection: $provider) {
                    ForEach(AIProvider.allCases.filter(\.isCloud)) { provider in
                        Text("\(provider.displayName) CLI").tag(provider)
                    }
                }
                .frame(width: 240)
                .disabled(busy)
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
                    .disabled(busy || hasExports || loadFailed || currentFingerprint.isEmpty)
                }
            }
            Text("The saved transcript is sent through your signed-in CLI. Review the drafts before creating issues in Linear.")
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
            linearControls
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
                    .disabled(busy || loadFailed)
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
                .disabled(selectedIDs.isEmpty || busy || loadFailed)
            }
        }
        .padding(24)
        .frame(width: 760, height: 680)
        .interactiveDismissDisabled(busy || hasChanges)
        .confirmationDialog("Discard unsaved task edits?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard and Close", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Saved drafts and Linear issues will stay unchanged. Copy the selected drafts first if you want to keep the unsaved text elsewhere.")
        }
        .task { load(); await loadLinear() }
        .task(id: teamID) { await loadProjects() }
        .onReceive(NotificationCenter.default.publisher(for: LinearCredentials.changed)) { _ in
            publication?.cancel()
            linearClient = nil
            workspace = nil
            Task { await loadLinear() }
        }
        .onChange(of: teamID) { projectID = ""; projects = [] }
        .onDisappear { extraction?.cancel(); publication?.cancel() }
        .sheet(isPresented: $showLinearSettings, onDismiss: { Task { await loadLinear() } }) {
            VStack {
                LinearSettings()
                Button("Done") { showLinearSettings = false }.padding(.bottom)
            }
            .frame(width: 520, height: 440)
        }
        .confirmationDialog("Replace the saved drafts and any edits?", isPresented: $confirmReplace) {
            Button("Replace drafts", role: .destructive) { extract() }
        } message: {
            Text("Existing drafts stay unchanged if analysis fails or is stopped.")
        }
    }

    private var linearControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(workspace.map { "Linear · \($0.name)" } ?? "Linear").font(.headline)
                Spacer()
                if loadingLinear || isPublishing { ProgressView().controlSize(.small) }
                Button("Configure Linear") { showLinearSettings = true }.disabled(busy || loadingLinear)
                Button("Refresh teams") { Task { await loadLinear() } }.disabled(busy || loadingLinear)
            }
            if workspace != nil {
                HStack {
                    Picker("Team", selection: $teamID) {
                        Text("Choose a team").tag("")
                        ForEach(teams) { Text("\($0.key) · \($0.name)").tag($0.id) }
                    }
                    Picker("Project", selection: $projectID) {
                        Text("No project").tag("")
                        ForEach(projects) { Text($0.name).tag($0.id) }
                    }
                    .disabled(teamID.isEmpty || loadingProjects)
                    if loadingProjects { ProgressView().controlSize(.small) }
                    Button("Create / retry \(publishCount) issues") { publish() }
                        .disabled(publishCount == 0 || teamID.isEmpty || loadingLinear || loadingProjects || isStale || loadFailed)
                }
                .disabled(busy)
                Text("Only selected drafts and quoted passages are sent. Names remain in the description; assignments are managed in Linear.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Connect a personal API key in Configure Linear or Settings → Integrations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if hasExports {
                Text("Linked and pending tasks are retained. Edit created issues in Linear; extracting again is disabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @MainActor
    private func loadLinear() async {
        guard !busy, !loadingLinear else { return }
        loadingLinear = true
        linearClient = nil
        workspace = nil
        teams = []
        teamID = ""
        projects = []
        projectID = ""
        defer { loadingLinear = false }
        do {
            guard let key = try LinearCredentials.load() else { return }
            let client = try LinearClient(apiKey: key)
            let result = try await client.teams()
            guard !Task.isCancelled, try LinearCredentials.load() == key else { return }
            linearClient = client
            workspace = result.workspace
            teams = result.teams
            if let pending = review.tasks.compactMap(\.linearExport).first(where: { $0.url == nil && $0.workspaceID == result.workspace.id }),
               teams.contains(where: { $0.id == pending.teamID }) {
                teamID = pending.teamID
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    @MainActor
    private func loadProjects() async {
        let requestedTeam = teamID
        guard !requestedTeam.isEmpty, let client = linearClient else { loadingProjects = false; return }
        loadingProjects = true
        defer { if teamID == requestedTeam { loadingProjects = false } }
        do {
            let result = try await client.projects(teamID: requestedTeam)
            guard !Task.isCancelled, teamID == requestedTeam else { return }
            projects = result
            if let pending = review.tasks.compactMap(\.linearExport).first(where: { $0.url == nil && $0.teamID == requestedTeam }),
               let id = pending.projectID, result.contains(where: { $0.id == id }) { projectID = id }
        } catch { if !Task.isCancelled, teamID == requestedTeam { self.error = error.localizedDescription } }
    }

    private func publish() {
        guard !busy, !isStale, !loadingProjects, let client = linearClient, let workspace,
              teams.contains(where: { $0.id == teamID }),
              projectID.isEmpty || projects.contains(where: { $0.id == projectID }), save() else { return }
        let snapshot = review
        let selected = selectedIDs
        let targetTeam = teamID
        let targetProject = projectID.isEmpty ? nil : projectID
        isPublishing = true
        error = nil
        publication = Task { @MainActor in
            defer {
                isPublishing = false
                publication = nil
                if linearClient == nil { Task { await loadLinear() } }
            }
            do {
                _ = try await LinearTaskPublisher.publish(
                    review: snapshot, selectedIDs: selected, meeting: meeting,
                    workspaceID: workspace.id, teamID: targetTeam, projectID: targetProject, client: client,
                    save: { next, previous in
                        try app.store.archive.saveDevelopmentTasks(next, for: meeting.id, replacing: previous)
                    }, onProgress: { next in review = next; savedReview = next })
            } catch {
                self.error = Task.isCancelled
                    ? "Publishing stopped. Retry to recover any issue already created."
                    : error.localizedDescription
            }
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
                .disabled(draft.wrappedValue.linearExport != nil)
            }
            if let exported = draft.wrappedValue.linearExport {
                if let url = exported.url {
                    Link(exported.identifier ?? "Open in Linear", destination: url)
                } else {
                    Label("Creation pending — retry to check Linear before creating again.", systemImage: "arrow.clockwise")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("If the issue already exists, retry recovers its link without applying further draft edits.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("Task title", text: draft.title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Task title")
                .disabled(draft.wrappedValue.linearExport?.url != nil)
            TextEditor(text: draft.detail)
                .font(.body)
                .frame(minHeight: 130)
                .border(.quaternary)
                .accessibilityLabel("Task description")
                .disabled(draft.wrappedValue.linearExport?.url != nil)
            TextField("Owner (leave empty if unassigned)", text: Binding(
                get: { draft.wrappedValue.owner ?? "" },
                set: { draft.wrappedValue.owner = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Task owner")
                .disabled(draft.wrappedValue.linearExport?.url != nil)
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
                selectedIDs = Set(saved.tasks.filter { $0.linearExport?.url == nil }.map(\.id))
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
            try app.store.archive.saveDevelopmentTasks(review, for: meeting.id, replacing: savedReview)
            savedReview = review
            error = nil
            return true
        } catch {
            self.error = "Could not save drafts: \(error.localizedDescription)"
            return false
        }
    }

    private func extract() {
        guard !hasExports, !busy else { return }
        let expectedReview = savedReview
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
                review = result
                currentFingerprint = result.transcriptFingerprint
                selectedIDs = Set(result.tasks.map(\.id))
                try app.store.archive.saveDevelopmentTasks(result, for: meeting.id, replacing: expectedReview)
                savedReview = result
            } catch is CancellationError {
                // Keep the saved drafts and the user's current edits.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
