import SwiftUI

/// Adds another account to a Hermes credential pool by running
/// `hermes auth add <provider>`: an existing pool provider gains a second
/// account, a new provider id starts its own pool.
struct AddPoolAccountSheet: View {
    @ObservedObject var control: ControlCenterModel
    @StateObject private var login = ProviderLoginModel()
    @State private var provider = ""
    @State private var label = ""
    @State private var apiKey = ""
    @State private var useAPIKey = false
    @State private var callbackCode = ""

    private static let commonProviders = ["openai-codex", "anthropic", "openrouter", "nous", "deepseek"]

    private var suggestions: [String] {
        let pooled = control.providerQuotas.compactMap { $0.hermesCredential?.provider }
        return (pooled + Self.commonProviders).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private var command: String? {
        Self.command(provider: provider, label: label, apiKey: useAPIKey ? apiKey : nil)
    }

    /// Hermes ids and labels are single words; whitespace would split the argv.
    nonisolated static func command(provider: String, label: String, apiKey: String?) -> String? {
        let id = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.contains(where: \.isWhitespace) else { return nil }
        var words = ["hermes", "auth", "add", id]
        let name = label.split(whereSeparator: \.isWhitespace).joined(separator: "-")
        if !name.isEmpty { words += ["--label", name] }
        if let apiKey {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
            words += ["--type", "api-key", "--api-key", key]
        }
        return words.joined(separator: " ")
    }

    var body: some View {
        DockModal(
            icon: .plus,
            title: "Add pool account",
            subtitle: "Adds an account to a Hermes credential pool, for an existing or new provider."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                labeledField("Provider", hint: "Hermes provider id") {
                    DockTextField("openai-codex", text: $provider)
                        .textFieldStyle(.dockGlass)
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { id in
                            Button(id) { provider = id }
                                .buttonStyle(.dockSecondary)
                        }
                    }
                }
                labeledField("Label", hint: "Optional") {
                    DockTextField("work", text: $label)
                        .textFieldStyle(.dockGlass)
                }
                Toggle("Use an API key instead of browser sign-in", isOn: $useAPIKey)
                    .toggleStyle(.checkbox)
                    .disabled(login.isRunning)
                if useAPIKey {
                    labeledField("API key") {
                        SecureField("Paste the API key", text: $apiKey)
                            .textFieldStyle(.dockGlass)
                    }
                    // ponytail: key rides on argv (Hermes only prompts on a tty); visible to local `ps` while it runs.
                    ModalNote(text: "Passed to `hermes auth add` and stored by Hermes, not by Herm.", icon: .lockSimple)
                }
                if login.isRunning {
                    labeledField("Authorization code", hint: "Only if Hermes asks for one") {
                        HStack(spacing: 8) {
                            DockTextField("Paste the code", text: $callbackCode)
                                .textFieldStyle(.dockGlass)
                                .onSubmit { submitCode() }
                            Button("Submit") { submitCode() }
                                .buttonStyle(.dockSecondary)
                                .disabled(callbackCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for Hermes…")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                }
                if let status = login.exitStatus, !login.isRunning {
                    ModalNote(
                        text: status == 0 ? "Account added. Quota was refreshed." : "Hermes exited with status \(status). Check the output below.",
                        icon: status == 0 ? .checkCircle : .warning,
                        tone: status == 0 ? .dockSuccess : .dockWarning
                    )
                }
                if let failure = login.failureText {
                    ModalNote(text: failure, icon: .warning, tone: .dockWarning)
                }
                if !login.outputLines.isEmpty {
                    ScrollView {
                        Text(login.outputLines.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.dockMetadataText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxHeight: 160)
                }
            }
        } footer: {
            Spacer()
            if login.isRunning {
                Button("Cancel") { login.cancel() }
                    .buttonStyle(.dockSecondary)
            } else {
                Button("Add Account") {
                    if let command { login.start(command: command) }
                }
                .buttonStyle(.dockPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(command == nil)
            }
        }
        .onChange(of: login.exitStatus) {
            apiKey = ""
            control.refreshProviderQuota()
        }
    }

    private func submitCode() {
        let trimmed = callbackCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        login.sendInput(trimmed)
        callbackCode = ""
    }
}
