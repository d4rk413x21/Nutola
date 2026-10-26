import AppKit
import SwiftUI

struct FolderDetailView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor

    let folderID: UUID
    @State private var name: String
    @State private var descriptionText: String
    @State private var showDeleteConfirm = false
    @State private var showIconEditor = false
    @State private var showAddExisting = false
    @FocusState private var editingName: Bool
    @FocusState private var editingDescription: Bool

    init(folder: MeetingFolder) {
        folderID = folder.id
        _name = State(initialValue: folder.name)
        _descriptionText = State(initialValue: folder.description ?? "")
    }

    private var folder: MeetingFolder? {
        app.folders.folder(id: folderID)
    }

    private var meetings: [Meeting] {
        app.folders.meetings(in: folderID, from: app.store)
    }

    /// #21 — Whether the folder has a non-empty description, used to compute
    /// top padding (tighter when there's no description line below the title).
    private var hasDescription: Bool {
        let d = folder?.description ?? descriptionText
        return !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    notesSection
                }
                .padding(.top, hasDescription ? 24 : 16)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .contentColumn()
                .frame(minHeight: meetings.isEmpty ? geo.size.height : nil, alignment: .top)
            }
        }
        .background(Theme.surface(scheme))
        .trackingEdits(isDirty: {
            guard let folder else { return false }
            return name.trimmingCharacters(in: .whitespacesAndNewlines) != folder.name
                || descriptionText != (folder.description ?? "")
        }, save: {
            saveName()
            saveDescription()
            return FilePersistence.failure(at: app.folders.archive.foldersDir
                .appendingPathComponent("folders.json")) == nil
        }, discard: {
            name = folder?.name ?? name
            descriptionText = folder?.description ?? ""
        })
        .onChange(of: folder?.name) { _, new in
            if let new, !editingName { name = new }
        }
        .onChange(of: folder?.description) { _, new in
            if !editingDescription { descriptionText = new ?? "" }
        }
        .confirmationDialog(
            "Delete “\(folder?.name ?? "folder")”?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Delete folder", role: .destructive) {
                app.folders.deleteFolder(id: folderID, meetingStore: app.store)
            }
        } message: {
            Text("Meetings in this folder will move back to the Meetings list. Nothing is deleted.")
        }
        .sheet(isPresented: $showAddExisting) {
            AddMeetingToFolderSheet(folderID: folderID) { meetingID in
                app.folders.assign(meetingID: meetingID, to: folderID, meetingStore: app.store)
            }
            .environmentObject(app)
        }
        .sheet(isPresented: $showIconEditor) {
            if let folder {
                FolderEditorSheet(
                    initialName: folder.name,
                    initialDescription: folder.description ?? "",
                    initialKind: folder.iconKind,
                    initialValue: folder.iconValue,
                    initialColorHex: folder.iconColorHex
                ) { name, description, kind, value, colorHex in
                    var updated = folder
                    updated.name = name
                    updated.description = description
                    updated.iconKind = kind
                    updated.iconValue = value
                    updated.iconColorHex = colorHex
                    app.folders.updateFolder(updated)
                    self.name = name
                    self.descriptionText = description ?? ""
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                if let folder {
                    Button { showIconEditor = true } label: {
                        FolderIconView(folder: folder, size: 40)
                    }
                    .buttonStyle(.plain)
                    .help("Edit folder")
                    .accessibilityLabel("Edit folder")
                }
                TextField("Folder name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.nutola(24, .bold))
                    .foregroundStyle(Theme.heading(scheme))
                    .focused($editingName)
                    .onSubmit(saveName)
                    .onChange(of: editingName) { if !editingName { saveName() } }
                Spacer()
                folderOverflowMenu
            }

            TextField("Add description…", text: $descriptionText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.nutola(13))
                .foregroundStyle(Theme.secondary(scheme))
                .lineLimit(1...3)
                .focused($editingDescription)
                .onSubmit(saveDescription)
                .onChange(of: editingDescription) { if !editingDescription { saveDescription() } }
        }
    }

    private var folderOverflowMenu: some View {
        Menu {
            Button("Edit folder…") { showIconEditor = true }
            Button("Rename") { editingName = true }
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete folder…", systemImage: "trash")
            }
            .destructiveMenuItemStyle()
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.open(app.folders.archive.foldersDir)
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .font(.nutola(13, .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var notesSection: some View {
        VStack(alignment: meetings.isEmpty ? .center : .leading, spacing: 12) {
            HStack {
                Text("Meetings")
                    .font(.nutola(15, .semibold))
                    .foregroundStyle(Theme.sectionTitle(scheme, accent: actionColor))
                Spacer()
                addExistingButton
            }

            if meetings.isEmpty {
                EmptyStateView(
                    title: "No meetings yet",
                    message: "This folder is empty. Add meetings to keep related notes together.",
                    tips: [
                        "Drag meetings here from the Meetings list",
                        "Use “Add existing” to pick from your library",
                        "Right-click a meeting and choose “Move to folder”"
                    ])
            } else {
                VStack(spacing: 0) {
                    ForEach(meetings) { meeting in
                        folderMeetingRow(meeting)
                        if meeting.id != meetings.last?.id {
                            Divider().padding(.leading, 8)
                        }
                    }
                }
                .cardStyle()
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: meetings.isEmpty ? .infinity : nil,
            alignment: meetings.isEmpty ? .center : .leading)
    }

    private var addExistingButton: some View {
        let unfiled = app.store.meetings.filter { $0.folderID == nil }
        return Button("Add existing") {
            showAddExisting = true
        }
        .font(.nutola(12, .medium))
        .disabled(unfiled.isEmpty)
    }

    private func folderMeetingRow(_ meeting: Meeting) -> some View {
        let isRecording = app.recordingMeeting?.id == meeting.id
        return Button {
            app.openMeetingID = meeting.id
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.calendarEventTitle ?? meeting.title)
                        .font(.nutola(13, .medium))
                        .foregroundStyle(Theme.heading(scheme))
                        .lineLimit(1)
                    Text(subtitle(for: meeting))
                        .font(.nutola(11))
                        .foregroundStyle(Theme.secondary(scheme))
                        .lineLimit(1)
                }
                Spacer()
                Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.nutola(11))
                    .foregroundStyle(Theme.secondary(scheme))
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .draggable(MeetingDragItem(meetingID: meeting.id), preview: { EmptyView() })
        .disabled(isRecording)
        .contextMenu {
            FolderPickerMenu(
                currentFolderID: meeting.folderID,
                calendarTitle: meeting.calendarEventTitle ?? meeting.title,
                meetingID: meeting.id
            ) {
                Text("Move to")
            }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [app.store.archive.folder(for: meeting.id)])
            }
            Button("Delete…", role: .destructive) {
                app.store.delete(id: meeting.id)
            }
        }
    }

    private func subtitle(for meeting: Meeting) -> String {
        if !meeting.attendees.isEmpty {
            let names = meeting.attendees.prefix(2).joined(separator: ", ")
            let extra = meeting.attendees.count - 2
            if extra > 0 { return "\(names) & \(extra) others" }
            return names
        }
        if meeting.duration > 0 {
            return TemplateRenderer.duration(meeting.duration)
        }
        return meeting.sourceApp ?? ""
    }

    private func saveName() {
        guard var f = folder else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != f.name else {
            name = f.name
            return
        }
        f.name = trimmed
        app.folders.updateFolder(f)
    }

    private func saveDescription() {
        guard var f = folder else { return }
        let trimmed = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let newDesc = trimmed.isEmpty ? nil : trimmed
        guard newDesc != f.description else { return }
        f.description = newDesc
        app.folders.updateFolder(f)
    }
}

private struct AddMeetingToFolderSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    let folderID: UUID
    let onSelect: (UUID) -> Void

    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool

    private var unfiledMeetings: [Meeting] {
        app.store.meetings
            .filter { $0.folderID == nil }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var filteredMeetings: [Meeting] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return unfiledMeetings }
        return unfiledMeetings.filter { MeetingSearch.matches($0, query: query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add to folder")
                .font(.nutola(13, .semibold))
                .foregroundStyle(Theme.heading(scheme))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary(scheme))
                TextField("Search meetings…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.nutola(13))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            if filteredMeetings.isEmpty {
                Text(
                    searchQuery.isEmpty
                        ? "No unfiled meetings."
                        : "No meetings match your search.")
                    .font(.nutola(13))
                    .foregroundStyle(Theme.secondary(scheme))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredMeetings) { meeting in
                    Button {
                        onSelect(meeting.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(meeting.calendarEventTitle ?? meeting.title)
                                .font(.nutola(13, .medium))
                                .foregroundStyle(Theme.heading(scheme))
                                .lineLimit(2)
                            Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.nutola(11))
                                .foregroundStyle(Theme.secondary(scheme))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 420, height: 480)
        .background(Theme.surface(scheme))
        .onAppear { searchFocused = true }
    }
}
