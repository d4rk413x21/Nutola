import SwiftUI

struct LinearSettings: View {
    @State private var apiKey = ""
    @State private var configured = false
    @State private var busy = false
    @State private var status: String?
    @State private var error: String?

    var body: some View {
        Form {
            Section("Linear") {
                Text(configured ? "An API key is saved in the macOS Keychain." : "Connect Linear to create issues from reviewed meeting tasks.")
                SecureField("Personal API key", text: $apiKey)
                    .disabled(busy)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Linear personal API key")
                HStack {
                    Button(configured ? "Replace API key" : "Connect") { connect() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    if configured {
                        Button("Disconnect", role: .destructive) {
                            do {
                                try LinearCredentials.remove()
                                configured = false
                                apiKey = ""
                                status = "Disconnected. Existing Linear issues and saved links are retained."
                                error = nil
                            } catch { self.error = error.localizedDescription }
                        }
                        .disabled(busy)
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                Link("Create a personal API key in Linear", destination: URL(string: "https://linear.app/settings/account/security")!)
                Text("The key needs read access to teams, projects and issues, and permission to create issues. It stays in your macOS Keychain and is sent only to Linear.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("In a meeting, open Development tasks, review the drafts, choose a team and optional project, then create the selected issues. Only selected descriptions and their quoted transcript passages are sent to Linear.")
                    .font(.callout).foregroundStyle(.secondary)
                if let status { Text(status).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            do { configured = try LinearCredentials.load() != nil }
            catch { self.error = error.localizedDescription }
        }
    }

    private func connect() {
        let key = apiKey
        busy = true
        status = nil
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let result = try await LinearClient(apiKey: key).teams()
                try LinearCredentials.save(key)
                apiKey = ""
                configured = true
                status = "Connected to \(result.workspace.name)."
            } catch { self.error = error.localizedDescription }
        }
    }
}
