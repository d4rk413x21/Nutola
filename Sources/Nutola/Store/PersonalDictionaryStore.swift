import Foundation

/// A user-managed vocabulary of custom words, phrase matches, and replacement
/// pairs applied to transcript text before summarization. Jaro-Winkler fuzzy
/// matching auto-corrects near-misses from the recognizer.
///
/// Stored as a JSON array in UserDefaults (small, always-available, no file I/O
/// needed) — mirrors `RecipeStore`'s shape.
final class PersonalDictionaryStore: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable, Sendable {
        var id: UUID = UUID()
        /// The canonical form the recognizer should have produced.
        var word: String
        /// Optional longer phrase to match (wins over `word` when present).
        var phraseMatch: String?
        /// What to replace the match with. nil = keep `word` (just add it to the
        /// recognizer's vocabulary — no substitution). Non-nil = replace the
        /// matched token with this string.
        var replacement: String?
        /// Minimum Jaro-Winkler similarity (0…1) for a fuzzy match. 1.0 = exact
        /// only. Default 0.92 — close enough to catch "Nutola"/"Nutoa" but not
        /// so loose it rewrites unrelated words.
        var minSimilarity: Double = 0.92
    }

    @Published private(set) var entries: [Entry]

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard,
         key: String = SettingsKey.personalDictionary) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
    }

    func add(_ entry: Entry) {
        entries.append(entry)
        persist()
        objectWillChange.send()
    }

    func update(_ entry: Entry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        persist()
        objectWillChange.send()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
        objectWillChange.send()
    }

    var hasAny: Bool { !entries.isEmpty }

    // MARK: - Apply

    /// Apply the dictionary to `text`. For each entry:
    ///   - If `phraseMatch` is set, replace exact (case-insensitive) occurrences.
    ///   - Else if `replacement` is set, fuzzy-match `word` and replace.
    ///   - Else (word-only entry) no-op — reserved for future recognizer-vocab hint.
    /// Pure `String → String`; unit-testable.
    func apply(to text: String) -> String {
        guard hasAny, !text.isEmpty else { return text }
        var result = text
        for entry in entries {
            result = Self.apply(entry, to: result)
        }
        return result
    }

    private static func apply(_ entry: Entry, to text: String) -> String {
        // Phrase matches are exact (case-insensitive) substitutions.
        if let phrase = entry.phraseMatch?.trimmingCharacters(in: .whitespacesAndNewlines),
           !phrase.isEmpty {
            let replacement = entry.replacement ?? entry.word
            return text.replacingOccurrences(
                of: phrase,
                with: replacement,
                options: [.caseInsensitive, .literal])
        }
        // Word matches use Jaro-Winkler fuzzy replacement only when a
        // replacement is defined. Word-only entries (no replacement) are
        // vocabulary hints — we leave the text alone for now.
        guard let replacement = entry.replacement else { return text }
        let target = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return text }
        return Self.fuzzyReplace(
            target: target,
            with: replacement,
            minSimilarity: entry.minSimilarity,
            in: text)
    }

    /// Token-by-token fuzzy replace. Splits on whitespace + punctuation, keeps
    /// boundaries, and only swaps whole tokens whose Jaro-Winkler similarity to
    /// `target` meets `minSimilarity`.
    private static func fuzzyReplace(
        target: String,
        with replacement: String,
        minSimilarity: Double,
        in text: String
    ) -> String {
        let lowerTarget = target.lowercased()
        // Match word tokens including letters/numbers; keep everything else as a
        // boundary we copy verbatim.
        let pattern = "[\\p{L}\\p{N}]+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length))
        // Walk matches in reverse so ranges stay valid as we mutate.
        var result = text
        for match in matches.reversed() {
            let token = nsText.substring(with: match.range)
            if JaroWinkler.similarity(token.lowercased(), lowerTarget) >= minSimilarity {
                let start = result.index(result.startIndex, offsetBy: match.range.location)
                let end = result.index(start, offsetBy: match.range.length)
                result.replaceSubrange(start..<end, with: replacement)
            }
        }
        return result
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(entries)
            defaults.set(data, forKey: key)
        } catch { PersistenceStatus.record(error) }
    }
}
