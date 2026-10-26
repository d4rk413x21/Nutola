import Foundation

/// Owned by each recorder under its existing capture lock/queue.
struct AudioWriteFailure: Sendable {
    private(set) var message: String?

    mutating func record(_ error: Error, source: String) {
        guard message == nil else { return }
        let text = "\(source) audio could not be saved. Some audio may be missing. \(error.localizedDescription)"
        message = text
        let error = NSError(domain: "Nutola.AudioWrite", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: text])
        Task { @MainActor in PersistenceStatus.shared.report(error) }
    }
}
