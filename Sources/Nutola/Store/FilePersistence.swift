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

    static func read(_ url: URL) throws -> Data {
        if let failure = pending.withLock({ $0[url] }) { return failure.data }
        return try Data(contentsOf: url)
    }

    static func write(_ data: Data, to url: URL) throws {
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
        pending.withLock { $0[url] = nil }
        Task { @MainActor in PersistenceStatus.shared.refresh() }
    }
}

@MainActor
final class PersistenceStatus: ObservableObject {
    static let shared = PersistenceStatus()
    @Published private(set) var failures: [URL: FilePersistence.Failure] = [:]
    @Published var operationError: String?

    nonisolated static func record(_ error: Error) {
        Task { @MainActor in shared.report(error) }
    }

    func refresh() { failures = FilePersistence.failures }

    func report(_ error: Error) {
        operationError = error.localizedDescription
        refresh()
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
                    Label("Changes could not be saved", systemImage: "exclamationmark.triangle.fill")
                    Text("Keep Nutola open. Unsaved file contents are held in memory until you retry.")
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
