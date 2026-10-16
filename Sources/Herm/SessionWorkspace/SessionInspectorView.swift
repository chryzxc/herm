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
    /// The session's bound folder; `sessionRepositoryPath` may be a worktree of it.
    var sessionRootPath: String? = nil
    var onSelectWorktree: ((String) -> Void)? = nil
    var showsHeader = true
    /// Collapses the inspector; shown at the right of the tab strip when set.
    var onToggle: (() -> Void)?
    /// Matches the chat header beside it so both rows share one baseline and separator.
    var headerHeight: CGFloat = 44
    // Persisted so collapsing and reopening the panel keeps the open tab.
    @AppStorage("sessionInspector.selectedSection") private var selectedSection = Section.activity
    @AppStorage("sessionInspector.closedSections") private var closedRaw = "Browser"
    /// Sessions whose Browser tab is open. The browser belongs to the session it was
    /// opened in (by Hermes or a chat link) and stays out of every other session.
    @AppStorage("sessionInspector.browserSessions") private var browserSessionsRaw = ""
    @State private var isShowingNewTab = false
    /// Extra Terminal/Browser instances opened from +. They stay mounted while
    /// another tab is selected so their shells and pages keep running.
    @State private var extras: [ExtraTab] = []
    @State private var selectedExtraID: UUID?
    /// Narrow panel: unselected tabs shrink to icons and + stays pinned.
    @State private var isCompactStrip = false
    @State private var hoveredSection: Section?
    @State private var isSwitchingBranch = false
    @StateObject private var preferences = CommandCenterPreferencesStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let sessionTabFont = Font.system(size: 12, weight: .semibold)

    private struct ExtraTab: Identifiable {
        let id = UUID()
        let kind: Section
        let number: Int
        /// Extra browsers belong to the session they were opened in; terminals are shared.
        var sessionID: String?
    }

    private enum Section: String, CaseIterable, Identifiable {
        case activity = "Activity"
        case files = "Files"
        case changes = "Source Control"
        case terminal = "Terminal"
        case browser = "Browser"

        var id: Self { self }
        var navigationTitle: String {
            switch self {
            case .files: "Explorer"
            case .terminal: "Terminal"
            case .activity: "Activity"
            case .changes: "Source Control"
            case .browser: "Browser"
            }
        }
        var icon: Ph {
            switch self {
            case .activity: .pulse
            case .files: .folder
            case .changes: .gitBranch
            case .terminal: .terminal
            case .browser: .globe
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                inspectorHeader
            }
            sessionModePicker
            if selectedSection == .changes, let onSelectWorktree, workflow.repository.isGitRepository, !workflow.worktrees.isEmpty {
                WorktreePicker(
                    worktrees: workflow.worktrees,
                    mainPath: sessionRootPath,
                    selection: Binding(get: { sessionRepositoryPath }, set: { $0.map(onSelectWorktree) })
                )
                .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
            }

            if let workflowError = workflow.error {
                HStack(spacing: 8) {
                    DockIcon(.warning)
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

            ZStack {
                baseContent
                    .opacity(selectedExtraID == nil ? 1 : 0)
                    .allowsHitTesting(selectedExtraID == nil)
                ForEach(extras) { extra in
                    extraContent(extra)
                        .opacity(isVisible(extra) ? 1 : 0)
                        .padding(.horizontal, 12)
                        .opacity(selectedExtraID == extra.id ? 1 : 0)
                        .allowsHitTesting(selectedExtraID == extra.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dockCanvas)
        .onAppear { if InAppBrowser.pending != nil { reopen(.browser) } }
        .onReceive(NotificationCenter.default.publisher(for: .hermOpenInBrowser)) { _ in reopen(.browser) }
        .onChange(of: model.navigationSessionID, initial: true) { _, _ in
            if let extra = extras.first(where: { $0.id == selectedExtraID }), !isVisible(extra) { selectedExtraID = nil }
            if !openSections.contains(selectedSection), let first = openSections.first { selectedSection = first }
        }
        .onChange(of: hasSessionGitRepository) { _, hasRepository in
            if !hasRepository, selectedSection == .changes { selectedSection = .activity }
        }
    }

    @ViewBuilder
    private var baseContent: some View {
        if selectedSection == .terminal || selectedSection == .files || selectedSection == .browser {
            inspectorContent
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                inspectorContent
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private func extraContent(_ extra: ExtraTab) -> some View {
        if extra.kind == .browser {
            SessionBrowserView(model: model, isPrimary: false)
        } else {
            SessionTerminalView(
                projectPath: sessionRepositoryPath,
                recipes: VerificationRecipeBuilder.make(facts: control.projectFacts, repository: workflow.repository),
                repositoryID: workflow.repository.isGitRepository ? workflow.repository.repositoryID : nil,
                repositoryFingerprint: workflow.repositoryFingerprint
            )
        }
    }

    /// Opens another Terminal/Browser; the first one reuses the built-in tab.
    private func openNew(_ kind: Section) {
        if !openSections.contains(kind) { return reopen(kind) }
        let sessionID = kind == .browser ? model.navigationSessionID : nil
        let extra = ExtraTab(kind: kind, number: extras.filter { $0.kind == kind && $0.sessionID == sessionID }.count + 2,
                             sessionID: sessionID)
        extras.append(extra)
        selectedExtraID = extra.id
    }

    private func closeExtra(_ extra: ExtraTab) {
        extras.removeAll { $0.id == extra.id }
        if selectedExtraID == extra.id { selectedExtraID = nil }
    }

    /// Changes only makes sense when the session's folder is a Git working tree.
    private var hasSessionGitRepository: Bool {
        guard let sessionRepositoryPath, !sessionRepositoryPath.isEmpty else { return false }
        return workflow.repository.isGitRepository && workflow.repository.path == sessionRepositoryPath
    }

    private var visibleSections: [Section] {
        hasSessionGitRepository ? [.activity, .terminal, .files, .changes, .browser] : [.activity, .terminal, .files, .browser]
    }

    private var browserSessions: [String] { browserSessionsRaw.split(separator: "|").map(String.init) }

    private var isBrowserOpenHere: Bool {
        model.navigationSessionID.map(browserSessions.contains) ?? false
    }

    private func setBrowserOpenHere(_ open: Bool) {
        guard let id = model.navigationSessionID else { return }
        var ids = browserSessions.filter { $0 != id }
        if open { ids.append(id) }
        browserSessionsRaw = ids.suffix(50).joined(separator: "|")  // ponytail: drops the oldest past 50 sessions
    }

    private func isVisible(_ extra: ExtraTab) -> Bool {
        extra.sessionID == nil || extra.sessionID == model.navigationSessionID
    }

    /// Tabs the user hasn't closed; closed ones come back through the + menu.
    /// Browser follows this session's own open state instead of the shared list.
    private var openSections: [Section] {
        let closed = Set(closedRaw.split(separator: "|").map(String.init))
        let open = visibleSections.filter { $0 == .browser ? isBrowserOpenHere : !closed.contains($0.rawValue) }
        return open.isEmpty ? [selectedSection] : open
    }

    private func close(_ section: Section) {
        guard openSections.count > 1 else { return }
        if section == .browser { setBrowserOpenHere(false) } else { closedRaw += "|" + section.rawValue }
        if selectedSection == section, let next = openSections.first(where: { $0 != section }) { selectedSection = next }
    }

    private func reopen(_ section: Section) {
        if section == .browser { setBrowserOpenHere(true) }
        closedRaw = closedRaw.split(separator: "|").filter { $0 != section.rawValue }.joined(separator: "|")
        selectedSection = section
        selectedExtraID = nil
    }

    /// Sits right after the last tab, like a browser's new-tab button.
    private var newTabMenu: some View {
        let closedSections = visibleSections.filter { !openSections.contains($0) }
        return Button { isShowingNewTab.toggle() } label: {
            DockIcon(.plus, size: 14, color: Color.dockPrimaryText)
                .frame(width: 28, height: 28)
                .background(isShowingNewTab ? Color.dockSurface2 : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New tab")
        .accessibilityLabel("New tab")
        .popover(isPresented: $isShowingNewTab, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                newTabRow("New Terminal", icon: .terminal) { openNew(.terminal) }
                newTabRow("New Browser", icon: .globe) { openNew(.browser) }
                ForEach(closedSections.filter { $0 != .terminal && $0 != .browser }) { section in
                    newTabRow(section.navigationTitle, icon: section.icon) { reopen(section) }
                }
            }
            .padding(6)
            .frame(minWidth: 180)
        }
    }

    private func newTabRow(_ title: String, icon: Ph, action: @escaping () -> Void) -> some View {
        Button {
            isShowingNewTab = false
            action()
        } label: {
            HStack(spacing: 8) {
                DockIcon(icon, size: 14, color: Color.dockSecondaryText)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
    }

    private var sessionModePicker: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(openSections) { section in
                        sectionButton(section)
                    }
                    ForEach(extras.filter(isVisible)) { extraButton($0) }
                    if !isCompactStrip { newTabMenu }
                }
                .padding(.horizontal, 10)
            }

            if isCompactStrip { newTabMenu }

            Spacer(minLength: 0)

            if let onToggle {
                DockSidebarToggle(isCollapsed: false, edge: .trailing, action: onToggle)
                .padding(.horizontal, 8)
            }
        }
        .frame(height: headerHeight)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { isCompactStrip = proxy.size.width < 420 }
                    .onChange(of: proxy.size.width) { _, width in isCompactStrip = width < 420 }
            }
        )
        .background(Color.dockSurface2.opacity(0.58))
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    private func sectionButton(_ section: Section) -> some View {
        let isSelected = selectedSection == section && selectedExtraID == nil
        return HStack(spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .dockEase(duration: 0.16)) { selectedSection = section; selectedExtraID = nil }
            } label: {
                HStack(spacing: 6) {
                    DockIcon(section.icon, size: 12, color: isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
                    if isSelected || !isCompactStrip { Text(section.navigationTitle).lineLimit(1) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(section.navigationTitle)
            .accessibilityLabel("Show \(section.rawValue)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isSelected, openSections.count + extras.filter(isVisible).count > 1 {
                Button { close(section) } label: {
                    DockIcon(.x, size: 10, color: Color.dockSecondaryText)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(section.navigationTitle)")
            }
        }
        .font(sessionTabFont)
        .foregroundStyle(isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(isSelected ? Color.dockAccentMuted : hoveredSection == section ? Color.dockSurface2 : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1))
        .fixedSize(horizontal: true, vertical: false)
        .onHover { hoveredSection = $0 ? section : nil }
    }

    private func extraButton(_ extra: ExtraTab) -> some View {
        let isSelected = selectedExtraID == extra.id
        return HStack(spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .dockEase(duration: 0.16)) { selectedExtraID = extra.id }
            } label: {
                HStack(spacing: 6) {
                    DockIcon(extra.kind.icon, size: 12, color: isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
                    if isSelected || !isCompactStrip { Text("\(extra.kind.navigationTitle) \(extra.number)").lineLimit(1) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button { closeExtra(extra) } label: {
                DockIcon(.x, size: 10, color: Color.dockSecondaryText)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(extra.kind.navigationTitle) \(extra.number)")
        }
        .font(sessionTabFont)
        .foregroundStyle(isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(isSelected ? Color.dockAccentMuted : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1))
        .fixedSize(horizontal: true, vertical: false)
    }

    private var inspectorHeader: some View {
        HStack(alignment: .center, spacing: 9) {
            DockIcon(.chats)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentSessionTitle ?? "Untitled session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                if let sessionProjectName {
                    DockIconLabel(sessionProjectName, icon: .folder)
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
            SessionActivityOverviewView(
                model: model,
                control: control,
                botMode: botMode,
                sessionID: model.kanbanSessionID
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
        case .files:
            SessionFilesView(
                projectPath: sessionRepositoryPath,
                onRefresh: { await workflow.refresh(preferences: preferences, control: control) }
            )
        case .changes:
            RepositoryChangesBrowser(
                model: model,
                workflow: workflow,
                projectPath: sessionRepositoryPath,
                onRefresh: { await workflow.refresh(preferences: preferences, control: control) },
                isInspector: true
            )
        case .terminal:
            SessionTerminalView(
                projectPath: sessionRepositoryPath,
                recipes: VerificationRecipeBuilder.make(facts: control.projectFacts, repository: workflow.repository),
                repositoryID: workflow.repository.isGitRepository ? workflow.repository.repositoryID : nil,
                repositoryFingerprint: workflow.repositoryFingerprint
            )
        case .browser:
            SessionBrowserView(model: model)
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
            let icon: Ph
            let label: String
            let value: String
        }

        let items: [TelemetryItem] = [
            focus.branch.map { TelemetryItem(id: "branch", icon: .gitBranch, label: "BRANCH", value: $0) },
            focus.contextPercent.map { TelemetryItem(id: "context", icon: .chartBar, label: "CONTEXT", value: "\(Int($0.rounded()))%") },
            focus.changedFiles.map { TelemetryItem(id: "files", icon: .fileText, label: "CHANGED", value: "\($0) files") }
        ].compactMap { $0 }

        return Group {
            if !items.isEmpty {
                HStack(spacing: 0) {
                    if let branch = items.first(where: { $0.id == "branch" }), workflow.repository.isGitRepository {
                        DockMenu {
                            ForEach(workflow.branches, id: \.self) { branchName in
                                Button {
                                    isSwitchingBranch = true
                                    Task {
                                        _ = await workflow.switchBranch(branchName, preferences: preferences, control: control)
                                        isSwitchingBranch = false
                                    }
                                } label: {
                                    if branchName == workflow.repository.branch {
                                        DockIconLabel(branchName, icon: .check)
                                    } else {
                                        Text(branchName)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                DockIcon(isSwitchingBranch ? .arrowsClockwise : branch.icon)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.dockAccent)
                                Text(branch.value)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.dockPrimaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                DockIcon(.caretDown)
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Color.dockSecondaryText)
                            }
                        }
                        .buttonStyle(.dockHover)
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
                            DockIcon(item.icon)
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
                DockIcon(.shieldCheck)
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
                DockIcon(.warning)
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
