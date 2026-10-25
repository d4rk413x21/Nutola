import Foundation

/// File-backed folder storage:
///
///     <root>/Folders/
///         folders.json      [MeetingFolder]
///         title-rules.json  [FolderTitleRule]
final class FolderArchive: @unchecked Sendable {
    let root: URL

    private let queue = DispatchQueue(label: "io.github.d4rk413x21.Nutola.folders")
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(FolderArchive.dateFormatter.string(from: date))
        }
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = FolderArchive.dateFormatter.date(from: s)
                ?? ISO8601DateFormatter().date(from: s)
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: dec.codingPath, debugDescription: "Bad date: \(s)"))
            }
            return date
        }
        return d
    }()

    init(root: URL = MeetingArchive.defaultRoot) {
        self.root = root
        try? FileManager.default.createDirectory(at: foldersDir, withIntermediateDirectories: true)
    }

    var foldersDir: URL { root.appendingPathComponent("Folders", isDirectory: true) }
    private var foldersFile: URL { foldersDir.appendingPathComponent("folders.json") }
    private var rulesFile: URL { foldersDir.appendingPathComponent("title-rules.json") }

    // MARK: - Folders

    func allFolders() -> [MeetingFolder] {
        queue.sync {
            guard let data = try? Data(contentsOf: foldersFile) else { return [] }
            let folders = (try? decoder.decode([MeetingFolder].self, from: data)) ?? []
            return folders.sorted { $0.sortOrder < $1.sortOrder }
        }
    }

    func save(_ folder: MeetingFolder) throws {
        try queue.sync {
            var folders = loadFolders()
            if let i = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[i] = folder
            } else {
                folders.append(folder)
            }
            try writeFolders(folders)
        }
    }

    func deleteFolder(id: UUID) throws {
        try queue.sync {
            var folders = loadFolders()
            folders.removeAll { $0.id == id }
            try writeFolders(folders)
            var rules = loadRules()
            rules.removeAll { $0.folderID == id }
            try writeRules(rules)
        }
    }

    // MARK: - Title rules

    func allTitleRules() -> [FolderTitleRule] {
        queue.sync {
            loadRules()
        }
    }

    func rule(forTitle title: String) -> FolderTitleRule? {
        let key = FolderTitleNormalizer.key(for: title)
        return queue.sync {
            loadRules().first { $0.normalizedTitle == key }
        }
    }

    func setRule(normalizedTitle: String, folderID: UUID) throws {
        try queue.sync {
            var rules = loadRules()
            let rule = FolderTitleRule(
                normalizedTitle: normalizedTitle,
                folderID: folderID,
                updatedAt: Date())
            if let i = rules.firstIndex(where: { $0.normalizedTitle == normalizedTitle }) {
                rules[i] = rule
            } else {
                rules.append(rule)
            }
            try writeRules(rules)
        }
    }

    func removeRules(forFolderID folderID: UUID) throws {
        try queue.sync {
            var rules = loadRules()
            rules.removeAll { $0.folderID == folderID }
            try writeRules(rules)
        }
    }

    // MARK: - Private

    private func loadFolders() -> [MeetingFolder] {
        guard let data = try? Data(contentsOf: foldersFile) else { return [] }
        return (try? decoder.decode([MeetingFolder].self, from: data)) ?? []
    }

    private func writeFolders(_ folders: [MeetingFolder]) throws {
        let data = try encoder.encode(folders)
        try data.write(to: foldersFile, options: .atomic)
    }

    private func loadRules() -> [FolderTitleRule] {
        guard let data = try? Data(contentsOf: rulesFile) else { return [] }
        return (try? decoder.decode([FolderTitleRule].self, from: data)) ?? []
    }

    private func writeRules(_ rules: [FolderTitleRule]) throws {
        let data = try encoder.encode(rules)
        try data.write(to: rulesFile, options: .atomic)
    }
}
