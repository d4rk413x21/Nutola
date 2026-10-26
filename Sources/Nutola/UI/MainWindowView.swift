import SwiftUI

enum SidebarItem: Hashable {
    case home
    case meetings
    case insights
    case digest
    case library
    case folder(UUID)
}

struct MainWindowView: View {
    @EnvironmentObject private var app: AppState
    @State private var selection: SidebarItem? = .home
    @State private var presentedMeetingID: UUID?
    @State private var showNewFolder = false
    @ObservedObject private var edits = UnsavedEdits.shared

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            detail
        }
        .frame(minWidth: 780, minHeight: 540)
        .onAppear { adoptPendingSelection() }
        .onChange(of: app.openMeetingID) { adoptPendingSelection() }
        .dismissalConfirmationDialog("Discard unsaved changes?", shouldPresent: edits.hasChanges) {
            Button("Discard Changes", role: .destructive) { edits.discardAll() }
        } message: {
            Text("Keep editing to save your changes before closing this window.")
        }
        .sheet(isPresented: $showNewFolder) {
            FolderEditorSheet(title: "New folder") { name, description, kind, value, colorHex in
                let folder = app.folders.createFolder(
                    name: name,
                    description: description,
                    iconKind: kind,
                    iconValue: value,
                    iconColorHex: colorHex)
                select(.folder(folder.id))
            }
        }
    }

    private func adoptPendingSelection() {
        if let id = app.openMeetingID {
            app.openMeetingID = nil
            guard presentedMeetingID == id || edits.confirmLeaving() else { return }
            presentedMeetingID = id
        }
    }

    private func dismissMeeting() {
        guard edits.confirmLeaving() else { return }
        presentedMeetingID = nil
    }

    private func select(_ item: SidebarItem?) {
        guard item != selection || presentedMeetingID != nil else { return }
        guard edits.confirmLeaving() else { return }
        selection = item
        presentedMeetingID = nil
    }
    private var meetingBackTitle: String {
        switch selection {
        case .home: "Coming up"
        case .meetings: "Meetings"
        case .insights: "Insights"
        case .digest: "Daily Digest"
        case .library: "Ask"
        case .folder(let id):
            app.folders.folder(id: id)?.name ?? "Folder"
        case nil: "Back"
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { selection }, set: select)) {
            navSection
            foldersSection
        }
        .listStyle(.sidebar)
        .navigationTitle("Nutola")
        .safeAreaInset(edge: .bottom) {
            if let session = app.session {
                SidebarRecordingStrip(session: session)
            }
        }
    }
    private var navSection: some View {
        Section {
            sidebarRow(.home, label: "Coming up", icon: "calendar")
            sidebarRow(.meetings, label: "Meetings", icon: "list.bullet.rectangle")
            sidebarRow(.insights, label: "Insights", icon: "chart.bar.xaxis")
            sidebarRow(.library, label: "Ask", icon: "bubble.left.and.text.bubble.right")
            sidebarRow(.digest, label: "Daily Digest", icon: "list.bullet.clipboard")
        }
    }

    private func sidebarRow(_ item: SidebarItem, label: String, icon: String) -> some View {
        Label(label, systemImage: icon)
            .font(.body)
            .symbolRenderingMode(.monochrome)
            .tag(item)
    }

    private var foldersSection: some View {
        Section("Folders") {
            ForEach(app.folders.folders) { folder in
                FolderSidebarRow(folder: folder)
                    .tag(SidebarItem.folder(folder.id))
            }
            Button {
                showNewFolder = true
            } label: {
                Label("New folder", systemImage: "plus")
                    .font(.nutola(13, .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            if let id = presentedMeetingID,
               let meeting = app.store.meetings.first(where: { $0.id == id }) {
                MeetingDetailView(
                    meeting: meeting,
                    backTitle: meetingBackTitle,
                    onBack: dismissMeeting)
            } else if presentedMeetingID != nil {
                EmptyStateView(
                    title: "Meeting not found",
                    message: "It may have been deleted.")
                .onAppear { dismissMeeting() }
            } else {
                switch selection {
                case .home:
                    ComingUpView()
                case .meetings:
                    MeetingsListView()
                case .insights:
                    MeetingInsightsView()
                case .digest:
                    DailyDigestView()
                case .library:
                    LibraryLauncherView()
                case .folder(let id):
                    if let folder = app.folders.folder(id: id) {
                        FolderDetailView(folder: folder)
                    } else {
                        EmptyStateView(
                            title: "Folder not found",
                            message: "It may have been deleted.")
                    }
                case nil:
                    ComingUpView()
                }
            }
        }
        .id(detailIdentity)
    }

    private var detailIdentity: String {
        if let id = presentedMeetingID {
            return "meeting-\(id.uuidString)"
        }
        return "section-\(String(describing: selection))"
    }
}

private struct FolderSidebarRow: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme
    let folder: MeetingFolder
    @State private var isDropTargeted = false
    @State private var showDeleteConfirm = false
    @State private var showIconEditor = false
    @State private var renameName = ""
    @State private var showRename = false

    var body: some View {
        FolderLabel(folder: folder, iconSize: 20)
            .font(.nutola(13, .medium))
            .foregroundStyle(Theme.heading(scheme))
            .padding(.vertical, 2)
            .background(isDropTargeted ? Theme.mint(scheme).opacity(0.2) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .dropDestination(for: MeetingDragItem.self) { items, _ in
                guard let item = items.first else { return false }
                let meeting = app.store.meeting(id: item.meetingID)
                if meeting?.folderID == folder.id { return false }
                app.folders.assign(meetingID: item.meetingID, to: folder.id, meetingStore: app.store)
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
            .contextMenu {
                Button("Edit folder…") { showIconEditor = true }
                Button("Rename") {
                    renameName = folder.name
                    showRename = true
                }
                Button("Delete…", role: .destructive) { showDeleteConfirm = true }
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.open(app.folders.archive.foldersDir)
                }
            }
            .alert("Rename folder", isPresented: $showRename) {
                TextField("Name", text: $renameName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    var f = folder
                    let trimmed = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    f.name = trimmed
                    app.folders.updateFolder(f)
                }
            }
            .confirmationDialog("Delete “\(folder.name)”?", isPresented: $showDeleteConfirm) {
                Button("Delete folder", role: .destructive) {
                    app.folders.deleteFolder(id: folder.id, meetingStore: app.store)
                }
            } message: {
                Text("Meetings in this folder will be unfiled.")
            }
            .sheet(isPresented: $showIconEditor) {
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
                }
            }
    }
}

private struct SidebarRecordingStrip: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var session: RecordingSession
    @EnvironmentObject private var app: AppState
    @Environment(\.nutolaActionColor) private var actionColor

    var body: some View {
        HStack(spacing: 8) {
            RecordDot()
            Text(timeString(session.elapsed))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Spacer()
            Button("Stop") { Task { await app.stopRecording() } }
                .buttonStyle(.borderedProminent)
                .tint(actionColor)
                .controlSize(.small)
        }
        .padding(12)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 12))
        .padding(10)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
