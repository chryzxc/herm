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
    @State private var showsLogin = false
    @State private var showsOutput = false
    @Environment(\.dismiss) private var dismiss

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

    private var accountAdded: Bool { login.exitStatus == 0 && !login.isRunning }

    var body: some View {
        DockModal(
            icon: .plus,
            title: "Add pool account",
            subtitle: "Connect another account to a Hermes provider pool."
        ) {
            Group {
                if showsLogin {
                    loginContent
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
                Button("Done") { dismiss() }
                    .buttonStyle(.dockPrimary)
                    .keyboardShortcut(.defaultAction)
            } else if !showsLogin {
                Button("Add Account") {
                    if let command {
                        callbackCode = ""
                        showsOutput = false
                        showsLogin = true
                        login.start(command: command)
                    }
                }
                .buttonStyle(.dockPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(command == nil)
            }
        }
        .onChange(of: login.exitStatus) {
            apiKey = ""
            if login.exitStatus == 0 { control.refreshProviderQuota() }
        }
        .onDisappear { login.cancel() }
    }

    private var accountForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            labeledField("Provider", hint: "Hermes provider id") {
                DockTextField("openai-codex", text: $provider)
                    .textFieldStyle(.dockGlass)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 6)], spacing: 6) {
                    ForEach(suggestions, id: \.self) { id in
                        Button { provider = id } label: {
                            Text(id)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.dockSecondary)
                        .controlSize(.small)
                        .help(id)
                        .overlay {
                            DockThemeShape(cornerRadius: DockLayout.controlRadius)
                                .stroke(provider == id ? Color.dockAccent : .clear, lineWidth: DockLayout.hairline)
                        }
                        .accessibilityAddTraits(provider == id ? .isSelected : [])
                    }
                }
            }
            labeledField("Label", hint: "Optional") {
                DockTextField("work", text: $label)
                    .textFieldStyle(.dockGlass)
            }
            Toggle("Use an API key instead of browser sign-in", isOn: $useAPIKey)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            if useAPIKey {
                labeledField("API key") {
                    SecureField("Paste the API key", text: $apiKey)
                        .textFieldStyle(.dockGlass)
                }
                // shortcut: key rides on argv until Hermes supports non-TTY key input.
                ModalNote(text: "Stored by Hermes, not by Herm.", icon: .lockSimple)
            }
        }
    }

    private var loginContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProviderMarkBadge(mark: ProviderMark(hermesProvider: provider), size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(label)
                            .lineLimit(1)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                }
                Spacer()
            }
            if accountAdded {
                ModalNote(text: "Account added. Quota refresh requested.", icon: .checkCircle, tone: .dockSuccess)
                if !login.outputLines.isEmpty {
                    DisclosureGroup("Sign-in details", isExpanded: $showsOutput) { loginOutput }
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockSecondaryText)
                }
            } else {
                if login.isRunning {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(useAPIKey ? "Adding account…" : "Complete sign-in using the instructions below.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                } else if let failure = login.failureText {
                    ModalNote(text: failure, icon: .warning, tone: .dockWarning)
                } else if let status = login.exitStatus {
                    ModalNote(text: "Account was not added (exit status \(status)). Review the details or go back to try again.", icon: .warning, tone: .dockWarning)
                }
                if !login.outputLines.isEmpty { loginOutput }
                if login.isRunning && !useAPIKey {
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
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loginOutput: some View {
        ScrollView {
            Text(login.outputLines.joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.dockSecondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: 180, alignment: .topLeading)
    }

    private func submitCode() {
        let trimmed = callbackCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        login.sendInput(trimmed)
        callbackCode = ""
    }
}
