import AppKit
import SwiftUI

/// Debug tab panel: a history of recorded crashes, newest first. Each row is a
/// one-line title (kind + detail, e.g. "signal: SIGABRT") with a relative time and
/// a kind-colored icon; selecting a row shows the full scrubbed JSON record with a
/// Copy button. Toolbar: Refresh, Copy All, Clear All (red). Each row has a
/// trash button to delete that single record and a hover affordance.
///
/// Records are read from `CrashDiagnosticLog.allCrashes()` (files under
/// `~/Library/Application Support/Nutola/Crashes/`), written by the opt-in crash
/// handlers — never audio, transcript, or summary text.
struct CrashHistoryPanel: View {
    @Environment(\.colorScheme) private var scheme
    @State private var crashes: [CrashDiagnosticLog.CrashRecord] = []
    @State private var selectedID: String?
    @State private var hoveredID: String?
    @State private var showClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if crashes.isEmpty {
                emptyState
            } else {
                detailSplit
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { reload() }
        // #25 — confirmation before deleting all crash records, since Clear All
        // looks similar to Copy All and the action is irreversible.
        .confirmationDialog(
            "Clear all crash records?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                CrashDiagnosticLog.clearAllCrashes()
                reload()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes all \(crashes.count) saved crash record\(crashes.count == 1 ? "" : "s"). This cannot be undone.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "ladybug")
                .font(.nutola(12, .medium))
                .foregroundStyle(Theme.blueberry(scheme))
            Text("Crash history")
                .font(.nutola(12, .semibold))
                .foregroundStyle(Theme.heading(scheme))
            if !crashes.isEmpty {
                Text("\(crashes.count)")
                    .font(.nutola(10, .semibold))
                    .foregroundStyle(Theme.tertiary(scheme))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.chip(scheme), in: Capsule())
            }
            Spacer()
            toolbarButton("Refresh", icon: "arrow.clockwise",
                           hint: "Reload the crash history from disk") { reload() }
            toolbarButton("Copy All", icon: "doc.on.doc", disabled: crashes.isEmpty,
                           hint: "Copy every crash record to the clipboard") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(CrashDiagnosticLog.allCrashesText(), forType: .string)
            }
            toolbarButton("Export…", icon: "square.and.arrow.up", disabled: crashes.isEmpty,
                           hint: "Save every crash record to a file") {
                exportCrashes()
            }
            toolbarButton("Clear All", icon: "trash", tint: .red, disabled: crashes.isEmpty,
                           role: .destructive,
                           hint: "Delete every saved crash record") {
                showClearConfirm = true
            }
        }
    }

    private func toolbarButton(
        _ label: String,
        icon: String,
        tint: Color? = nil,
        disabled: Bool = false,
        role: ButtonRole? = nil,
        hint: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        // #25 — Use Button(role:) when a role is set (e.g. .destructive) so the
        // button is semantically marked for accessibility and appearance.
        Group {
            if let role {
                Button(role: role, action: action) {
                    toolbarButtonLabel(icon: icon, label: label, tint: tint)
                }
            } else {
                Button(action: action) {
                    toolbarButtonLabel(icon: icon, label: label, tint: tint)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? label)
    }

    @ViewBuilder
    private func toolbarButtonLabel(icon: String, label: String, tint: Color?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.nutola(9))
            Text(label).font(.nutola(10))
        }
        .foregroundStyle(tint ?? Theme.blueberry(scheme))
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.mint(scheme))
            Text("No crashes recorded")
                .font(.nutola(12, .semibold))
                .foregroundStyle(Theme.secondary(scheme))
            Text(
                "Enable “Crash diagnostics” in General to capture scrubbed crash records "
                + "(no audio/transcript/notes) for bug reports.")
                .font(.nutola(10))
                .foregroundStyle(Theme.tertiary(scheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: List + detail split

    private var detailSplit: some View {
        HStack(spacing: 0) {
            crashList
            Divider()
            detailPane
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }

    private var crashList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(crashes) { crash in
                    crashRow(crash)
                    if crash.id != crashes.last?.id {
                        Divider().opacity(0.4).padding(.leading, 10)
                    }
                }
            }
        }
        .frame(width: 230)
    }

    private func crashRow(_ crash: CrashDiagnosticLog.CrashRecord) -> some View {
        let selected = crash.id == selectedID
        let hovered = crash.id == hoveredID
        return HStack(spacing: 8) {
            // Accent bar: solid when selected, faint on hover, clear otherwise.
            RoundedRectangle(cornerRadius: 1)
                .fill(selected ? Theme.blueberry(scheme) : Color.clear)
                .frame(width: 2)
            kindIcon(crash.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(crash.title)
                    .font(.nutola(10, .semibold))
                    .foregroundStyle(selected ? Theme.heading(scheme) : Theme.secondary(scheme))
                    .lineLimit(1)
                Text(crash.relativeTime)
                    .font(.nutola(9))
                    .foregroundStyle(Theme.tertiary(scheme))
                    .lineLimit(1)
            }
            Spacer()
            Button {
                CrashDiagnosticLog.delete(crash)
                reload()
            } label: {
                Image(systemName: "trash")
                    .font(.nutola(9))
                    .foregroundStyle(.secondary.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Delete this crash record")
            .accessibilityLabel("Delete this crash record")
            .opacity(hovered || selected ? 1 : 0.5)
        }
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(
            (selected ? Theme.blueberry(scheme).opacity(0.1)
              : (hovered ? Color.primary.opacity(0.04) : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hoveredID = $0 ? crash.id : (hoveredID == crash.id ? nil : hoveredID) }
        .onTapGesture { selectedID = crash.id }
        .accessibilityAction(named: Text("Show crash details")) { selectedID = crash.id }
        .focusable()
        .onKeyPress(.return) { selectedID = crash.id; return .handled }
    }

    private func kindIcon(_ kind: String) -> some View {
        let isException = kind == "exception"
        let icon = isException ? "exclamationmark.bubble" : "exclamationmark.triangle"
        let color = isException ? Theme.raspberry : Theme.honey(scheme)
        return Image(systemName: icon)
            .font(.nutola(11))
            .foregroundStyle(color)
    }

    private var detailPane: some View {
        Group {
            if let selected = crashes.first(where: { $0.id == selectedID }) {
                VStack(alignment: .leading, spacing: 0) {
                    detailHeader(for: selected)
                    Divider()
                    ScrollView {
                        Text(CrashDiagnosticLog.text(for: selected))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Theme.tertiary(scheme))
                    Text("Select a crash to see its details.")
                        .font(.nutola(10))
                        .foregroundStyle(Theme.tertiary(scheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func detailHeader(for record: CrashDiagnosticLog.CrashRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            kindIcon(record.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.nutola(11, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                    .lineLimit(1)
                Text(record.id)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.tertiary(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    CrashDiagnosticLog.text(for: record), forType: .string)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "doc.on.doc").font(.nutola(9))
                    Text("Copy").font(.nutola(10))
                }
                .foregroundStyle(Theme.blueberry(scheme))
            }
            .buttonStyle(.plain)
            .help("Copy this crash record")
            .accessibilityLabel("Copy this crash record")
        }
        .padding(12)
    }

    // MARK: Actions

    private func reload() {
        crashes = CrashDiagnosticLog.allCrashes()
        if !crashes.contains(where: { $0.id == selectedID }) {
            selectedID = crashes.first?.id
        }
    }

    private func exportCrashes() {
        let panel = NSSavePanel()
        panel.title = "Export Crash History"
        panel.nameFieldStringValue = "nutola-crash-history.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let text = CrashDiagnosticLog.allCrashesText()
        try? FilePersistence.write(Data(text.utf8), to: dest)
    }
}
