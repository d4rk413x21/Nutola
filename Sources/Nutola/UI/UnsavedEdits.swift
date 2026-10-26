import AppKit
import SwiftUI

/// Shares save/discard decisions between navigation, window closure and app termination.
@MainActor
final class UnsavedEdits: ObservableObject {
    static let shared = UnsavedEdits()
    struct Entry {
        var isDirty: () -> Bool
        var save: () -> Bool
        var discard: () -> Void
    }
    @Published private var entries: [UUID: Entry] = [:]
    var hasChanges: Bool { entries.values.contains { $0.isDirty() } }

    func register(_ id: UUID, entry: Entry) { entries[id] = entry }
    func remove(_ id: UUID) { entries[id] = nil }
    func changed() { objectWillChange.send() }

    @discardableResult
    func saveAll() -> Bool {
        // Saving one editor can update another; always check its current state.
        for entry in Array(entries.values) where entry.isDirty() {
            if !entry.save() { return false }
        }
        return true
    }

    func discardAll() {
        for entry in Array(entries.values) where entry.isDirty() { entry.discard() }
        changed()
    }

    func confirmLeaving() -> Bool {
        guard hasChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save your changes before leaving?"
        alert.informativeText = "Your edits have not been saved. You can save them, discard them, or keep editing."
        alert.addButton(withTitle: "Save Changes")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveAll()
        case .alertSecondButtonReturn: discardAll(); return true
        default: return false
        }
    }
}

private struct TrackUnsavedEdits: ViewModifier {
    @State private var id = UUID()
    let entry: UnsavedEdits.Entry

    func body(content: Content) -> some View {
        content
            .onAppear { UnsavedEdits.shared.register(id, entry: entry) }
            .onChange(of: entry.isDirty()) { UnsavedEdits.shared.changed() }
            .onDisappear { UnsavedEdits.shared.remove(id) }
    }
}

extension View {
    func trackingEdits(isDirty: @escaping () -> Bool, save: @escaping () -> Bool,
                       discard: @escaping () -> Void) -> some View {
        modifier(TrackUnsavedEdits(entry: .init(isDirty: isDirty, save: save, discard: discard)))
    }
}
