import Foundation

/// Persists user-archived calendar events so they're hidden from Coming up.
///
/// Two modes:
/// - **By title** (series): hides all events sharing a title (e.g. "Lunch time" recurring)
/// - **By event ID**: hides a single event instance (stores the title for display)
final class ArchivedEventStore: ObservableObject {
    @Published private(set) var archivedTitles: Set<String>
    @Published private(set) var archivedEvents: [ArchivedEvent]

    struct ArchivedEvent: Codable, Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        var eventID: String { id }
    }

    private let defaults: UserDefaults
    private let titlesKey: String
    private let idsKey: String

    init(defaults: UserDefaults = .standard,
         titlesKey: String = SettingsKey.archivedEventTitles,
         idsKey: String = SettingsKey.archivedEventIDs) {
        self.defaults = defaults
        self.titlesKey = titlesKey
        self.idsKey = idsKey
        self.archivedTitles = Set(defaults.stringArray(forKey: titlesKey) ?? [])
        if let data = defaults.data(forKey: idsKey),
           let decoded = try? JSONDecoder().decode([ArchivedEvent].self, from: data) {
            self.archivedEvents = decoded
        } else {
            // Migrate from old plain string array
            let oldIDs = defaults.stringArray(forKey: idsKey) ?? []
            self.archivedEvents = oldIDs.map { ArchivedEvent(id: $0, title: "Archived event") }
        }
    }

    // MARK: - Title (series) archiving

    func archiveTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        archivedTitles.insert(trimmed)
        persistTitles()
        objectWillChange.send()
    }

    func unarchiveTitle(_ title: String) {
        archivedTitles.remove(title)
        persistTitles()
        objectWillChange.send()
    }

    func isTitleArchived(_ title: String) -> Bool {
        archivedTitles.contains(title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Individual event archiving

    func archiveEvent(id: String, title: String) {
        guard !archivedEvents.contains(where: { $0.id == id }) else { return }
        archivedEvents.append(ArchivedEvent(id: id, title: title))
        persistEvents()
        objectWillChange.send()
    }

    func unarchiveEvent(id: String) {
        archivedEvents.removeAll { $0.id == id }
        persistEvents()
        objectWillChange.send()
    }

    func isEventArchived(id: String) -> Bool {
        archivedEvents.contains { $0.id == id }
    }

    // MARK: - Filtering

    /// Returns `true` if the event should be hidden from views.
    func isArchived(title: String, eventID: String) -> Bool {
        isTitleArchived(title) || isEventArchived(id: eventID)
    }

    /// Clears all archived titles and event IDs.
    func clearAll() {
        archivedTitles.removeAll()
        archivedEvents.removeAll()
        persistTitles()
        persistEvents()
        objectWillChange.send()
    }

    var hasAny: Bool {
        !archivedTitles.isEmpty || !archivedEvents.isEmpty
    }

    // MARK: - Persistence

    private func persistTitles() {
        defaults.set(Array(archivedTitles).sorted(), forKey: titlesKey)
    }

    private func persistEvents() {
        do {
            let data = try JSONEncoder().encode(archivedEvents)
            defaults.set(data, forKey: idsKey)
        } catch { PersistenceStatus.record(error) }
    }
}
