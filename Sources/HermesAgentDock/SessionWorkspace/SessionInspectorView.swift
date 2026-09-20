import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers
struct SessionInspector: View {
    @ObservedObject var model: DockModel
    @ObservedObject var botMode: BotModeModel
    @ObservedObject var control: ControlCenterModel
    @ObservedObject var workflow: DeveloperWorkflowModel
    let sessionRepositoryPath: String?
    let sessionProjectIsBound: Bool
    var showsHeader = true
    @State private var selectedSection = Section.activity
    @State private var isSwitchingBranch = false
    @StateObject private var preferences = CommandCenterPreferencesStore()

    private let sessionTabFont = Font.system(size: 12, weight: .semibold)

    private enum Section: String, CaseIterable, Identifiable {
        case activity = "Activity"
        case files = "Files"
        case changes = "Source Control"
        case terminal = "Terminal"

        var id: Self { self }
        var navigationTitle: String {
            switch self {
            case .files: "Explorer"
            case .terminal: "Terminal"
            case .activity: "Activity"
            case .changes: "Source Control"
            }
        }
        var icon: String {
            switch self {
            case .activity: "waveform.path.ecg"
            case .files: "folder"
            case .changes: "arrow.triangle.branch"
            case .terminal: "terminal"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                inspectorHeader
            }
            sessionModePicker

            if let workflowError = workflow.error {
                HStack(spacing: 8) {
                    LucideImage(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.dockWarning)
                    Text(workflowError)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.dockWarning.opacity(0.08))
                .overlay(alignment: .bottom) {
                    Color.dockWarning.opacity(0.25).frame(height: 0.5)
                }
            }

            ScrollView {
                inspectorContent
                    .padding(.horizontal, DockLayout.compactInset)
                    .padding(.top, selectedSection == .activity ? DockLayout.tight : DockLayout.compactInset)
                    .padding(.bottom, DockLayout.compactInset)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dockCanvas)
    }

    private var sessionModePicker: some View {
        // Keep every session destination in one horizontally scrollable strip.
        // There is no overflow menu competing with the same navigation model.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach([Section.files, .terminal, .activity, .changes]) { section in
                    sectionButton(section)
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 4)
        .frame(height: 52)
        .background(Color.dockSurface2.opacity(0.72))
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    private func sectionButton(_ section: Section) -> some View {
        Button {
            withAnimation(.dockEase(duration: 0.2)) {
                selectedSection = section
            }
        } label: {
            HStack(spacing: 5) {
                LucideImage(systemName: section.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(section.navigationTitle)
                    .lineLimit(1)
            }
                .font(sessionTabFont)
                .foregroundStyle(selectedSection == section ? Color.dockPrimaryText : Color.dockSecondaryText)
                .frame(minWidth: 88, minHeight: 36)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selectedSection == section ? Color.dockAccent.opacity(0.10) : Color.clear)
                }
                .overlay(alignment: .bottom) {
                    if selectedSection == section {
                        Color.dockAccent.frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Show \(section.rawValue)")
    }

    private var inspectorHeader: some View {
        HStack(alignment: .center, spacing: 9) {
            LucideImage(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentSessionTitle ?? "Untitled session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                if let sessionProjectName {
                    LucideLabel(sessionProjectName, icon: "folder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(model.status.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(model.status == .working ? Color.dockAccent : Color.dockSecondaryText)
        }
        .padding(.horizontal, 16)
        .frame(height: sessionProjectName == nil ? 50 : 58)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private var sessionProjectName: String? {
        guard sessionProjectIsBound,
              let sessionRepositoryPath,
              !sessionRepositoryPath.isEmpty else { return nil }
        let name = URL(fileURLWithPath: sessionRepositoryPath).lastPathComponent
        return name.isEmpty ? nil : name
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch selectedSection {
        case .activity:
            VStack(alignment: .leading, spacing: 12) {
                SessionKanbanActivityView(
                    model: model,
                    control: control,
                    botMode: botMode,
                    sessionID: model.kanbanSessionID
                )
                AgentBoardView(model: model, embedded: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        case .files:
            VStack(alignment: .leading, spacing: 14) {
                inspectorLabel("PROJECT FILES")
                SessionFilesView(
                    projectPath: sessionRepositoryPath,
                    onRefresh: { await workflow.refresh(preferences: preferences, control: control) }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .changes:
            RepositoryChangesBrowser(
                model: model,
                workflow: workflow,
                projectPath: sessionRepositoryPath,
                onRefresh: { await workflow.refresh(preferences: preferences, control: control) }
            )
        case .terminal:
            SessionTerminalView(
                projectPath: sessionRepositoryPath,
                recipes: VerificationRecipeBuilder.make(facts: control.projectFacts, repository: workflow.repository),
                repositoryID: workflow.repository.isGitRepository ? workflow.repository.repositoryID : nil,
                repositoryFingerprint: workflow.repositoryFingerprint
            )
        }
    }

    private func inspectorLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.dockSecondaryText)
    }

    /// Renders repository telemetry without duplicating the model selector from the composer.
    private func sessionTelemetryStrip(focus: MissionControlFocus) -> some View {
        struct TelemetryItem: Identifiable {
            let id: String
            let icon: String
            let label: String
            let value: String
        }

        let items: [TelemetryItem] = [
            focus.branch.map { TelemetryItem(id: "branch", icon: "arrow.triangle.branch", label: "BRANCH", value: $0) },
            focus.contextPercent.map { TelemetryItem(id: "context", icon: "chart.bar.fill", label: "CONTEXT", value: "\(Int($0.rounded()))%") },
            focus.changedFiles.map { TelemetryItem(id: "files", icon: "doc.badge.gearshape", label: "CHANGED", value: "\($0) files") }
        ].compactMap { $0 }

        return Group {
            if !items.isEmpty {
                HStack(spacing: 0) {
                    if let branch = items.first(where: { $0.id == "branch" }), workflow.repository.isGitRepository {
                        Menu {
                            ForEach(workflow.branches, id: \.self) { branchName in
                                Button {
                                    isSwitchingBranch = true
                                    Task {
                                        _ = await workflow.switchBranch(branchName, preferences: preferences, control: control)
                                        isSwitchingBranch = false
                                    }
                                } label: {
                                    if branchName == workflow.repository.branch {
                                        LucideLabel(branchName, icon: "checkmark")
                                    } else {
                                        Text(branchName)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                LucideImage(systemName: isSwitchingBranch ? "refresh-cw" : branch.icon)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.dockAccent)
                                Text(branch.value)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.dockPrimaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                LucideImage(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Color.dockSecondaryText)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .buttonStyle(.borderless)
                        .disabled(isSwitchingBranch || workflow.branches.isEmpty)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if items.contains(where: { $0.id != "branch" }) {
                            Divider()
                                .frame(height: 24)
                                .padding(.horizontal, 10)
                        }
                    }

                    ForEach(items.filter { $0.id != "branch" }) { item in
                        HStack(spacing: 6) {
                            LucideImage(systemName: item.icon)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.dockAccent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.label)
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.dockSecondaryText)
                                Text(item.value)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.dockPrimaryText)
                                    .lineLimit(1)
                            }
                            if item.id != items.filter({ $0.id != "branch" }).last?.id {
                                Divider()
                                    .frame(height: 24)
                                    .padding(.horizontal, 10)
                            }
                        }
                    }
                }
                .padding(10)
                .dockGlassPane()
            }
        }
    }

    /// Renders pre-flight readiness checks for repository cleanliness and model configuration.
    private func sessionReadinessCard(readiness: ReadinessSummary) -> some View {
        let color: Color = switch readiness.state {
        case .ready: .dockSuccess
        case .needsReview: .dockWarning
        case .blocked: .dockDestructive
        case .notApplicable: .dockSecondaryText
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                LucideImage(systemName: "checkmark.shield")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                Text("PRE-FLIGHT READINESS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.75)
                    .foregroundStyle(color)
                Spacer(minLength: 0)
                Text(readiness.state.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
            }

            Text(readiness.detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dockPrimaryText)

            if let scope = readiness.verificationScope {
                Text("Scope: \(scope)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .dockGlassPane()
    }

    /// Renders an individual attention item requiring user action or response.
    private func attentionRow(_ attention: AttentionItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                LucideImage(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                Text(attention.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(attention.kind.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dockWarning)
            }
            if !attention.detail.isEmpty {
                Text(attention.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .dockGlassPane()
    }
}
