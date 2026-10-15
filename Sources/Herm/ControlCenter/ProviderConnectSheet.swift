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
    var onFinished: (() -> Void)?

    private var process: Process?
    private var inputPipe: Pipe?
    private var pendingPartialLine = ""

    func start(command: String) {
        guard !isRunning else { return }
        outputLines = []
        exitStatus = nil
        failureText = nil
        pendingPartialLine = ""

        let arguments = command.split(separator: " ").map(String.init)
        let searchDirectories = Self.defaultSearchDirectories()
        guard let executablePath = Self.executablePath(command: command, searchDirectories: searchDirectories) else {
            failureText = "The \(arguments.first ?? "provider") command was not found on this Mac. Install it and try again."
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
    }

    func cancel() {
        process?.terminate()
    }

    private func accumulate(_ text: String) {
        let combined = pendingPartialLine + text
        var lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        pendingPartialLine = lines.removeLast()
        outputLines = Self.cappedLines(outputLines, newLines: lines)
    }

    private func finish(terminationStatus: Int32) {
        guard isRunning else { return }
        isRunning = false
        exitStatus = terminationStatus
        inputPipe = nil
        if !pendingPartialLine.isEmpty {
            outputLines = Self.cappedLines(outputLines, newLines: [pendingPartialLine])
            pendingPartialLine = ""
        }
        onFinished?()
    }

    // MARK: - Pure helpers

    static func cappedLines(_ existing: [String], newLines: [String], lineLimit: Int = 400, characterLimit: Int = 16_000) -> [String] {
        var lines = existing + newLines.map(HermesRuntimeInspector.stripANSI)
        while lines.count > lineLimit { lines.removeFirst(lines.count - lineLimit) }
        while lines.joined(separator: "\n").count > characterLimit && lines.count > 1 { lines.removeFirst(1) }
        return lines
    }

    static func executablePath(command: String, searchDirectories: [String], fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
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
            "\(homePath)/.volta/bin"
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
    @State private var callbackCodeInput = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DockModal(
            badge: AnyView(ProviderMarkBadge(mark: ProviderMark(providerID: descriptor.id, displayName: descriptor.displayName), size: 32)),
            title: "Connect \(descriptor.displayName)",
            subtitle: descriptor.summary
        ) {
            switch descriptor.connect {
            case .apiKey(let instruction, _): apiKeySection(instruction)
            case .login(let command, let instruction): loginSection(command, instruction)
            case .openApp(_, let instruction): openAppSection(instruction)
            }
        } footer: {
            websiteLink
            Spacer()
            switch descriptor.connect {
            case .apiKey:
                if hasStoredKey {
                    Button("Remove Key", role: .destructive) {
                        control.saveProviderAPIKey(nil, for: descriptor)
                        apiKeyInput = ""
                        refreshStoredKeyState()
                    }
                    .buttonStyle(.dockSecondary)
                }
                Button("Save & Test") { saveAPIKey() }
                    .buttonStyle(.dockPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .login(let command, _):
                if login.isRunning {
                    Button("Cancel Sign-In") { login.cancel() }
                        .buttonStyle(.dockSecondary)
                } else {
                    Button("Log In") { login.start(command: command) }
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
        .onChange(of: login.exitStatus) { control.refreshProviderQuota() }
    }

    private func saveAPIKey() {
        guard !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        control.saveProviderAPIKey(apiKeyInput, for: descriptor)
        apiKeyInput = ""
        refreshStoredKeyState()
    }

    private func refreshStoredKeyState() {
        hasStoredKey = descriptor.storageKey.map { ProviderKeyStore().contains($0) } ?? false
    }

    private func submitCallbackCode() {
        let trimmed = callbackCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        login.sendInput(trimmed)
        callbackCodeInput = ""
    }

    private func apiKeySection(_ instruction: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            instructionText(instruction)
            labeledField("API key") {
                SecureField(hasStoredKey ? "Paste a new key to replace the stored one" : "Paste your API key", text: $apiKeyInput)
                    .textFieldStyle(.dockGlass)
                    .onSubmit { saveAPIKey() }
            }
            VStack(alignment: .leading, spacing: 6) {
                if hasStoredKey {
                    ModalNote(text: "A key is already stored for this provider.", icon: .checkCircle, tone: .dockSuccess)
                }
                ModalNote(text: "Stored in ~/.config/herm/providers.json with owner-only permissions. Never displayed or logged, and used only to read quota.", icon: .lockSimple)
            }
        }
    }

    private func loginSection(_ command: String, _ instruction: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            instructionText(instruction)
            labeledField("Command") {
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
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
                .padding(.horizontal, 10)
                .frame(minHeight: DockLayout.controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                        .fill(Color.dockControlSurface)
                        .stroke(Color.dockBorder, lineWidth: DockLayout.hairline)
                )
            }
            if login.isRunning {
                labeledField("Authorization code", hint: "Shown in the browser after you sign in") {
                    HStack(spacing: 8) {
                        DockTextField("Paste the code", text: $callbackCodeInput)
                            .textFieldStyle(.dockGlass)
                            .onSubmit { submitCallbackCode() }
                        Button("Submit") { submitCallbackCode() }
                            .buttonStyle(.dockSecondary)
                            .disabled(callbackCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(descriptor.displayName) sign-in…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                }
            }
            if let status = login.exitStatus, !login.isRunning {
                ModalNote(
                    text: status == 0 ? "The login command finished. Quota was refreshed." : "The login command exited with status \(status). Check the output below.",
                    icon: status == 0 ? .checkCircle : .warning,
                    tone: status == 0 ? .dockSuccess : .dockWarning
                )
            }
            if let failure = login.failureText {
                ModalNote(text: failure, icon: .warning, tone: .dockWarning)
            }
            if !login.outputLines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(login.outputLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.dockMetadataText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 160)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                        .fill(Color.dockSurface.opacity(0.4))
                        .stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline)
                )
            }
        }
    }

    private func openAppSection(_ instruction: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            instructionText(instruction)
            ModalNote(text: "After you sign in, quota appears on refresh and stays live while the app is running.", icon: .info)
        }
    }

    private func instructionText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.dockPrimaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var websiteLink: some View {
        if let website = descriptor.website {
            let isAPIKey = if case .apiKey = descriptor.connect { true } else { false }
            Link(destination: website) {
                DockIconLabel(isAPIKey ? "Get an API Key" : "Open Website", icon: .arrowSquareOut)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dockAccent)
            }
            .buttonStyle(.dockHover)
        }
    }
}
