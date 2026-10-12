import AppKit
import Combine
import SwiftUI

/// Real interactive terminal view following DESIGN.md glass pane & typography specifications.
@MainActor
private final class TerminalTabStore: ObservableObject {
    @Published private(set) var sessions: [LocalTerminalSession]
    @Published var selectedID: LocalTerminalSession.ID
    private var subscriptions: [AnyCancellable] = []

    init() {
        let session = LocalTerminalSession()
        sessions = [session]
        selectedID = session.id
        observe(session)
    }

    var selected: LocalTerminalSession {
        sessions.first(where: { $0.id == selectedID }) ?? sessions[0]
    }

    func add(directory: String) {
        let session = LocalTerminalSession()
        sessions.append(session)
        observe(session)
        selectedID = session.id
        session.start(directory: directory)
    }

    func closeSelected() {
        guard sessions.count > 1 else {
            selected.close()
            return
        }
        let index = sessions.firstIndex(where: { $0.id == selectedID }) ?? 0
        sessions[index].close()
        sessions.remove(at: index)
        subscriptions.removeAll()
        sessions.forEach(observe)
        selectedID = sessions[min(index, sessions.count - 1)].id
    }

    func closeAll() {
        sessions.forEach { $0.close() }
    }

    private func observe(_ session: LocalTerminalSession) {
        session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }
}

struct SessionTerminalView: View {
    let projectPath: String?
    let recipes: [VerificationRecipe]
    let repositoryID: String?
    let repositoryFingerprint: String?
    @StateObject private var terminalTabs = TerminalTabStore()

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

            SessionTerminalCanvas(session: terminal)
                .id(terminal.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 8)

        }
        .background(Color.dockCanvas)
        .task(id: projectPath) {
            terminal.start(directory: directory)
        }
        .onDisappear { terminalTabs.closeAll() }
    }

    private var terminalTabBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(terminalTabs.sessions) { session in
                        terminalTab(session)
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                terminalTabs.add(directory: directory)
            } label: {
                DockIcon(.plus)
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.dockHover)
            .help("New terminal session")
        }
        .padding(.horizontal, 0)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func terminalTab(_ session: LocalTerminalSession) -> some View {
        HStack(spacing: 7) {
            DockIcon(.terminal)
                .font(.system(size: 10, weight: .semibold))
            Text("Shell \((terminalTabs.sessions.firstIndex(where: { $0.id == session.id }) ?? 0) + 1)")
                .font(.system(size: 12))
                .lineLimit(1)
            Button {
                terminalTabs.selectedID = session.id
                terminalTabs.closeSelected()
            } label: {
                DockIcon(.x)
                    .font(.system(size: 9, weight: .semibold))
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
                .font(.system(size: 12))
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
                .help(directory)
            if case .failed(let error) = terminal.state {
                Text(error).font(.system(size: 12)).foregroundStyle(Color.dockWarning)
                Button("Retry") { terminal.start(directory: directory) }.buttonStyle(.dockHover)
            }
            if terminal.state == .closed || terminal.state == .exited {
                Button("Restart") { terminal.start(directory: directory) }
                    .buttonStyle(.dockHover)
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
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.dockAccent)
                .help("Run verified repository check")
                .accessibilityLabel("Run verified repository check")
                .accessibilityIdentifier(WorkflowAccessibilityIdentifier.terminalRunVerification)
                .disabled(terminal.state != .ready)
            }

            DockMenu {
                Button("Clear output") { terminal.clear() }
                Button("Interrupt", action: terminal.interrupt)
                    .disabled(!canInterrupt)
                Button("Restart shell") { terminal.start(directory: directory) }
            } label: {
                DockIcon(.dotsThree).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Terminal options")

        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func verificationRunBanner(_ run: VerificationRun) -> some View {
        HStack(spacing: 8) {
            Text(run.isComplete ? "\(run.command) · EXIT \(run.exitCode ?? -1)\(run.durationLabel.map { " · \($0)" } ?? "")" : "Running \(run.command)…")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(run.isComplete && run.exitCode == 0 ? Color.dockSuccess : Color.dockWarning)
                .lineLimit(1)
            if let recipe = recipes.first(where: { $0.id == run.recipeID }), run.isComplete {
                Button("Rerun") {
                    guard let repositoryID, let repositoryFingerprint else { return }
                    terminal.runVerification(recipe, repositoryID: repositoryID, repositoryFingerprint: repositoryFingerprint)
                }
                .buttonStyle(.dockHover)
                .foregroundStyle(Color.dockAccent)
                .accessibilityLabel("Rerun \(recipe.title)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .accessibilityLabel(run.isComplete ? "Verification completed with exit code \(run.exitCode ?? -1)" : "Verification running")
    }
}
