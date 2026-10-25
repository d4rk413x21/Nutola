import AppKit
import Foundation
import SwiftUI

/// Ring buffer of diagnostics shown in Settings → Debug (when Developer mode is on).
@MainActor
final class AIDebugLog: ObservableObject {
    static let shared = AIDebugLog()

    @Published private(set) var lines: [String] = []

    private static let maxLines = 1000
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var allText: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n")
    }

    func append(_ message: String) {
        let stamp = Self.formatter.string(from: Date())
        lines.append("[\(stamp)] \(message)")
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }

    func clear() {
        lines.removeAll()
    }

    /// Safe to call from any thread. No-op unless Developer mode is enabled.
    nonisolated static func log(_ message: String) {
        guard AppSettings.developerMode else { return }
        Task { @MainActor in
            shared.append(message)
        }
    }
}

struct AIDebugLogPanel: View {
    @ObservedObject private var log = AIDebugLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Debug logs").font(.nutola(12, .medium))
                Spacer()
                Button("Clear") { log.clear() }
                    .buttonStyle(.plain)
                    .font(.nutola(11))
                    .foregroundStyle(Theme.blueberry)
                    .disabled(log.allText.isEmpty)
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.allText, forType: .string)
                }
                .buttonStyle(.plain)
                .font(.nutola(11))
                .foregroundStyle(Theme.blueberry)
                .disabled(log.allText.isEmpty)
            }
            ScrollView {
                Text(log.allText.isEmpty
                     ? "Activity from recording, Zoom speaker tracking, transcription, and AI appears here. Filter Console.app with subsystem io.github.d4rk413x21.Nutola."
                     : log.allText)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }
}

struct AIDebugLogButton: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Debug logs", systemImage: "ladybug")
        }
        .buttonStyle(.plain)
        .font(.nutola(12))
        .foregroundStyle(Theme.blueberry)
        .help("Debug logs")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            AIDebugLogPanel()
                .frame(width: 420, height: 240)
        }
    }
}
