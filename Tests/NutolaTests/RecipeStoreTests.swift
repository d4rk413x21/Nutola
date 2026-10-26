import Foundation
import Testing
@testable import Nutola

final class RecipeStoreTests {
    /// Each test gets a private UserDefaults suite so nothing leaks across tests
    /// or into the user's real recipe library.
    private let suiteName = "NutolaTests.RecipeStore.\(UUID().uuidString)"
    private let key = "recipes"

    private func makeStore() -> RecipeStore {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.setPersistentDomain([:], forName: suiteName)
        return RecipeStore(defaults: defaults, key: key)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    @Test func testEmptyStore() {
        let store = makeStore()
        #expect(store.all().isEmpty)
        #expect(store.recipe(named: "Anything") == nil)
    }

    @Test func testAddRecipe() {
        let store = makeStore()
        let recipe = store.add(name: "Weekly recap", prompt: "Summarize my week")

        #expect(store.all().count == 1)
        #expect(recipe.name == "Weekly recap")
        #expect(recipe.prompt == "Summarize my week")
        #expect(store.all().first == recipe)

        // A fresh store backed by the *same* suite should see the recipe —
        // it has to survive across instances (UserDefaults persistence).
        let defaults = UserDefaults(suiteName: suiteName)!
        let reloaded = RecipeStore(defaults: defaults, key: key)
        #expect(reloaded.all() == [recipe])
    }

    @Test func testDeleteRecipe() {
        let store = makeStore()
        let recipe = store.add(name: "Action items", prompt: "List action items")
        #expect(store.all().count == 1)

        store.delete(id: recipe.id)
        #expect(store.all().isEmpty)
    }

    @Test func testUpdateRecipe() {
        let store = makeStore()
        let original = store.add(name: "Follow-up", prompt: "Draft a follow-up")

        var updated = original
        updated.name = "Follow-up email"
        updated.prompt = "Draft a polite follow-up email"
        store.update(updated)

        let recipes = store.all()
        #expect(recipes.count == 1)
        #expect(recipes.first?.name == "Follow-up email")
        #expect(recipes.first?.prompt == "Draft a polite follow-up email")
        #expect(recipes.first?.id == original.id)
    }

    @Test func testRecipeNamed() {
        let store = makeStore()
        _ = store.add(name: "Decisions", prompt: "What decisions came out?")

        // Case-insensitive lookup matches the TemplateStore convention.
        #expect(store.recipe(named: "Decisions")?.name == "Decisions")
        #expect(store.recipe(named: "decisions")?.name == "Decisions")
        #expect(store.recipe(named: "DECISIONS")?.name == "Decisions")
        #expect(store.recipe(named: "Missing") == nil)
    }

    @Test func testAllSortedByName() {
        let store = makeStore()
        _ = store.add(name: "Zebra", prompt: "z")
        _ = store.add(name: "alpha", prompt: "a")
        _ = store.add(name: "Mango", prompt: "m")

        let names = store.all().map(\.name)
        #expect(names == ["alpha", "Mango", "Zebra"])
    }
}
