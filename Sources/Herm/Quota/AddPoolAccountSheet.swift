import SwiftUI

/// Adds another account to a Hermes credential pool by running
/// `hermes auth add <provider>`: an existing pool provider gains a second
/// account, a new provider id starts its own pool.
struct AddPoolAccountSheet: View {
    @ObservedObject var control: ControlCenterModel
    var initialProvider = ""
    var onAdded: (() -> Void)?
    @StateObject private var login = ProviderLoginModel()
    @State private var provider = ""
    @State private var label = ""
    @State private var apiKey = ""
    @State private var useAPIKey = false
    @State private var showsLogin = false
    @Environment(\.dismiss) private var dismiss

    private static let commonProviders = ["openai-codex", "anthropic", "nous", "openrouter", "xai-oauth", "deepseek"]

    /// Providers `hermes auth add` can sign in through a browser. Every other
    /// provider only takes an API key, and without `--api-key` Hermes would
    /// wait on a hidden `Paste your API key:` prompt.
    nonisolated static let browserSignInProviders: Set<String> = [
        "openai-codex", "anthropic", "nous", "xai-oauth", "qwen-oauth", "minimax-oauth", "openrouter",
    ]

    private var providerID: String { provider.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var keyOnly: Bool { !providerID.isEmpty && !Self.browserSignInProviders.contains(providerID) }
    private var usesKey: Bool { keyOnly || useAPIKey }

    private var suggestions: [String] {
        let pooled = control.providerQuotas.compactMap { $0.hermesCredential?.provider }
        return (pooled + Self.commonProviders).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private var command: String? {
        Self.command(provider: provider, label: label, apiKey: usesKey ? apiKey : nil)
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
        } else {
            guard browserSignInProviders.contains(id) else { return nil }
            // OpenRouter defaults to an API key; its browser login must be asked for.
            if id == "openrouter" { words += ["--type", "oauth"] }
        }
        return words.joined(separator: " ")
    }

    private var accountAdded: Bool { login.exitStatus == 0 && !login.isRunning }

    var body: some View {
        DockModal(
            title: accountAdded ? "Account added" : "Add pool account",
            subtitle: "Connect another account to a Hermes provider pool."
        ) {
            Group {
                if showsLogin {
                    ProviderSignInFlow(
                        login: login,
                        providerName: providerID,
                        mark: ProviderMark(hermesProvider: providerID),
                        accountLabel: label.trimmingCharacters(in: .whitespacesAndNewlines),
                        usesBrowser: !usesKey,
                        onRetry: usesKey ? { showsLogin = false } : { start() }
                    )
                } else {
                    ScrollView { accountForm }
                }
            }
            .frame(height: 360, alignment: .topLeading)
        } footer: {
            if showsLogin && !login.isRunning && !accountAdded {
                Button("Back") { showsLogin = false }
                    .buttonStyle(.dockSecondary)
            }
            Spacer()
            if login.isRunning {
                Button("Cancel Sign-In") { login.cancel() }
                    .buttonStyle(.dockSecondary)
            } else if accountAdded && showsLogin {
                Button("Add Another") {
                    label = ""
                    showsLogin = false
                }
                .buttonStyle(.dockSecondary)
                Button("Done") { dismiss() }
                    .buttonStyle(.dockPrimary)
                    .keyboardShortcut(.defaultAction)
            } else if !showsLogin {
                Button(usesKey ? "Add Account" : "Sign In") { start() }
                    .buttonStyle(.dockPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(command == nil)
            }
        }
        .onAppear { if provider.isEmpty { provider = initialProvider } }
        .onChange(of: login.exitStatus) {
            apiKey = ""
            if login.exitStatus == 0 {
                control.refreshProviderQuota()
                onAdded?()
            }
        }
        .onDisappear { login.cancel() }
    }

    private func start() {
        guard let command else { return }
        showsLogin = true
        login.start(command: command)
    }

    private var accountForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            labeledField("Provider", hint: "Hermes provider id") {
                DockTextField("openai-codex", text: $provider)
                    .textFieldStyle(.dockGlass)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 6)], spacing: 6) {
                    ForEach(suggestions, id: \.self) { id in
                        Button {
                            provider = id
                        } label: {
                            HStack(spacing: 6) {
                                ProviderMarkBadge(mark: ProviderMark(hermesProvider: id), size: 16)
                                Text(id).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.dockSecondary)
                        .controlSize(.small)
                        .help(id)
                        .overlay {
                            DockThemeShape(cornerRadius: DockLayout.controlRadius)
                                .stroke(providerID == id ? Color.dockAccent : .clear, lineWidth: DockLayout.hairline)
                        }
                        .accessibilityAddTraits(providerID == id ? .isSelected : [])
                    }
                }
            }
            labeledField("Label", hint: "Optional") {
                DockTextField("work", text: $label)
                    .textFieldStyle(.dockGlass)
            }
            if keyOnly {
                ModalNote(text: "\(providerID) signs in with an API key.", icon: .key)
            } else if !providerID.isEmpty {
                Toggle("Use an API key instead of browser sign-in", isOn: $useAPIKey)
                    .toggleStyle(.dockCheckbox)
                    .dockFont(.body)
            }
            if usesKey {
                labeledField("API key") {
                    SecureField("Paste the API key", text: $apiKey)
                        .textFieldStyle(.dockGlass)
                        .onSubmit { start() }
                }
                // shortcut: key rides on argv until Hermes supports non-TTY key input.
                ModalNote(text: "Stored by Hermes in its credential pool, not by Herm.", icon: .lockSimple)
            }
        }
    }
}
