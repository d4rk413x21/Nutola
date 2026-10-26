import Foundation
import SwiftUI

/// One day's accumulated token usage (prompt + completion), persisted as JSON
/// in UserDefaults so the Settings chart survives relaunches without file I/O.
struct DailyTokenUsage: Codable, Identifiable, Equatable, Sendable {
    /// ISO-8601 calendar date ("yyyy-MM-dd") — stable id across launches.
    let date: String
    let promptTokens: Int
    let completionTokens: Int

    var id: String { date }
    var totalTokens: Int { promptTokens + completionTokens }
}

/// Tracks token usage per calendar day so the Settings "Token Usage" chart can
/// show the last 14 days of AI activity (Claude summaries, Apple Intelligence
/// asks, …). Each completed AI request calls `record(promptTokens:completionTokens:)`
/// which adds to today's running total and persists the array to UserDefaults.
///
/// Backed by a JSON `[DailyTokenUsage]` under `SettingsKey.tokenUsageHistory`.
/// UserDefaults is documented thread-safe and mutations are short, so the
/// tracker mirrors `RecipeStore`/`PinnedSegmentsStore` and is
/// `@unchecked Sendable` rather than `@MainActor`-isolated — AI requests run
/// off the main thread and call `record` directly.
final class TokenUsageTracker: ObservableObject, @unchecked Sendable {
    static let shared = TokenUsageTracker()

    private let defaults: UserDefaults
    private let key: String
    private let queue = DispatchQueue(label: "io.github.d4rk413x21.Nutola.token-usage", qos: .utility)
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// Convenience for app use: history lives in `UserDefaults.standard` under
    /// the shared `SettingsKey.tokenUsageHistory` key.
    convenience init() {
        self.init(defaults: AppSettings.defaults, key: SettingsKey.tokenUsageHistory)
    }

    /// Testable initializer: pass an isolated `UserDefaults` suite and a unique
    /// key so tests never touch the user's real usage history.
    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    // MARK: - Writes

    /// Add `promptTokens`/`completionTokens` to today's running total, creating
    /// a new day's row if today isn't present yet. Persists synchronously to
    /// UserDefaults and publishes `objectWillChange` so any observing chart
    /// refreshes. Safe to call off the main thread.
    func record(promptTokens: Int, completionTokens: Int) {
        queue.sync {
            var entries = load()
            let today = todayString()
            if let index = entries.firstIndex(where: { $0.date == today }) {
                entries[index] = DailyTokenUsage(
                    date: today,
                    promptTokens: entries[index].promptTokens + promptTokens,
                    completionTokens: entries[index].completionTokens + completionTokens)
            } else {
                entries.append(DailyTokenUsage(
                    date: today,
                    promptTokens: promptTokens,
                    completionTokens: completionTokens))
            }
            save(entries)
        }
        objectWillChange.send()
    }

    /// Remove every stored day. Used by the Settings "Clear history" button.
    func clear() {
        queue.sync {
            defaults.removeObject(forKey: key)
        }
        objectWillChange.send()
    }

    // MARK: - Reads

    /// The last 14 calendar days, oldest first, filling missing days with zeros
    /// so the chart always has a full 14-bar row even on quiet days.
    func last14Days() -> [DailyTokenUsage] {
        let entries = queue.sync { load() }
        let byDate = Dictionary(uniqueKeysWithValues: entries.map { ($0.date, $0) })
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var days: [DailyTokenUsage] = []
        for offset in stride(from: 13, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = string(from: day)
            if let entry = byDate[key] {
                days.append(entry)
            } else {
                days.append(DailyTokenUsage(date: key, promptTokens: 0, completionTokens: 0))
            }
        }
        return days
    }

    /// Sum of `totalTokens` across the last 14 calendar days (filled with zeros
    /// for missing days, so the headline figure matches the chart's bars).
    func totalForLast14Days() -> Int {
        last14Days().reduce(0) { $0 + $1.totalTokens }
    }

    // MARK: - Storage

    private func load() -> [DailyTokenUsage] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DailyTokenUsage].self, from: data)) ?? []
    }

    private func save(_ entries: [DailyTokenUsage]) {
        do {
            let data = try JSONEncoder().encode(entries)
            defaults.set(data, forKey: key)
        } catch { PersistenceStatus.record(error) }
    }

    private func todayString() -> String { string(from: Date()) }

    private func string(from date: Date) -> String { dateFormatter.string(from: date) }
}
