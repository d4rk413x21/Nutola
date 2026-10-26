import SwiftUI

struct MeetingsListView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor

    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    @State private var meetingToDelete: Meeting?
    @State private var showImportAudio = false
    @State private var importError: String?
    @State private var isImporting = false

    private var groups: [MeetingDayGroup] {
        MeetingDayGrouper.group(meetings: app.store.meetings)
    }

    private var filteredGroups: [MeetingDayGroup] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        let filtered = app.store.meetings.filter { MeetingSearch.matches($0, query: query) }
        return MeetingDayGrouper.group(meetings: filtered)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Meetings")
                        .font(.nutola(22, .bold))
                        .foregroundStyle(Theme.heading(scheme))
                    Spacer()
                    Menu {
                        Button {
                            showImportAudio = true
                        } label: {
                            Label("Import Audio…", systemImage: "waveform.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.nutola(15, .medium))
                            .foregroundStyle(Theme.secondary(scheme))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                searchField

                if groups.isEmpty {
                    EmptyStateView(
                        title: "No meetings yet",
                        message: "Recorded meetings will appear here.")
                } else if filteredGroups.isEmpty {
                    EmptyStateView(
                        title: "No matches",
                        message: "Try a different title, attendee, or calendar event name.")
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(filteredGroups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(group.label)
                                        .font(.nutola(15, .semibold))
                                        .foregroundStyle(Theme.sectionTitle(scheme, accent: actionColor))
                                    Text("\(group.meetings.count)")
                                        .font(.nutola(12, .medium))
                                        .foregroundStyle(Theme.tertiary(scheme))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Theme.chip(scheme), in: Capsule())
                                }
                                VStack(spacing: 0) {
                                    ForEach(group.meetings) { meeting in
                                        MeetingHistoryRow(meeting: meeting) {
                                            app.openMeetingID = meeting.id
                                        }
                                        .help(meeting.title)
                                        .contextMenu {
                                            FolderPickerMenu(
                                                currentFolderID: meeting.folderID,
                                                calendarTitle: meeting.calendarEventTitle ?? meeting.title,
                                                meetingID: meeting.id
                                            ) {
                                                Label("Move to Folder", systemImage: "folder")
                                            }
                                            Divider()
                                            Button(role: .destructive) {
                                                meetingToDelete = meeting
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                            .disabled(app.recordingMeeting?.id == meeting.id)
                                        }
                                        if meeting.id != group.meetings.last?.id {
                                            Divider().padding(.leading, 8)
                                        }
                                    }
                                }
                                .cardStyle()
                            }
                        }
                    }
                }
            }
            .padding(24)
            .contentColumn()
        }
        .background(Theme.surface(scheme))
        .onAppear { searchFocused = false }
        .background {
            Button("Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: Binding(
                get: { meetingToDelete != nil },
                set: { if !$0 { meetingToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete meeting, transcript, and notes", role: .destructive) {
                guard let meetingToDelete else { return }
                app.store.delete(id: meetingToDelete.id)
                self.meetingToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                self.meetingToDelete = nil
            }
        } message: {
            if let meetingToDelete {
                Text("“\(meetingToDelete.calendarEventTitle ?? meetingToDelete.title)” and its transcript, notes, and audio files will be permanently deleted. This cannot be undone.")
            }
        }
        .modifier(ImportAudioModifier(
            showImportAudio: $showImportAudio,
            importError: $importError,
            isImporting: $isImporting,
            importHandler: { url in
                isImporting = true
                Task {
                    _ = await app.importAudio(fileURL: url)
                    await MainActor.run { isImporting = false }
                }
            }
        ))
    }

    private struct ImportAudioModifier: ViewModifier {
        @Binding var showImportAudio: Bool
        @Binding var importError: String?
        @Binding var isImporting: Bool
        var importHandler: (URL) -> Void
        @EnvironmentObject private var app: AppState
        @Environment(\.colorScheme) private var scheme

        func body(content: Content) -> some View {
            content
                .fileImporter(
                    isPresented: $showImportAudio,
                    allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Movie],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        importHandler(url)
                    case .failure(let error):
                        importError = error.localizedDescription
                    }
                }
                .alert("Import failed", isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } })
                ) {
                    Button("OK") { importError = nil }
                } message: {
                    Text(importError ?? "")
                }
                .overlay {
                    if isImporting {
                        ProgressView("Importing & transcribing…")
                            .padding(20)
                            .background(Theme.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(searchFocused ? actionColor : Theme.secondary(scheme))

            TextField("Search meetings…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.nutola(14))
                .focused($searchFocused)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiary(scheme))
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    searchFocused ? actionColor.opacity(0.45) : Color.primary.opacity(0.08),
                    lineWidth: searchFocused ? 1.5 : 1)
        }
    }
}

enum MeetingSearch {
    static func matches(_ meeting: Meeting, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if meeting.title.localizedCaseInsensitiveContains(q) { return true }
        if let calendar = meeting.calendarEventTitle,
           calendar.localizedCaseInsensitiveContains(q) { return true }
        if meeting.attendees.contains(where: { $0.localizedCaseInsensitiveContains(q) }) {
            return true
        }
        if let source = meeting.sourceApp, source.localizedCaseInsensitiveContains(q) {
            return true
        }
        return false
    }
}
