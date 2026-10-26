import Foundation
import SwiftUI

/// A saved Ask Claude prompt the user can re-run from the launcher's recipe chips.
/// Stored as a JSON array in UserDefaults so it survives relaunches with no file I/O.
struct Recipe: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var prompt: String
    var createdAt: Date = Date()
}

/// Persists the user's custom Ask Claude recipes in UserDefaults.
///
/// `RecipeStore` is the data layer for the recipe chips shown in `AILauncherView`.
/// It mirrors the `TemplateStore` shape (list / named / save / delete) but backs
/// itself with `UserDefaults` instead of the filesystem — recipes are small,
/// always-available, and don't deserve their own directory.
///
/// `objectWillChange` fires on every mutation so SwiftUI views that observe the
/// store refresh their chips without manual reloading.
final class RecipeStore: ObservableObject {
    private let defaults: UserDefaults
    private let key: String

    /// Convenience for app use: recipes live in `UserDefaults.standard` under
    /// the shared `SettingsKey.recipes` key.
    convenience init() {
        self.init(defaults: AppSettings.defaults, key: SettingsKey.recipes)
    }

    /// Testable initializer: pass an isolated `UserDefaults` suite and a unique
    /// key so tests never touch the user's real recipes.
    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    /// All recipes, sorted by name (case-insensitive, ascending).
    func all() -> [Recipe] {
        load().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Look up a recipe by name (case-insensitive). Returns the first match.
    func recipe(named name: String) -> Recipe? {
        all().first { $0.name.lowercased() == name.lowercased() }
    }

    /// Append a new recipe. The store fires `objectWillChange` and persists to
    /// UserDefaults. Returns the created recipe with its freshly assigned id.
    @discardableResult
    func add(name: String, prompt: String) -> Recipe {
        let recipe = Recipe(name: name, prompt: prompt)
        var recipes = load()
        recipes.append(recipe)
        save(recipes)
        return recipe
    }

    /// Replace an existing recipe by id. If no recipe with that id exists the
    /// update is a no-op (callers can detect this via a follow-up `recipe(named:)`).
    func update(_ recipe: Recipe) {
        var recipes = load()
        guard let index = recipes.firstIndex(where: { $0.id == recipe.id }) else { return }
        recipes[index] = recipe
        save(recipes)
    }

    /// Remove the recipe with the given id. No-op if it isn't present.
    func delete(id: UUID) {
        var recipes = load()
        recipes.removeAll { $0.id == id }
        save(recipes)
    }

    // MARK: - Storage

    private func load() -> [Recipe] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Recipe].self, from: data)) ?? []
    }

    private func save(_ recipes: [Recipe]) {
        objectWillChange.send()
        do {
            let data = try JSONEncoder().encode(recipes)
            defaults.set(data, forKey: key)
        } catch { PersistenceStatus.record(error) }
    }
}
