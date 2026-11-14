import AppKit
import SwiftUI

/// Runs a provider CLI's interactive login command as a bounded child process
/// and streams its output for the connect sheet. The command is looked up in
/// the shell PATH plus the standard Homebrew, ~/.local/bin, Volta, and nvm
/// locations so it works from a GUI-launched Dock.
@MainActor
final class ProviderLoginModel: ObservableObject {
    @Published private(set) var outputLines: [String] = []
    @Published private(set) var isRunning = false
    @Published private(set) var exitStatus: Int32?
    @Published private(set) var failureText: String?
    /// Output after the last newline: a stdin prompt such as `Authorization code: `.
    @Published private(set) var partialLine = ""
    var onFinished: (() -> Void)?

    private var process: Process?
    private var inputPipe: Pipe?

    func start(command: String) {
        guard !isRunning else { return }
        outputLines = []
        exitStatus = nil
        failureText = nil
        partialLine = ""

        let arguments = command.split(separator: " ").map(String.init)
        let searchDirectories = Self.defaultSearchDirectories()
        guard let executablePath = Self.executablePath(command: command, searchDirectories: searchDirectories) else {
            failureText =
                "The \(arguments.first ?? "provider") command was not found on this Mac. Install it and try again."
            return
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: executablePath)
        child.arguments = Array(arguments.dropFirst())
        child.environment = Self.childEnvironment(searchDirectories: searchDirectories)
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        let stdin = Pipe()
        child.standardInput = stdin

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(data: chunk, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                self?.accumulate(text)
            }
        }
        child.terminationHandler = { terminated in
            Task { @MainActor [weak self] in
                self?.finish(terminationStatus: terminated.terminationStatus)
            }
        }

        do {
            try child.run()
        } catch {
            failureText = "The sign-in command could not be started: \(error.localizedDescription)"
            pipe.fileHandleForReading.readabilityHandler = nil
            return
        }
        process = child
        inputPipe = stdin
        isRunning = true
    }

    /// Sends a line of text (such as an OAuth callback code) to the running
    /// process's stdin, followed by a newline, as if the user typed it into a
    /// terminal.
    func sendInput(_ text: String) {
        guard isRunning, let handle = inputPipe?.fileHandleForWriting else { return }
        let line = text.hasSuffix("\n") ? text : text + "\n"
        guard let data = line.data(using: .utf8) else { return }
        handle.write(data)
        // The prompt is answered; keep it in the log without the reply.
        if !partialLine.isEmpty {
            outputLines = Self.cappedLines(outputLines, newLines: [partialLine])
            partialLine = ""
        }
    }

    func cancel() {
        process?.terminate()
    }

    private func accumulate(_ text: String) {
        let combined = partialLine + text
        var lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        partialLine = HermesRuntimeInspector.stripANSI(lines.removeLast())
        if !lines.isEmpty { outputLines = Self.cappedLines(outputLines, newLines: lines) }
    }

    private func finish(terminationStatus: Int32) {
        guard isRunning else { return }
        isRunning = false
        exitStatus = terminationStatus
        inputPipe = nil
        if !partialLine.isEmpty {
            outputLines = Self.cappedLines(outputLines, newLines: [partialLine])
            partialLine = ""
        }
        onFinished?()
    }

    // MARK: - Pure helpers

    static func cappedLines(
        _ existing: [String], newLines: [String], lineLimit: Int = 400, characterLimit: Int = 16_000
    ) -> [String] {
        var lines = existing + newLines.map(HermesRuntimeInspector.stripANSI)
        while lines.count > lineLimit { lines.removeFirst(lines.count - lineLimit) }
        while lines.joined(separator: "\n").count > characterLimit && lines.count > 1 { lines.removeFirst(1) }
        return lines
    }

    static func executablePath(
        command: String, searchDirectories: [String],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let name = command.split(separator: " ").first.map(String.init) ?? command
        guard !name.isEmpty else { return nil }
        if name.contains("/") {
            return fileExists(name) ? name : nil
        }
        for directory in searchDirectories where !directory.isEmpty {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fileExists(candidate) { return candidate }
        }
        return nil
    }

    static func defaultSearchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        nodeVersionDirectoriesAt nodeDirectory: String? = nil
    ) -> [String] {
        var directories = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for fixed in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] where !directories.contains(fixed) {
            directories.append(fixed)
        }
        directories += [
            "\(homePath)/.local/bin",
            "\(homePath)/bin",
            "\(homePath)/.volta/bin",
        ]
        let nvmVersions = nodeDirectory ?? "\(homePath)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmVersions) {
            directories += versions.map { "\(nvmVersions)/\($0)/bin" }
        }
        return directories
    }

    static func childEnvironment(searchDirectories: [String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchDirectories.joined(separator: ":") + ":" + (environment["PATH"] ?? "")
        // A pipe makes Python block-buffer stdout, which would hold back the
        // sign-in URL and code until the command exits.
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }
}

/// Per-provider connect flow for the Quota surface: paste an API key, run the
/// provider CLI's login command, or open the provider's app.
struct ProviderConnectSheet: View {
    let descriptor: QuotaProviderDescriptor
    @ObservedObject var control: ControlCenterModel
    @StateObject private var login = ProviderLoginModel()
    @State private var apiKeyInput = ""
    @State private var hasStoredKey = false
    @State private var testStartedAt: Date?
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var remoteKeySaved = false
    @State private var showsRemoteLogin = false
    @State private var quotaCheckedAt: [String: Date] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DockModal(
            badge: AnyView(
                ProviderMarkBadge(
                    mark: ProviderMark(providerID: descriptor.id, displayName: descriptor.displayName), size: 32)),
            title: "Connect \(descriptor.displayName)",
            subtitle: descriptor.summary
        ) {
            switch descriptor.connect {
            case .apiKey(let instruction, _): apiKeySection(instruction)
            case .login(let command, let instruction):
                if allowsLogin {
                    loginSection(command, instruction)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ModalNote(text: ProviderBackendAvailability.remoteAuthMessage, icon: .info)
                        if descriptor.id == "codex-hermes" {
                            Button("Backend Sign-In") { showsRemoteLogin = true }.buttonStyle(.dockPrimary)
                        }
                    }
                }
            case .openApp(_, let instruction): openAppSection(instruction)
            }
        } footer: {
            websiteLink
            Spacer()
            switch descriptor.connect {
            case .apiKey:
                if hasStoredKey {
                    Button("Remove Key", role: .destructive) {
                        if let row = hermesRow {
                            saveHermesKey(nil, row)
                        } else {
                            control.saveProviderAPIKey(nil, for: descriptor)
                            refreshStoredKeyState()
                        }
                        apiKeyInput = ""
                    }
                    .buttonStyle(.dockSecondary)
                }
                Button(GatewayConnectionStore.isLocalBackend ? "Save & Test" : "Save Key") { saveAPIKey() }
                    .buttonStyle(.dockPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .login(let command, _):
                if !allowsLogin {
                    Button("Done") { dismiss() }
                        .buttonStyle(.dockPrimary)
                        .keyboardShortcut(.defaultAction)
                } else if login.isRunning {
                    Button("Cancel Sign-In") { login.cancel() }
                        .buttonStyle(.dockSecondary)
                } else if login.exitStatus == 0 {
                    Button("Done") { dismiss() }
                        .buttonStyle(.dockPrimary)
                        .keyboardShortcut(.defaultAction)
                } else if login.exitStatus == nil && login.failureText == nil {
                    Button("Log In") { startLogin(command) }
                        .buttonStyle(.dockPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            case .openApp(let applicationName, _):
                Button("Open \(applicationName)") { control.openProviderApplication(named: applicationName) }
                    .buttonStyle(.dockPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { refreshStoredKeyState() }
        .dockSheet(isPresented: $showsRemoteLogin) {
            RemoteProviderLoginSheet(control: control, provider: "openai-codex")
        }
        .onReceive(control.providerQuotaFreshness.$checkedAt) { quotaCheckedAt = $0 }
        .onChange(of: login.exitStatus) {
            if allowsLogin { control.refreshProviderQuota() }
        }
    }

    private var allowsLogin: Bool {
        ProviderBackendAvailability(isLocalBackend: GatewayConnectionStore.isLocalBackend).allowsLogin(for: descriptor)
    }

    private func startLogin(_ command: String) {
        guard allowsLogin else { return }
        login.start(command: command)
    }

    private func saveAPIKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        testStartedAt = GatewayConnectionStore.isLocalBackend ? .now : nil
        remoteKeySaved = false
        apiKeyInput = ""
        saveError = nil
        isSaving = true
        let binding = control.clientBindingGeneration
        let identity = control.dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        let profile = control.dockModel?.profileScopeID
        Task {
            defer { isSaving = false }
            // Providers is the source of truth: make sure its catalog is loaded
            // so the key lands in Hermes instead of a Herm-only store.
            if hermesRow == nil { try? await control.loadHermesProviderRows() }
            guard control.isCurrentClient(identity, bindingGeneration: binding),
                control.dockModel?.profileScopeID == profile
            else {
                testStartedAt = nil
                saveError = "The backend or profile changed before the key was saved."
                return
            }
            guard let row = hermesRow else {
                testStartedAt = nil
                saveError = "Couldn't reach Hermes to save this key. Check Settings → Providers."
                return
            }
            do {
                try await control.saveHermesProviderKey(key, row: row)
                remoteKeySaved = !GatewayConnectionStore.isLocalBackend
                refreshStoredKeyState()
            } catch {
                testStartedAt = nil
                saveError = error.localizedDescription
            }
        }
    }

    /// The Settings → Providers row this key belongs to: the key then lives in
    /// Hermes' .env, the same place Settings writes it.
    private var hermesRow: HermesProviderRow? {
        control.hermesRow(for: descriptor)
    }

    private func saveHermesKey(_ key: String?, _ row: HermesProviderRow) {
        saveError = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await control.saveHermesProviderKey(key, row: row)
                refreshStoredKeyState()
            } catch {
                testStartedAt = nil
                saveError = error.localizedDescription
            }
        }
    }

    private func refreshStoredKeyState() {
        if let row = hermesRow {
            hasStoredKey = row.authenticated
        } else {
            hasStoredKey = descriptor.storageKey.map { ProviderKeyStore().contains($0) } ?? false
        }
    }

    /// The quota read that follows Save & Test: nil while it is still running.
    private var testResult: (ok: Bool, text: String)? {
        // The Hermes save runs before the quota read starts; judging now would
        // report the previous read's "no key" error.
        guard !isSaving, let started = testStartedAt?.addingTimeInterval(-1) else { return nil }
        if let snapshot = control.providerQuotas.first(where: { $0.provider == descriptor.id }),
            (quotaCheckedAt[snapshot.provider] ?? snapshot.updatedAt) >= started
        {
            let first = snapshot.windows.first.map {
                " · \($0.label): \($0.remainingDisplay ?? $0.remainingPercent.map { "\(Int($0))% left" } ?? "reported")"
            }
            return (true, "Connected\(first ?? "")")
        }
        if control.refreshState(for: "provider.quota")?.isRefreshing != true {
            return (
                false,
                control.providerQuotaDiagnostic(for: descriptor.id)
                    ?? "The key was saved, but quota couldn't be read with it."
            )
        }
        return nil
    }

    private func apiKeySection(_ instruction: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            instructionText(instruction)
            labeledField("API key") {
                SecureField(
                    hasStoredKey ? "Paste a new key to replace the stored one" : "Paste your API key",
                    text: $apiKeyInput
                )
                .textFieldStyle(.dockGlass)
                .onSubmit { saveAPIKey() }
            }
            VStack(alignment: .leading, spacing: 6) {
                if remoteKeySaved {
                    ModalNote(
                        text: "Key saved to the Hermes backend. " + ProviderBackendAvailability.remoteQuotaMessage,
                        icon: .checkCircle, tone: .dockSuccess)
                }
                if testStartedAt != nil {
                    if let result = testResult {
                        ModalNote(
                            text: result.text, icon: result.ok ? .checkCircle : .warning,
                            tone: result.ok ? .dockSuccess : .dockWarning)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            ModalNote(text: "Testing the key…")
                        }
                    }
                } else if hasStoredKey {
                    ModalNote(
                        text: "A key is already stored for this provider.", icon: .checkCircle, tone: .dockSuccess)
                }
                if let saveError { ModalNote(text: saveError, icon: .warning, tone: .dockWarning) }
                ModalNote(
                    text: hermesRow.map {
                        "Saved by Hermes in its own .env\($0.keyEnv.map { " as \($0)" } ?? ""), the same key as Settings → Providers."
                    }
                        ?? "Stored in ~/.config/herm/providers.json with owner-only permissions. Never displayed or logged, and used only to read quota.",
                    icon: .lockSimple
                )
            }
        }
    }

    @ViewBuilder
    private func loginSection(_ command: String, _ instruction: String) -> some View {
        if login.isRunning || login.exitStatus != nil || login.failureText != nil {
            ProviderSignInFlow(
                login: login,
                providerName: descriptor.displayName,
                mark: ProviderMark(providerID: descriptor.id, displayName: descriptor.displayName),
                successDetail: "Signed in. Quota is refreshing.",
                onRetry: { startLogin(command) }
            )
            .frame(height: 300, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                instructionText(instruction)
                labeledField("Command") {
                    HStack(spacing: 8) {
                        Text(command)
                            .dockFont(.body, weight: .regular, design: .monospaced)
                            .foregroundStyle(Color.dockPrimaryText)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        DockCopyButton(
                            command,
                            accessibilityLabel: "Copy command",
                            presentation: .icon
                        )
                        .buttonStyle(.dockPress)
                    }
                    .dockPadding(.horizontal, 10)
                    .frame(minHeight: DockLayout.controlHeight)
                    .background(
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                            .dockSurfaceFill(
                                Color.dockControlSurface, stroke: Color.dockBorder, lineWidth: DockLayout.hairline)
                    )
                }
            }
        }
    }

    private func openAppSection(_ instruction: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            instructionText(instruction)
            ModalNote(
                text: "After you sign in, quota appears on refresh and stays live while the app is running.",
                icon: .info)
        }
    }

    private func instructionText(_ text: String) -> some View {
        Text(text)
            .dockFont(.navigation)
            .foregroundStyle(Color.dockPrimaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var websiteLink: some View {
        if let website = descriptor.website {
            let isAPIKey = if case .apiKey = descriptor.connect { true } else { false }
            Link(destination: website) {
                DockIconLabel(isAPIKey ? "Get an API Key" : "Open Website", icon: .arrowSquareOut)
                    .dockFont(.body, weight: .medium)
                    .foregroundStyle(Color.dockAccent)
            }
            .buttonStyle(.dockLink)
        }
    }
}
