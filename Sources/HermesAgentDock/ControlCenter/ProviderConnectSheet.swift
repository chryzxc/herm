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
            failureText = "The \(arguments.first ?? command) command was not found on this Mac. Install it, or run \(command) in a terminal and refresh."
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
            failureText = "\(command) could not be started: \(error.localizedDescription)"
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
        var lines = existing + newLines
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
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect \(descriptor.displayName)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Text(descriptor.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSecondaryText)
            }

            switch descriptor.connect {
            case .apiKey(let instruction, _): apiKeySection(instruction)
            case .login(let command, let instruction): loginSection(command, instruction)
            case .openApp(let applicationName, let instruction): openAppSection(applicationName, instruction)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 470)
        .onAppear { refreshStoredKeyState() }
        .onChange(of: login.exitStatus) { control.refreshProviderQuota() }
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
        VStack(alignment: .leading, spacing: 9) {
            Text(instruction)
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("API key", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button {
                    control.saveProviderAPIKey(apiKeyInput, for: descriptor)
                    apiKeyInput = ""
                    refreshStoredKeyState()
                } label: {
                    Text("Save & Test")
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasStoredKey {
                    Button(role: .destructive) {
                        control.saveProviderAPIKey(nil, for: descriptor)
                        apiKeyInput = ""
                        refreshStoredKeyState()
                    } label: {
                        Text("Remove Stored Key")
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                websiteLink("Get an API Key")
            }
            if hasStoredKey {
                Text("A key is already stored for this provider.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
            }
            Text("The key is stored in ~/.config/hermes-agent-dock/providers.json with owner-only permissions and is never displayed or logged. No Keychain is used.")
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loginSection(_ command: String, _ instruction: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(instruction)
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.dockPrimaryText)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    LucideImage(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockAccent)
                .help("Copy command")
            }
            if login.isRunning {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(descriptor.displayName) sign-in…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                    Spacer()
                    Button("Cancel") { login.cancel() }
                        .buttonStyle(.bordered)
                }
                HStack(spacing: 8) {
                    TextField("Paste the code from the browser page", text: $callbackCodeInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitCallbackCode() }
                    Button("Submit") { submitCallbackCode() }
                        .buttonStyle(.borderedProminent)
                        .disabled(callbackCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("After signing in, the browser shows an authorization code. Paste it here to finish.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    Button { login.start(command: command) } label: {
                        LucideLabel("Log In with \(descriptor.displayName)", icon: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    websiteLink("Open Website")
                }
                if let status = login.exitStatus {
                    Text(status == 0 ? "The login command finished. Quota was refreshed." : "The login command exited with status \(status). Check the output below.")
                        .font(.system(size: 11))
                        .foregroundStyle(status == 0 ? Color.dockSuccess : Color.dockWarning)
                }
                if let failure = login.failureText {
                    Text(failure)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(Color.dockSurface.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    private func openAppSection(_ applicationName: String, _ instruction: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(instruction)
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    control.openProviderApplication(named: applicationName)
                } label: {
                    LucideLabel("Open \(applicationName)", icon: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                websiteLink("Open Website")
            }
            Text("After you sign in, quota appears on refresh and stays live while the app is running.")
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func websiteLink(_ title: String) -> some View {
        Group {
            if let website = descriptor.website {
                Link(destination: website) {
                    Text(title)
                }
            }
        }
    }
}
