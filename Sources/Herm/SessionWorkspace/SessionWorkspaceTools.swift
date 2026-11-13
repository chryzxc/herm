import AppKit
import Combine
import SwiftUI

struct SessionTerminalView: View {
    var discoveryActive = true
    let projectPath: String?
    let recipes: [VerificationRecipe]
    let repositoryID: String?
    let repositoryFingerprint: String?
    @ObservedObject private var terminalTabs: TerminalTabStore
    @Environment(\.chatContextRouter) private var contextRouter

    init(
        projectPath: String?, recipes: [VerificationRecipe], repositoryID: String?, repositoryFingerprint: String?,
        workspaceKey: String = "local", discoveryActive: Bool = true
    ) {
        self.discoveryActive = discoveryActive
        self.projectPath = projectPath
        self.recipes = recipes
        self.repositoryID = repositoryID
        self.repositoryFingerprint = repositoryFingerprint
        self.terminalTabs = TerminalWorkspaceStore.shared.workspace(key: workspaceKey + ":" + (projectPath ?? "home"))
    }

    private var directory: String { projectPath ?? FileManager.default.homeDirectoryForCurrentUser.path }

    private var terminal: LocalTerminalSession { terminalTabs.selected }

    private var canInterrupt: Bool {
        if case .running = terminal.state { return true }
        if case .interrupting = terminal.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            terminalControls
            if let run = terminal.lastVerificationRun {
                verificationRunBanner(run)
            }

            pane(terminal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dockPadding(.top, 8)

        }
        .background(Color.dockCanvas)
        .task(id: terminal.id) {
            if terminal.workingDirectory == nil { terminal.start(directory: directory) }
        }
    }
    private func pane(_ session: LocalTerminalSession) -> some View {
        SessionTerminalCanvas(session: session) { excerpt, start, end in
            let bytes = Array(excerpt.utf8.prefix(32 * 1024))
            let content = String(decoding: bytes, as: UTF8.self)
            let label = "Terminal lines \(start)–\(end)"
            contextRouter?.model?.attachedContexts.append(
                ChatContext(
                    id: UUID().uuidString, title: label,
                    body:
                        "\(label) (\(session.workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Home"))\n```\n\(content)\n```"
                        + (bytes.count < excerpt.utf8.count ? "\nExcerpt truncated at 32 KiB." : "")))
        }.id(session.id)
    }

    private var terminalControls: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(URL(fileURLWithPath: directory).lastPathComponent)
                .dockFont(.body)
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
                .help(directory)
            if case .failed(let error) = terminal.state {
                Text(error).dockFont(.body).foregroundStyle(Color.dockWarning)
                Button("Retry") { terminal.start(directory: directory) }.buttonStyle(.dockCompact)
            }
            if terminal.state == .closed || terminal.state == .exited {
                Button("Restart") { terminal.start(directory: directory) }
                    .buttonStyle(.dockCompact)
            }
            Spacer(minLength: 8)

            if !recipes.isEmpty {
                DockMenu {
                    ForEach(recipes) { recipe in
                        Button(recipe.title) {
                            guard let repositoryID, let repositoryFingerprint else { return }
                            terminal.runVerification(
                                recipe, repositoryID: repositoryID, repositoryFingerprint: repositoryFingerprint)
                        }
                        Button("Copy \(recipe.title.lowercased()) command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(recipe.command, forType: .string)
                        }
                    }
                } label: {
                    Label("Run check", icon: .sealCheck)
                        .dockFont(.metadata, weight: .semibold)
                }
                .foregroundStyle(Color.dockAccent)
                .help("Run verified repository check")
                .accessibilityLabel("Run verified repository check")
                .accessibilityIdentifier(WorkflowAccessibilityIdentifier.terminalRunVerification)
                .disabled(terminal.state != .ready)
            }

            HStack(spacing: 4) {
                LocalServersMenu(processIDs: terminalTabs.sessions.map(\.shellProcessID), active: discoveryActive)
                DockMenu {
                    Button("Clear output") { terminal.clear() }
                    Button("Interrupt", action: terminal.interrupt).disabled(!canInterrupt)
                    Button("Restart shell") { terminal.start(directory: directory) }
                } label: {
                    DockIcon(.dotsThreeVertical).frame(width: 32, height: 32)
                }
                .accessibilityLabel("Terminal options")
            }
        }
        .dockPadding(.horizontal, 14)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func verificationRunBanner(_ run: VerificationRun) -> some View {
        HStack(spacing: 8) {
            Text(
                run.isComplete
                    ? "\(run.command) · EXIT \(run.exitCode ?? -1)\(run.durationLabel.map { " · \($0)" } ?? "")"
                    : "Running \(run.command)…"
            )
            .dockFont(.compactStatus, weight: .regular, design: .monospaced)
            .foregroundStyle(run.isComplete && run.exitCode == 0 ? Color.dockSuccess : Color.dockWarning)
            .lineLimit(1)
            if let recipe = recipes.first(where: { $0.id == run.recipeID }), run.isComplete {
                Button("Rerun") {
                    guard let repositoryID, let repositoryFingerprint else { return }
                    terminal.runVerification(
                        recipe, repositoryID: repositoryID, repositoryFingerprint: repositoryFingerprint)
                }
                .buttonStyle(.dockCompact)
                .foregroundStyle(Color.dockAccent)
                .accessibilityLabel("Rerun \(recipe.title)")
            }
        }
        .dockPadding(.horizontal, 14)
        .dockPadding(.vertical, 5)
        .accessibilityLabel(
            run.isComplete ? "Verification completed with exit code \(run.exitCode ?? -1)" : "Verification running")
    }
}
