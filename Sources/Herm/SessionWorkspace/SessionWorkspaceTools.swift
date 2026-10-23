import AppKit
import Combine
import SwiftUI

struct SessionTerminalView: View {
    var discoveryActive = true
    let projectPath: String?
    let recipes: [VerificationRecipe]
    let repositoryID: String?
    let repositoryFingerprint: String?
    /// Bumped by the inspector's + menu to open another shell.
    var newShellRequest = 0
    @ObservedObject private var terminalTabs: TerminalTabStore
    @Environment(\.chatContextRouter) private var contextRouter
    @State private var confirmingClose = false

    init(projectPath: String?, recipes: [VerificationRecipe], repositoryID: String?, repositoryFingerprint: String?,
         workspaceKey: String = "local", newShellRequest: Int = 0, discoveryActive: Bool = true) {
        self.discoveryActive = discoveryActive
        self.projectPath = projectPath; self.recipes = recipes; self.repositoryID = repositoryID
        self.repositoryFingerprint = repositoryFingerprint; self.newShellRequest = newShellRequest
        self.terminalTabs = TerminalWorkspaceStore.shared.workspace(key: workspaceKey + ":" + (projectPath ?? "home"))
    }
    @State private var isHoveringNewShell = false

    private var directory: String { projectPath ?? FileManager.default.homeDirectoryForCurrentUser.path }

    private var terminal: LocalTerminalSession { terminalTabs.selected }

    private var canInterrupt: Bool {
        if case .running = terminal.state { return true }
        if case .interrupting = terminal.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            terminalTabBar
            terminalControls
            if let run = terminal.lastVerificationRun {
                verificationRunBanner(run)
            }

            GeometryReader { geometry in
                if terminalTabs.splitIDs.count > 1 {
                    // Stack narrow panes without changing the stored split preference.
                    if terminalTabs.splitAxis == 0 && geometry.size.width >= CGFloat(visibleSessions.count) * 280 {
                        HSplitView { ForEach(visibleSessions) { pane($0).frame(minWidth: 160) } }
                    } else {
                        VSplitView { ForEach(visibleSessions) { pane($0).frame(minHeight: 100) } }
                    }
                } else { pane(terminal) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, 8)

        }
        .background(Color.dockCanvas)
        .task(id: terminal.id) {
            for session in visibleSessions + [terminal] where session.workingDirectory == nil { session.start(directory: directory) }
        }
        .onChange(of: newShellRequest) { _, _ in terminalTabs.add(directory: directory) }
        .confirmationDialog("Close the running terminal?", isPresented: $confirmingClose) {
            Button("Close terminal", role: .destructive) { terminalTabs.closeSelected() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The foreground command will stop. Other terminals stay open.") }
    }

    private var visibleSessions: [LocalTerminalSession] {
        terminalTabs.sessions.filter { terminalTabs.splitIDs.contains($0.id) }
    }
    private func split(axis: Int) {
        if terminalTabs.splitIDs.isEmpty { terminalTabs.splitIDs = [terminal.id] }
        terminalTabs.splitAxis = axis
        terminalTabs.add(directory: directory)
        terminalTabs.splitIDs.append(terminal.id)
    }
    private func pane(_ session: LocalTerminalSession) -> some View {
        SessionTerminalCanvas(session: session) { excerpt, start, end in
            let bytes = Array(excerpt.utf8.prefix(32 * 1024))
            let content = String(decoding: bytes, as: UTF8.self)
            let label = "Terminal lines \(start)–\(end)"
            contextRouter?.model?.attachedContexts.append(ChatContext(id: UUID().uuidString, title: label,
                body: "\(label) (\(session.workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Home"))\n```\n\(content)\n```" + (bytes.count < excerpt.utf8.count ? "\nExcerpt truncated at 32 KiB." : "")))
        }.id(session.id)
    }

    private var terminalTabBar: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(terminalTabs.sessions) { session in
                            terminalTab(session).id(session.id)
                        }
                        Button {
                            terminalTabs.add(directory: directory)
                        } label: {
                            DockIcon(.plus)
                                .dockFont(.pageTitle, weight: .light)
                                .foregroundStyle(isHoveringNewShell ? Color.dockPrimaryText : Color.dockSecondaryText)
                                .frame(width: 32, height: 32)
                                .background(isHoveringNewShell ? Color.dockSurface2 : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1))
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringNewShell = $0 }
                        .animation(.dockEase(duration: 0.12), value: isHoveringNewShell)
                        .help("New terminal session").accessibilityLabel("New terminal session")
                    }
                }
                .onAppear { proxy.scrollTo(terminalTabs.selectedID, anchor: .trailing) }
                .onChange(of: terminalTabs.selectedID) { _, id in proxy.scrollTo(id, anchor: .trailing) }
            }

            Spacer(minLength: 0)

            DockMenu {
                Button("Split horizontally") { split(axis: 0) }.disabled(terminalTabs.splitIDs.count >= 4)
                Button("Split vertically") { split(axis: 1) }.disabled(terminalTabs.splitIDs.count >= 4)
                Button("Show selected shell only") { terminalTabs.splitIDs = [] }
                Button("Clear output") { terminal.clear() }
                Button("Interrupt", action: terminal.interrupt)
                    .disabled(!canInterrupt)
                Button("Restart shell") { terminal.start(directory: directory) }
            } label: {
                DockIcon(.dotsThree).frame(width: 32, height: 32)
            }
            .accessibilityLabel("Terminal options")
        }
        .padding(.horizontal, 0)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func terminalTab(_ session: LocalTerminalSession) -> some View {
        HStack(spacing: 7) {
            DockIcon(.terminal)
                .dockFont(.compactStatus, weight: .semibold)
            Text("Shell \((terminalTabs.sessions.firstIndex(where: { $0.id == session.id }) ?? 0) + 1)")
                .dockFont(.body)
                .lineLimit(1)
            Button {
                terminalTabs.selectedID = session.id
                if terminal.hasForegroundJob { confirmingClose = true } else { terminalTabs.closeSelected() }
            } label: {
                DockIcon(.x)
                    .dockFont(size: 9, weight: .semibold)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .help("Close terminal")
        }
        .foregroundStyle(terminalTabs.selectedID == session.id ? Color.dockPrimaryText : Color.dockSecondaryText)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .fill(terminalTabs.selectedID == session.id ? Color.dockSurface6 : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { terminalTabs.selectedID = session.id }
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
            if let command = terminal.projectCommand {
                Text(command.isRunning ? "Running action…" : command.exitCode.map { "Action exited \($0)" } ?? "Action interrupted")
                    .dockFont(.metadata).foregroundStyle(command.exitCode.map { $0 == 0 ? Color.dockSuccess : Color.dockWarning } ?? Color.dockSecondaryText)
            }
            Spacer(minLength: 8)

            if !recipes.isEmpty {
                DockMenu {
                    ForEach(recipes) { recipe in
                        Button(recipe.title) {
                            guard let repositoryID, let repositoryFingerprint else { return }
                            terminal.runVerification(recipe, repositoryID: repositoryID, repositoryFingerprint: repositoryFingerprint)
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

            LocalServersMenu(processIDs: terminalTabs.sessions.map(\.shellProcessID), active: discoveryActive)

        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func verificationRunBanner(_ run: VerificationRun) -> some View {
        HStack(spacing: 8) {
            Text(run.isComplete ? "\(run.command) · EXIT \(run.exitCode ?? -1)\(run.durationLabel.map { " · \($0)" } ?? "")" : "Running \(run.command)…")
                .dockFont(.compactStatus, weight: .regular, design: .monospaced)
                .foregroundStyle(run.isComplete && run.exitCode == 0 ? Color.dockSuccess : Color.dockWarning)
                .lineLimit(1)
            if let recipe = recipes.first(where: { $0.id == run.recipeID }), run.isComplete {
                Button("Rerun") {
                    guard let repositoryID, let repositoryFingerprint else { return }
                    terminal.runVerification(recipe, repositoryID: repositoryID, repositoryFingerprint: repositoryFingerprint)
                }
                .buttonStyle(.dockCompact)
                .foregroundStyle(Color.dockAccent)
                .accessibilityLabel("Rerun \(recipe.title)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .accessibilityLabel(run.isComplete ? "Verification completed with exit code \(run.exitCode ?? -1)" : "Verification running")
    }
}
