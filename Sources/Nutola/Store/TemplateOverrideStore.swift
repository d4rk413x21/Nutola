import Foundation
import SwiftUI

/// Per-calendar-event template assignment. Maps a `CalendarEventSummary.id`
/// (the EventKit identifier, stable across the event's lifecycle) to a
/// template name. Consulted by `PrepareMeetingUseCase` and
/// `RecordingServiceImpl` after the smart/default template is picked, so an
/// explicit assignment wins over both.
@MainActor
final class TemplateOverrideStore: ObservableObject, TemplateOverrideRepository {
    @Published private(set) var overrides: [String: String] = [:]

    private let file: URL

    init(root: URL = MeetingArchive.defaultRoot) {
        let dir = root.appendingPathComponent("TemplateOverrides", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("overrides.json")
        load()
    }

    /// Returns the template name assigned to `eventID`, or nil if none (or if
    /// the assigned template no longer exists — stale overrides are pruned
    /// lazily on read so deleted templates don't silently fall back to a
    /// wrong default).
    func templateName(forEventID eventID: String, available: [String]) -> String? {
        guard let name = overrides[eventID] else { return nil }
        let lower = available.map { $0.lowercased() }
        guard lower.contains(name.lowercased()) else {
            // Template was deleted since the override was set. Drop the stale
            // entry so the default/smart path applies, matching user intent.
            if overrides[eventID] != nil {
                overrides[eventID] = nil
                persist()
            }
            return nil
        }
        return name
    }

    /// Assign `templateName` to `eventID`. Passing nil clears the override.
    func set(eventID: String, templateName: String?) {
        let trimmed = templateName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty == false) ? trimmed : nil
        overrides[eventID] = value
        persist()
    }

    func clear(eventID: String) {
        guard overrides[eventID] != nil else { return }
        overrides[eventID] = nil
        persist()
    }

    /// Prune overrides whose template no longer exists. Called after template
    /// delete/rename so the Coming Up UI doesn't show stale assignments.
    func pruneUnavailable(available: [String]) {
        let lower = Set(available.map { $0.lowercased() })
        let stale = overrides.filter { !lower.contains($0.value.lowercased()) }
        guard !stale.isEmpty else { return }
        for k in stale.keys { overrides[k] = nil }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        overrides = decoded
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(overrides)
            try FilePersistence.write(data, to: file)
        } catch { PersistenceStatus.record(error) }
    }
}
