import Foundation
import SwiftUI
import Synchronization

/// Retains the newest failed write per file until it succeeds or the user quits explicitly.
enum FilePersistence {
    struct Failure: Sendable {
        let data: Data
        let message: String
    }
    private static let pending = Mutex<[URL: Failure]>([:])

    static var failures: [URL: Failure] { pending.withLock { $0 } }

    private static func key(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: false)
    }

    static func failure(at url: URL) -> Failure? { pending.withLock { $0[key(url)] } }

    static func read(_ url: URL) throws -> Data {
        if let failure = failure(at: url) { return failure.data }
        return try Data(contentsOf: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        let url = key(url)
        var changed = false
        defer { if changed { Task { @MainActor in PersistenceStatus.shared.refresh() } } }
        try pending.withLock { files in
            do {
                try data.write(to: url, options: .atomic)
                changed = files[url] != nil
                files[url] = nil
            } catch {
                changed = true
                files[url] = Failure(data: data, message: error.localizedDescription)
                throw error
            }
        }
    }

    static func retryAll() {
        pending.withLock { files in
            for (url, failure) in files {
                do {
                    try failure.data.write(to: url, options: .atomic)
                    files[url] = nil
                } catch {
                    files[url] = Failure(data: failure.data, message: error.localizedDescription)
                }
            }
        }
        Task { @MainActor in PersistenceStatus.shared.refresh() }
    }

    static func discard(in directory: URL) {
        pending.withLock { files in
            files = files.filter { !$0.key.path.hasPrefix(directory.path + "/") }
        }
        Task { @MainActor in PersistenceStatus.shared.refresh() }
    }

    static func discard(_ url: URL) {
        pending.withLock { $0[key(url)] = nil }
        Task { @MainActor in PersistenceStatus.shared.refresh() }
    }
}

@MainActor
final class PersistenceStatus: ObservableObject {
    static let shared = PersistenceStatus()
    @Published private(set) var failures: [URL: FilePersistence.Failure] = [:]
    @Published var operationError: String?

    nonisolated static func record(_ error: Error) {
        // Failed file writes already publish their current state, including later recovery.
        guard !FilePersistence.failures.values.contains(where: { $0.message == error.localizedDescription }) else { return }
        Task { @MainActor in shared.report(error) }
    }

    func refresh() { failures = FilePersistence.failures }

    func report(_ error: Error) {
        refresh()
        if !failures.values.contains(where: { $0.message == error.localizedDescription }) {
            operationError = error.localizedDescription
        }
    }
}

struct PersistenceWarning: ViewModifier {
    @ObservedObject private var status = PersistenceStatus.shared
    @State private var showDetails = false
    @EnvironmentObject private var app: AppState

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            if !status.failures.isEmpty || status.operationError != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Label(status.failures.isEmpty ? "File operation failed" : "Changes could not be saved",
                          systemImage: "exclamationmark.triangle.fill")
                    Text(status.failures.isEmpty
                         ? "The operation did not finish. See Details, fix the problem and try the action again."
                         : "Keep Nutola open. Unsaved file contents are held in memory. Free disk space or fix folder access, then retry.")
                        .font(.caption)
                    HStack {
                        Button("Retry saving") {
                            let pending = Set(FilePersistence.failures.keys)
                            FilePersistence.retryAll()
                            status.refresh()
                            if status.failures.isEmpty { status.operationError = nil }
                            app.store.reload()
                            app.folders.reload()
                            for url in pending where FilePersistence.failures[url] == nil && url.lastPathComponent == "summary.md" {
                                if let id = UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) {
                                    app.store.onSummarySaved?(id, app.store.summary(for: id))
                                }
                            }
                        }
                        .disabled(status.failures.isEmpty)
                        Button("Details") { showDetails = true }
                        if status.operationError != nil {
                            Button("Dismiss error") { status.operationError = nil }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
                .accessibilityElement(children: .contain)
            }
        }
        .alert("File operation failed", isPresented: $showDetails) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(([status.operationError].compactMap { $0 } + status.failures
                .sorted { $0.key.path < $1.key.path }
                .map { "\($0.key.path): \($0.value.message)" }).joined(separator: "\n\n"))
        }
    }
}

extension Notification.Name {
    static let nutolaFlushEdits = Notification.Name("nutolaFlushEdits")
}
