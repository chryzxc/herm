import AppKit
import ServiceManagement
import SwiftUI
import Foundation
import UniformTypeIdentifiers

extension WorkspaceActivitySidebar {
    var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                sidebarHeader
            }

            if showsModePicker {
                modePicker
            }
            if selectedMode == .core {
                settingsWorkspaceContent
            } else if selectedMode == .kanban {
                kanbanContent
            } else if selectedMode == .officePreview {
                officePreviewContent
            } else if selectedMode == .automations {
                AutomationWorkspaceView(control: control)
            } else if selectedMode == .calendar {
                calendarContent
            } else if selectedMode == .capabilities {
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader
                    // ponytail: launch profile only; bots open their own profile from the bot editor.
                    WorkflowIntegrationView(
                        destination: IntegrationDestination(profileID: nil), client: model.controlRPCClient,
                        pageSection: $capabilitySection)
                }
            } else if selectedMode == .messaging {
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader
                    MessagingWorkspaceView(botMode: botMode, client: model.controlRPCClient)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader
                    ScrollView {
                        Group {
                            switch selectedMode {
                            case .changes: changesContent
                            case .automations: automationsContent
                            case .projects: projectsContent
                            case .search: searchContent
                            case .kanban: kanbanContent
                            case .officePreview: officePreviewContent
                            case .core: coreContent
                            case .quota: quotaContent
                            case .usage: UsageWorkspaceView(control: control)
                            // Rendered outside this ScrollView so the calendar can stay pinned.
                            case .calendar, .capabilities, .messaging: EmptyView()
                            }
                        }
                        .frame(maxWidth: readingWidthModes.contains(selectedMode) ? 1280 : .infinity, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                    // Keeps content scrolled past the top from drawing through the title row.
                    .clipped()
                }
            }
        }
        .font(.system(size: 13))
    }

    var pageHeader: some View {
        if selectedMode == .kanban {
            AnyView(DockPageHeader(
                title: selectedMode.pageHeaderTitle,
                subtitle: pageHeaderSubtitle,
                onRefresh: { applyKanbanFilters() },
                isRefreshing: control.isKanbanRefreshPending,
                trailing: { if titleRow != nil { kanbanToolbarControls } }
            ))
        } else if selectedMode == .automations {
            AnyView(DockPageHeader(
                title: selectedMode.pageHeaderTitle,
                subtitle: pageHeaderSubtitle,
                onRefresh: refreshAutomations,
                isRefreshing: automationIsRefreshing,
                trailing: {
                Button(action: { isShowingAutomationComposer = true }) {
                    DockIconLabel("New automation", icon: .plus)
                }
                .buttonStyle(.dockSecondary)
                .controlSize(.small)
                }
            ))
        } else if selectedMode == .core {
            AnyView(DockPageHeader(
                title: selectedMode.pageHeaderTitle,
                subtitle: pageHeaderSubtitle,
                onRefresh: { control.refresh() },
                isRefreshing: control.isRefreshing,
                sidebarCollapsed: $isSettingsRailCollapsed
            ))
        } else if selectedMode == .usage {
            AnyView(DockPageHeader(
                title: selectedMode.pageHeaderTitle,
                subtitle: pageHeaderSubtitle,
                trailing: { if titleRow != nil { UsageToolbar(control: control) } }
            ))
        } else {
            AnyView(DockPageHeader(
                title: selectedMode.pageHeaderTitle,
                subtitle: pageHeaderSubtitle
            ))
        }
    }

    var settingsWorkspaceContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader
            GeometryReader { geometry in
                let layout = SettingsLayoutMode.forWidth(geometry.size.width)
                Group {
                    if layout == .rail, isSettingsRailCollapsed {
                        settingsDetailScroll
                    } else if layout == .rail {
                        HStack(spacing: 0) {
                            settingsCategoryRail
                                .frame(width: 240)
                            Divider().overlay(Color.dockBorderLight)
                            settingsDetailScroll
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            settingsCategoryMenu
                            Divider().overlay(Color.dockBorderLight)
                            settingsDetailScroll
                        }
                    }
                }
            }
        }
        .task {
            model.refreshRuntimeConfiguration()
            model.refreshRuntimeModelOptions()
        }
    }

    var settingsCategoryRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsCategoryGroup.allCases) { group in
                    DockSectionLabel(title: group.rawValue)
                        .padding(.horizontal, 10)
                        .padding(.top, group == .app ? 0 : 16)
                        .padding(.bottom, 6)
                    ForEach(group.categories) { category in
                        settingsCategoryRow(category)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
    }

    var settingsCategoryMenu: some View {
        DockMenuPicker(title: selectedSettingsCategory.title, selection: $selectedSettingsCategory) {
            ForEach(SettingsCategoryGroup.allCases) { group in
                DockMenuSection(group.rawValue) {
                    ForEach(group.categories) { category in
                        DockMenuOption(category.title, value: category)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func settingsCategoryRow(_ category: SettingsCategory) -> some View {
        let badge = settingsCategoryBadge(for: category)
        return DockNavRow(
            title: category.title,
            icon: category.icon,
            isSelected: selectedSettingsCategory == category,
            showsUpdateBadge: badge?.kind == .dot,
            style: DockThemePalette(theme: dockThemeStore.selectedThemeID)
        ) {
            withAnimation(.dockEase(duration: 0.18)) {
                selectedSettingsCategory = category
            }
        }
        .overlay(alignment: .trailing) {
            if let badge, badge.kind != .dot {
                settingsCategoryBadgeView(badge)
                    .padding(.trailing, 10)
                    .allowsHitTesting(false)
            }
        }
        .help(category.subtitle)
    }

    @ViewBuilder
    func settingsCategoryBadgeView(_ badge: SettingsCategoryBadge) -> some View {
        switch badge.kind {
        case .dot:
            Circle()
                .fill(badge.isWarning ? Color.dockWarning : Color.dockAccent)
                .frame(width: 7, height: 7)
        case .count(let count):
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(badge.isWarning ? Color.dockWarning : Color.dockMetadataText)
        }
    }

    func settingsCategoryBadge(for category: SettingsCategory) -> SettingsCategoryBadge? {
        switch category {
        case .updates:
            if case .readyToInstall = appUpdater.phase {
                return SettingsCategoryBadge(kind: .dot, isWarning: true)
            }
            return agentUpdateService.phase == .updateAvailable
                ? SettingsCategoryBadge(kind: .dot, isWarning: true)
                : nil
        case .integrations:
            let count = unavailableSetupCapabilities.count
            return count > 0 ? SettingsCategoryBadge(kind: .count(count), isWarning: true) : nil
        case .session:
            let count = control.attention.filter { $0.state == .open }.count
            return count > 0 ? SettingsCategoryBadge(kind: .count(count), isWarning: true) : nil
        case .general, .gateway, .appearance, .notifications, .runtime, .providers, .chat, .workspace, .safety, .browser, .memory, .voice, .advanced, .diagnostics:
            return nil
        }
    }

    var settingsDetailScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedSettingsCategory.title)
                        .font(DockTypography.pageTitle)
                        .foregroundStyle(Color.dockPrimaryText)
                    Text(selectedSettingsCategory.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockSecondaryText)
                }
                coreContent
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
        }
        .id(selectedSettingsCategory)
    }

    /// Owns its own scrolling: the calendar stays put while the day detail scrolls.
    var calendarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader
            CalendarWorkspaceView(
                control: control,
                repoPaths: calendarRepoPaths,
                botsByID: Dictionary(botMode.bots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                avatarImages: botMode.avatarImages,
                onOpenTask: { task in
                    select(.kanban)
                    control.revealKanbanTask(task)
                },
                onOpenUsage: { select(.usage) }
            )
            .task { await botMode.refreshNow() }
            .padding(.horizontal, 16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    var officeKanbanIsCurrent: Bool {
        control.globalKanbanIsCurrent
    }

    var officePreviewContent: some View {
        OfficePreviewView(
            kanbanTasks: control.globalKanbanTasks,
            bots: botMode.bots,
            mainSessions: officeMainSessions,
            onOpenSession: { id in
                if let session = model.sessions.first(where: { $0.id == id }) { model.resumeSession(session) }
                else if let session = control.activeSessions.first(where: { $0.id == id }) { control.openLatestActivitySession(session) }
            },
            avatarImages: botMode.avatarImages,
            canAssignTasks: control.capabilityAvailable("kanban.assign"),
            isDataCurrent: officeKanbanIsCurrent,
            subtitle: projectionHeaderSubtitle(control.projectionState(for: "kanban.board"), fallback: selectedMode.pageHeaderSubtitle),
            onRefresh: { control.refreshGlobalKanban(); control.refresh(); botMode.refresh() },
            isRefreshing: control.isKanbanRefreshPending
        ) { task, botID in
                guard control.capabilityAvailable("kanban.assign") else { return }
                kanbanMutationRequest = KanbanMutationRequest(task: task, kind: .assign, value: botID, reclaimFirst: false)
        }
        .task { await botMode.refreshNow(force: true) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var officeMainSessions: [OfficeMainSession] {
        let botIDs = Set(botMode.bots.filter { !$0.isDefault }.map(\.id))
        let sessionsCurrent: Bool
        if case .ready = control.projectionState(for: "sessions") { sessionsCurrent = true }
        else { sessionsCurrent = false }
        var summaries = control.activeSessions.filter { session in
            session.profileID.map { !botIDs.contains($0) } ?? true
        }
        if let id = model.sessionID, !summaries.contains(where: { $0.id == id }),
           model.sessionProfileID.map({ !botIDs.contains($0) }) ?? true {
            summaries.append(.init(id: id, title: model.sessions.first(where: { $0.id == id })?.displayTitle ?? "Current conversation", state: "unknown", preview: nil))
        }
        return summaries.map { session in
            let current = session.id == model.sessionID
            let state: String
            if current {
                switch model.status {
                case .working: state = "working"
                case .needsApproval: state = "needs_approval"
                case .needsClarification: state = "needs_clarification"
                case .idle: state = "idle"
                case .offline: state = "offline"
                }
            } else { state = sessionsCurrent ? session.state : "unknown" }
            let activities = control.latestActivities.filter { $0.sessionID == session.id }.prefix(12).map {
                OfficeMainSession.Activity(id: $0.id, name: $0.activityName, timestamp: $0.timestamp)
            }
            return OfficeMainSession(id: session.id, title: session.title, state: state, isCurrent: current, activities: activities)
        }
    }

    var pageHeaderSubtitle: String {
        switch selectedMode {
        case .kanban:
            return projectionHeaderSubtitle(
                control.projectionState(for: "kanban.board"),
                fallback: kanbanHeaderSubtitle
            )
        case .core:
            return projectionHeaderSubtitle(
                model.runtimeConfigurationProjectionState,
                fallback: selectedMode.pageHeaderSubtitle
            )
        case .automations:
            return projectionHeaderSubtitle(
                control.projectionState(for: "cron.jobs"),
                fallback: selectedMode.pageHeaderSubtitle
            )
        default:
            return selectedMode.pageHeaderSubtitle
        }
    }

    var kanbanHeaderSubtitle: String {
        let boardName = control.kanbanBoards.first(where: { $0.slug == control.selectedKanbanBoardSlug })?.name
            ?? control.selectedKanbanBoardSlug
            ?? "Current board"
        let total = control.kanbanBoards.first(where: { $0.slug == control.selectedKanbanBoardSlug })?.total
            ?? control.kanbanTasks.count
        return "\(boardName) · \(control.kanbanTasks.count) of \(total) tasks"
    }

    /// A page header reserves one subtitle line, so projection transitions
    /// never insert a temporary row and shift the page underneath the user.
    func projectionHeaderSubtitle<Value: Equatable & Sendable>(
        _ state: HermesProjectionState<Value>?,
        fallback: String
    ) -> String {
        guard let state else { return fallback }
        switch state {
        case .loading:
            return "Refreshing workspace…"
        case .stale:
            return "Refreshing workspace…"
        case .empty:
            return fallback
        case .unavailable, .failed:
            return "Workspace status is unavailable"
        case .ready:
            return fallback
        }
    }

    var sidebarHeader: some View {
            HStack {
                Spacer()
                Button { isShowingCommandPalette = true } label: {
                    DockIcon(.command)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.dockHover)
                .help("Command palette")
                .keyboardShortcut("k", modifiers: [.command])
                Button(action: onClose) {
                    DockIcon(.caretLeft)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.dockSurface4))
                }
                .buttonStyle(.dockHover)
                .dockHitTarget()
                .help("Return to chat")
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    var observedSidebar: some View {
        sidebarContent
        .background {
            ZStack {
                Color.dockCanvas
                RadialGradient(
                    colors: [Color.dockAccent.opacity(0.055), .clear],
                    center: UnitPoint(x: 0.9, y: 0),
                    startRadius: 0,
                    endRadius: 300
                )
            }
        }
        .fileImporter(isPresented: $showingRepositoryPicker, allowedContentTypes: [.folder], onCompletion: handleRepositoryImport)
        // Repository loading is owned by DockPopover's shared context-panel
        // task so switching Global/Session cannot let this view clear or race
        // the workflow projection. Manual Refresh actions still use the local
        // refreshRepository() path below.
        .task {
            control.bind(to: model)
            control.refresh()
            // The initial tab does not produce an `onChange` event. Load
            // projections only after binding the CLI client, so a directly
            // opened Quota or Kanban tab never misses its first request.
            if selectedMode == .quota {
                control.refreshProviderQuota()
            } else if selectedMode == .usage {
                control.refreshTokenUsage(days: UsageWorkspaceView.storedDays)
            } else if selectedMode == .calendar {
                control.refreshWorkCalendar(month: Date(), repoPaths: calendarRepoPaths)
            } else if selectedMode == .kanban {
                applyKanbanFilters()
            } else if selectedMode == .officePreview {
                control.refreshGlobalKanban()
            }
        }
        .onChange(of: model.status) { _, _ in control.rebuildAttention() }
        .onChange(of: model.approvalText) { _, _ in control.rebuildAttention() }
        .onChange(of: model.sessionID) { _, sessionID in
            sessionSteerFeedback = nil
            control.focus(sessionID: sessionID)
            if sessionID != nil {
                control.refresh()
            }
        }
        .onChange(of: control.projectSessions) { _, sessions in
            guard let path = selectedProjectFolderPath, !sessions.isEmpty else { return }
            store.attachProject(at: path, toSessions: sessions)
        }
        .onChange(of: control.cronJobs) { _, _ in
            reconcileSelectedCronJob()
        }
        .onChange(of: control.capabilities) { _, _ in
            guard selectedMode == .kanban, control.capabilityAvailable("kanban") else { return }
            applyKanbanFilters()
        }
        .onChange(of: selectedMode) { _, mode in
            switch mode {
            case .quota:
                control.refreshProviderQuota()
            case .usage:
                control.refreshTokenUsage(days: UsageWorkspaceView.storedDays)
            case .calendar:
                control.refreshWorkCalendar(month: Date(), repoPaths: calendarRepoPaths)
            case .kanban:
                // Re-apply this surface's visible controls. This prevents a
                // session-only query started from Activity from leaking into
                // a separately opened global board.
                applyKanbanFilters()
            case .officePreview:
                // The office reads the same global Kanban projection as the
                // Kanban page; it never creates or mutates a second task store.
                control.refreshGlobalKanban()
            case .automations:
                control.refresh()
                control.refreshCronRuns()
                reconcileSelectedCronJob()
            default:
                break
            }
        }
        .onChange(of: model.runtimeConfiguration) { _, _ in
            guard selectedMode == .quota else { return }
            control.refreshProviderQuota()
        }
        .onChange(of: model.observedKanbanTaskRevision) { _, _ in
            // Keep the board in step with an exact `kanban show <id>` tool
            // event. The task may not carry a durable session_id, so waiting
            // for a session-filtered list would leave the board falsely empty.
            if selectedMode == .officePreview { control.refreshGlobalKanban() }
            else if selectedMode == .kanban { applyKanbanFilters(trigger: .background) }
        }
        .task(id: selectedMode == .quota) {
            guard selectedMode == .quota else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, selectedMode == .quota else { return }
                control.refreshProviderQuota()
            }
        }
        .onChange(of: searchQuery) { _, query in
            guard selectedMode == .search else { return }
            control.search(query)
        }

    }

    var modePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
            ForEach(compactRailLeading) { compactModeButton($0) }

            compactTabButton(title: "Artifacts", icon: .fileMagnifyingGlass, isSelected: false) {
                onOpenArtifacts()
            }

            ForEach(compactRailTrailing) { compactModeButton($0) }

            DockMenu {
                DockMenuSection("More") {
                    ForEach(compactOverflowNavigation) { mode in
                        secondaryModeButton(mode)
                    }
                }
            } label: {
                compactTabLabel(
                    title: "More",
                    icon: .dotsThreeCircle,
                    detail: isToolsModeSelected ? selectedMode.tabLabel : nil,
                    badgeCount: toolsBadgeCount,
                    isUrgent: toolsBadgeIsUrgent,
                    isSelected: isToolsModeSelected
                )
            }
            .buttonStyle(.dockHover)
            .help(isToolsModeSelected ? selectedMode.tabLabel : "More control views")
        }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    func compactTabButton(
        title: String,
        icon: Ph,
        count: Int = 0,
        isUrgent: Bool = false,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            compactTabLabel(
                title: title,
                icon: icon,
                detail: nil,
                badgeCount: count,
                isUrgent: isUrgent,
                isSelected: isSelected
            )
        }
        .buttonStyle(.dockHover)
    }

    func compactTabLabel(
        title: String,
        icon: Ph,
        detail: String?,
        badgeCount: Int,
        isUrgent: Bool,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 6) {
            DockIcon(icon)
                .font(.system(size: 11, weight: .semibold))
            Text(detail ?? title)
                .lineLimit(1)
            if badgeCount > 0 {
                badgeView(count: badgeCount, isUrgent: isUrgent)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(isSelected ? Color.dockAccent.opacity(0.14) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .contentShape(Rectangle())
    }

    struct CompactProjectGroup: Identifiable {
        let id: String
        let title: String
        let sessions: [HermesSession]
    }

    var compactSortedSessions: [HermesSession] {
        model.sessions.sorted { ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast) }
    }

    var compactProjectGroups: [CompactProjectGroup] {
        control.projects
            .filter { $0.name != "__no_project__" }
            .map { project in
                let sessions = compactSortedSessions.filter {
                    project.sessionIDs.contains($0.id) || control.projectIDBySessionID[$0.id] == project.id
                }
                let name = URL(fileURLWithPath: project.name).lastPathComponent
                return CompactProjectGroup(id: project.id, title: name.isEmpty ? project.name : name, sessions: sessions)
            }
            .filter { !$0.sessions.isEmpty }
            .sorted { ($0.sessions.first?.lastUpdatedAt ?? .distantPast) > ($1.sessions.first?.lastUpdatedAt ?? .distantPast) }
    }

    /// Compact mode mirrors the fullscreen rail's daily operator destinations.
    /// Repository and setup surfaces remain available from More.
    var compactRailLeading: [ControlTab] {
        [.kanban, .calendar, .automations, .capabilities].filter { $0 != .kanban || showsKanbanInSidebar }.filter { $0 != .calendar || showsCalendarInSidebar }
    }

    var compactRailTrailing: [ControlTab] {
        [.officePreview, .usage, .quota, .core].filter { $0 != .officePreview || showsOfficeInSidebar }
    }

    func compactModeButton(_ mode: ControlTab) -> some View {
        compactTabButton(
            title: mode.globalRailLabel,
            icon: mode.icon,
            count: badgeCount(for: mode),
            isUrgent: badgeIsUrgent(for: mode),
            isSelected: selectedMode == mode
        ) {
            select(mode)
        }
    }

    /// Every repository Herm has attached to a session, for the Calendar's git log.
    var calendarRepoPaths: [String] {
        Array(Set(store.tasks.compactMap(\.projectPath) + [store.projectPath].compactMap { $0 }))
    }

    var compactOverflowNavigation: [ControlTab] {
        [.projects, .changes, .search]
    }

    var isToolsModeSelected: Bool {
        compactOverflowNavigation.contains(selectedMode)
    }

    var toolsBadgeCount: Int {
        compactOverflowNavigation.reduce(0) { $0 + badgeCount(for: $1) }
    }

    var toolsBadgeIsUrgent: Bool {
        compactOverflowNavigation.contains(where: badgeIsUrgent(for:))
    }

    func navigationMenuLabel(
        title: String,
        detail: String?,
        badgeCount: Int,
        isUrgent: Bool,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 8) {
            DockIcon(.dotsThreeCircle)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, alignment: .center)
            Text(detail ?? title)
                .lineLimit(1)
            if badgeCount > 0 {
                badgeView(count: badgeCount, isUrgent: isUrgent)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(isSelected ? Color.dockAccent.opacity(0.14) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .contentShape(Rectangle())
    }

    func secondaryModeButton(_ mode: ControlTab) -> some View {
        Button { select(mode) } label: {
            HStack {
                DockIconLabel(mode.tabLabel, icon: mode.icon)
                if badgeCount(for: mode) > 0 {
                    Text(badgeLabel(for: mode))
                }
                if selectedMode == mode {
                    DockIcon(.check)
                }
            }
        }
    }

    func modeButton(_ mode: ControlTab) -> some View {
        Button { select(mode) } label: {
            HStack(spacing: 8) {
                DockIcon(mode.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, alignment: .center)
                Text(mode.globalRailLabel)
                    .lineLimit(1)
                if badgeCount(for: mode) > 0 {
                    badgeView(count: badgeCount(for: mode), isUrgent: badgeIsUrgent(for: mode))
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(selectedMode == mode ? Color.dockPrimaryText : Color.dockSecondaryText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(selectedMode == mode ? Color.dockAccent.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
    }

    func badgeView(count: Int, isUrgent: Bool) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 12, weight: .bold))
            .monospacedDigit()
            .tracking(0)
            .foregroundStyle(isUrgent ? Color.dockOnAccentText : Color.dockPrimaryText)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 4)
            .background(Capsule().fill(isUrgent ? Color.dockWarning : Color.dockAccent.opacity(0.85)))
    }

    func select(_ mode: ControlTab) {
        withAnimation(.dockEase(duration: 0.2)) { selectedMode = mode }
        if mode == .core {
            model.refreshRuntimeConfiguration()
            control.refresh(forceCapabilities: true)
        }
        if mode == .automations { control.refresh(); control.refreshCronRuns() }
        if mode == .projects {
            control.refresh()
            Task { await refreshRepository() }
        }
        if mode == .search { control.search(searchQuery) }
        // Always derive the request from this surface's visible controls. A
        // direct refresh can retain the session filter set by Activity, then
        // make the global board look empty while active cards exist.
        if mode == .kanban { applyKanbanFilters() }
        if mode == .changes { Task { await refreshRepository() } }
    }

    func run(_ command: DockAction) {
        switch command {
        case .tab(let tab): select(tab)
        case .newChat: model.newChat(); model.requestComposerFocus()
        case .focusComposer: model.requestComposerFocus()
        case .stop: model.stop()
        case .voice: model.startVoiceConversation()
        case .refresh:
            control.refresh(forceCapabilities: true)
            Task { await refreshRepository() }
        case .artifacts: onOpenArtifacts()
        case .restartDock: isShowingDockRestartConfirmation = true
        case .workflow(let recipe):
            guard !recipe.requiresRepository || activeRepositoryPath != nil else { return }
            let repositoryContext = activeRepositoryPath.map { " Repository: \($0)." } ?? ""
            Task { _ = await control.startBackgroundTask(recipe.prompt + repositoryContext) }
        }
    }
}
