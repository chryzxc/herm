import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceActivitySidebar {
    var kanbanContent: some View {
        VStack(spacing: 0) {
            pageHeader
            AdaptiveSplit(breakpoint: 940, primaryMinWidth: 560, showsSecondary: selectedKanbanTask != nil, onBack: nil)
            {
                // Header and toolbar stay fixed; the board takes the remaining
                // height so each lane scrolls its own cards.
                VStack(alignment: .leading, spacing: 0) {

                    VStack(alignment: .leading, spacing: 12) {
                        if titleRow == nil { kanbanToolbar }

                        if control.capabilityAvailable("kanban.create"), !kanbanCurrentSessionOnly,
                            isShowingKanbanComposer
                        {
                            createKanbanTaskForm
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        } else if kanbanCurrentSessionOnly {
                            DockIconLabel(
                                "Session cards must be created by a session-aware Kanban worker. Manual CLI cards are global.",
                                icon: .link
                            )
                            .dockFont(.compactStatus, weight: .regular)
                            .foregroundStyle(Color.dockMetadataText)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        if !control.kanbanDiagnostics.isEmpty {
                            DisclosureGroup(isExpanded: $isKanbanHealthExpanded) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(control.kanbanDiagnostics) { diagnostic in
                                        Button {
                                            if let taskID = diagnostic.taskID,
                                                let task = control.kanbanTasks.first(where: { $0.id == taskID })
                                            {
                                                selectKanbanTask(task)
                                            }
                                        } label: {
                                            HStack(spacing: 6) {
                                                Text(diagnostic.severity.uppercased())
                                                    .foregroundStyle(
                                                        diagnostic.severity.lowercased() == "error"
                                                            ? Color.dockDestructive : Color.dockWarning)
                                                Text(diagnostic.title)
                                                    .foregroundStyle(Color.dockSecondaryText)
                                                    .lineLimit(1)
                                                Spacer()
                                                if diagnostic.taskID != nil { DockIcon(.caretRight) }
                                            }
                                            .dockFont(.metadata)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .dockPadding(.vertical, 5)
                                        }
                                        .buttonStyle(.dockHover)
                                        .disabled(diagnostic.taskID == nil)
                                    }
                                }
                                .dockPadding(.top, 5)
                            } label: {
                                HStack(spacing: 7) {
                                    DockIcon(.stethoscope)
                                        .foregroundStyle(Color.dockWarning)
                                    Text("Kanban health")
                                        .dockFont(.metadata, weight: .semibold)
                                    Text("\(control.kanbanDiagnostics.count)")
                                        .dockFont(.compactStatus, weight: .regular, design: .monospaced)
                                        .foregroundStyle(Color.dockMetadataText)
                                    Spacer()
                                    DockMenu(kanbanDiagnosticSeverity) {
                                        ForEach(["ALL", "ERROR", "WARNING", "INFO"], id: \.self) { severity in
                                            Button(severity) {
                                                kanbanDiagnosticSeverity = severity
                                                control.refreshKanbanDiagnostics(
                                                    severity: severity == "ALL" ? nil : severity.lowercased())
                                            }
                                        }
                                    }
                                    .dockFont(.compactStatus, weight: .regular)
                                    Button {
                                        control.refreshKanbanDiagnostics(
                                            severity: kanbanDiagnosticSeverity == "ALL"
                                                ? nil : kanbanDiagnosticSeverity.lowercased())
                                    } label: {
                                        DockIcon(.arrowsClockwise)
                                    }
                                    .buttonStyle(.dockHover)
                                    .foregroundStyle(Color.dockAccent)
                                }
                            }
                            .disclosureGroupStyle(DockDisclosureGroupStyle())
                            .dockPadding(.horizontal, 10)
                            .dockPadding(.vertical, 7)
                            .background(Color.dockWarning.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
                        }

                        if control.kanbanTasks.isEmpty, control.refreshState(for: "kanban.board")?.lastSuccess == nil,
                            control.isKanbanRefreshPending
                                || control.refreshState(for: "kanban.board")?.isRefreshing == true
                        {
                            DockLoadingState(title: "Loading board…", detail: "Reading Kanban tasks from Hermes.")
                        } else {
                            kanbanBoard
                                .frame(maxHeight: .infinity)
                        }
                        if let state = control.refreshState(for: "kanban.board"), let error = state.error {
                            HStack(alignment: .top, spacing: 8) {
                                DockIcon(.warning)
                                    .dockFont(.body, weight: .medium)
                                Text(state.isStale ? "Showing the last successful board. \(error)" : error)
                                    .dockFont(.navigation)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(Color.dockWarning)
                            .dockPadding(.horizontal, 10)
                            .dockPadding(.vertical, 9)
                            .background(Color.dockWarning.opacity(0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).stroke(
                                    Color.dockWarning.opacity(0.34), lineWidth: 0.5)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
                        }
                    }
                    .dockPadding(.horizontal, 16)
                    .dockPadding(.bottom, 12)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: control.requestedKanbanTask, initial: true) { _, task in
                    guard let task else { return }
                    control.requestedKanbanTask = nil
                    kanbanStatusFilter = "All"
                    kanbanAssigneeFilter = "All"
                    kanbanMineOnly = false
                    kanbanCurrentSessionOnly = false
                    applyKanbanFilters()
                    selectKanbanTask(task)
                }
                .onChange(of: control.kanbanTasks.map(\.id)) { _, ids in
                    // Board navigation clears the old list while fetching the new
                    // board. Keep a notch-selected card through that transition.
                    if ids.isEmpty, control.isKanbanRefreshPending { return }
                    if let selectedKanbanTask, !ids.contains(selectedKanbanTask.id) {
                        self.selectedKanbanTask = nil
                    }
                }

            } secondary: {
                if let task = selectedKanbanTask {
                    // Bot lookup only; card details are not needed by the inspector.
                    kanbanDetailPanel(
                        task,
                        presentation: KanbanBoardPresentation.makeSnapshot(
                            tasks: [],
                            bots: botMode.bots,
                            visibleBots: botMode.visibleBots
                        )
                    )
                    .animation(.dockEase(duration: 0.2), value: selectedKanbanTask?.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: selectedMode == .kanban && hostVisible) {
            guard selectedMode == .kanban && hostVisible else { return }
            applyKanbanFilters(trigger: .background)
            while !Task.isCancelled {
                let hasLiveCards = control.kanbanTasks.contains {
                    ["running", "claimed", "in_progress", "blocked", "review", "waiting"].contains(
                        $0.status.lowercased())
                }
                try? await Task.sleep(for: hasLiveCards ? .seconds(5) : .seconds(15))
                guard !Task.isCancelled, selectedMode == .kanban else { return }
                applyKanbanFilters(trigger: .background)
            }
        }
    }

    var kanbanBoard: some View {
        KanbanBoardView(
            tasks: control.kanbanTasks,
            bots: botMode.bots,
            visibleBots: botMode.visibleBots,
            avatarImages: botMode.avatarImages,
            selectedTaskID: selectedKanbanTask?.id,
            actions: KanbanCardActionAvailability(
                details: true,
                complete: control.canMutateKanbanTask(.complete),
                block: control.canMutateKanbanTask(.block),
                unblock: control.canMutateKanbanTask(.unblock),
                archive: control.canMutateKanbanTask(.archive),
                move: control.canMoveKanbanTasks,
                assign: control.capabilityAvailable("kanban.reassign")
            ),
            pendingActionIDs: control.pendingActionIDs.filter { id in
                Self.kanbanCardActionPrefixes.contains { id.hasPrefix($0) }
            },
            loadingDetailTaskID: control.loadingKanbanDetailTaskID,
            onSelect: { selectKanbanTask($0) },
            onAction: { requestKanbanAction($0, action: $1) },
            onDrop: { dropKanbanTask($0, on: $1) },
            onAssign: { control.assignKanbanTask($0, to: $1) }
        )
        .equatable()
    }

    var kanbanToolbar: some View {
        kanbanToolbarControls
            .dockPadding(.horizontal, 10)
            .dockPadding(.vertical, 8)
            .dockPaneTint(Color.dockSurface.opacity(0.28))
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    var kanbanToolbarControls: some View {
        HStack(spacing: 8) {
            DockMenu {
                if control.kanbanBoards.isEmpty {
                    Text("Board inventory unavailable")
                } else {
                    ForEach(control.kanbanBoards.filter { !$0.archived }) { board in
                        Button {
                            control.selectKanbanBoard(board)
                            selectedKanbanTask = nil
                        } label: {
                            HStack {
                                Text(board.name)
                                if board.slug == control.selectedKanbanBoardSlug {
                                    Spacer()
                                    Ph.check.image()
                                }
                            }
                        }
                    }
                }
            } label: {
                kanbanToolbarChip(
                    control.kanbanBoards.first(where: { $0.slug == control.selectedKanbanBoardSlug })?.name
                        ?? control.selectedKanbanBoardSlug
                        ?? "Current board",
                    icon: .kanban
                )
            }
            .buttonStyle(.dockHover)
            .fixedSize()
            .disabled(control.kanbanBoards.count < 2 || control.isKanbanRefreshPending)
            .help("Select Kanban board")

            kanbanFilterControls

            if kanbanFiltersAreActive {
                Button {
                    kanbanStatusFilter = "All"
                    kanbanAssigneeFilter = "All"
                    kanbanMineOnly = false
                    kanbanSort = "updated"
                    applyKanbanFilters()
                } label: {
                    HStack(spacing: 4) {
                        DockIcon(.xCircle, weight: .fill)
                        Text("Clear")
                    }
                    .dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(Color.dockAccent)
                }
                .buttonStyle(.dockSecondary)
                .help("Clear Kanban filters")
            }

            Spacer(minLength: 8)

            if control.capabilityAvailable("kanban.create"), !kanbanCurrentSessionOnly {
                Button {
                    withAnimation(.dockEase(duration: 0.2)) {
                        isShowingKanbanComposer.toggle()
                    }
                } label: {
                    DockIconLabel(
                        isShowingKanbanComposer ? "Close" : "Add task", icon: isShowingKanbanComposer ? .x : .plus)
                }
                .buttonStyle(.dockPrimary)
                .dockFont(.metadata, weight: .semibold)
            }
        }
    }

    var kanbanFiltersAreActive: Bool {
        kanbanStatusFilter != "All" || kanbanAssigneeFilter != "All" || kanbanMineOnly || kanbanSort != "updated"
    }

    func kanbanToolbarChip(_ title: String, icon: Ph) -> some View {
        HStack(spacing: 5) {
            DockIcon(icon)
                .dockFont(.compactStatus, weight: .semibold)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            DockIcon(.caretDown)
                .dockFont(size: 8, weight: .bold)
        }
        .dockFont(.metadata, weight: .semibold)
        .foregroundStyle(Color.dockSecondaryText)
        .dockPadding(.horizontal, 8)
        .dockPadding(.vertical, 6)
        .background(Capsule().dockSurfaceFill(Color.dockSurface2.opacity(0.76)))
        .clipShape(Capsule())
    }

    var kanbanFilterControls: some View {
        HStack(spacing: 6) {
            Button {
                isShowingKanbanStatusFilter.toggle()
            } label: {
                kanbanFilterChip(kanbanStatusFilter == "All" ? "Status" : kanbanStatusFilter, icon: .funnelSimple)
            }
            .dockPopover(isPresented: $isShowingKanbanStatusFilter, arrowEdge: .bottom) {
                kanbanStatusPopover
            }
            Button {
                isShowingKanbanAssigneeFilter.toggle()
            } label: {
                kanbanFilterChip(kanbanAssigneeFilter == "All" ? "Assignee" : kanbanAssigneeFilter, icon: .users)
            }
            .dockPopover(isPresented: $isShowingKanbanAssigneeFilter, arrowEdge: .bottom) {
                kanbanAssigneePopover
            }
            Button {
                kanbanMineOnly.toggle()
                applyKanbanFilters()
            } label: {
                kanbanFilterChip("Mine", icon: .user, isSelected: kanbanMineOnly)
            }
            DockMenu {
                ForEach(["updated", "created-desc", "priority-desc", "title"], id: \.self) { value in
                    Button(kanbanSortLabel(value)) {
                        kanbanSort = value
                        applyKanbanFilters()
                    }
                }
            } label: {
                kanbanFilterChip(kanbanSort == "updated" ? "Sort" : kanbanSortLabel(kanbanSort), icon: .arrowsDownUp)
            }
            .fixedSize()
        }
        .buttonStyle(.dockHover)
        .dockFont(.metadata, weight: .semibold)
        .disabled(control.isKanbanRefreshPending)
    }

    var kanbanAssigneeOptions: [String] {
        Set(
            control.kanbanAssignees
                + control.kanbanTasks.compactMap { task in
                    guard let assignee = task.assignee?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !assignee.isEmpty
                    else { return nil }
                    return assignee
                }
        ).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func kanbanSortLabel(_ value: String) -> String {
        switch value {
        case "created-desc": "Created"
        case "priority-desc": "Priority"
        case "title": "Title"
        default: "Updated"
        }
    }

    func kanbanFilterChip(_ title: String, icon: Ph, isSelected: Bool = false) -> some View {
        HStack(spacing: 6) {
            DockIcon(icon)
                .dockFont(.metadata, weight: .semibold)
            Text(title)
                .lineLimit(1)
            DockIcon(.caretDown)
                .dockFont(size: 8, weight: .bold)
        }
        .foregroundStyle(isSelected ? Color.dockAccent : Color.dockSecondaryText)
        .dockPadding(.horizontal, 9)
        .dockPadding(.vertical, 7)
        .background(isSelected ? Color.dockAccent.opacity(0.14) : Color.dockSurface.opacity(0.72))
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(isSelected ? Color.dockAccent.opacity(0.28) : Color.dockBorderLight, lineWidth: 0.5)
        }
    }

    var kanbanStatusPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                DockIcon(.circlesFour)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockAccent)
                Text("STATUS")
                    .dockFont(.metadata, weight: .bold)
                    .tracking(0.9)
                    .foregroundStyle(Color.dockMetadataText)
                Spacer()
                Text("\(KanbanLane.allCases.count)")
                    .dockFont(.compactStatus, weight: .semibold, design: .monospaced)
                    .foregroundStyle(Color.dockMetadataText)
            }
            .dockPadding(.horizontal, 12)
            .dockPadding(.vertical, 11)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView {
                LazyVStack(spacing: 3) {
                    kanbanStatusRow(nil, title: "All statuses", isSelected: kanbanStatusFilter == "All")
                    ForEach(KanbanLane.allCases) { lane in
                        kanbanStatusRow(lane, title: lane.rawValue, isSelected: kanbanStatusFilter == lane.rawValue)
                    }
                }
                .dockPadding(8)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 270)
        .background(Color.dockCanvas)
    }

    func kanbanStatusRow(_ lane: KanbanLane?, title: String, isSelected: Bool) -> some View {
        Button {
            kanbanStatusFilter = lane?.rawValue ?? "All"
            isShowingKanbanStatusFilter = false
            applyKanbanFilters()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill((lane?.color ?? Color.dockAccent).opacity(0.18))
                    if let lane {
                        DockIcon(lane.icon)
                            .foregroundStyle(lane.color)
                    } else {
                        DockIcon(.circlesFour)
                            .dockFont(.metadata, weight: .semibold)
                            .foregroundStyle(Color.dockAccent)
                    }
                }
                .frame(width: 30, height: 30)
                Text(title)
                    .dockFont(.navigation, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    DockIcon(.check)
                        .dockFont(.body, weight: .bold)
                        .foregroundStyle(Color.dockAccent)
                }
            }
            .dockPadding(.horizontal, 8)
            .dockPadding(.vertical, 5)
            .background(isSelected ? Color.dockAccent.opacity(0.11) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
    }

    var kanbanAssigneePopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                DockIcon(.users)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockAccent)
                Text("ASSIGNEE")
                    .dockFont(.metadata, weight: .bold)
                    .tracking(0.9)
                    .foregroundStyle(Color.dockMetadataText)
                Spacer()
                Text("\(kanbanAssigneeOptions.count)")
                    .dockFont(.compactStatus, weight: .semibold, design: .monospaced)
                    .foregroundStyle(Color.dockMetadataText)
            }
            .dockPadding(.horizontal, 12)
            .dockPadding(.vertical, 11)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView {
                LazyVStack(spacing: 3) {
                    kanbanAssigneeRow("All", isSelected: kanbanAssigneeFilter == "All")
                    ForEach(kanbanAssigneeOptions, id: \.self) { assignee in
                        kanbanAssigneeRow(assignee, isSelected: kanbanAssigneeFilter == assignee)
                    }
                }
                .dockPadding(8)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 270)
        .background(Color.dockCanvas)
    }

    func kanbanAssigneeRow(_ assignee: String, isSelected: Bool) -> some View {
        Button {
            kanbanAssigneeFilter = assignee
            isShowingKanbanAssigneeFilter = false
            applyKanbanFilters()
        } label: {
            HStack(spacing: 10) {
                if assignee == "All" {
                    ZStack {
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous)
                            .fill(Color.dockAccent.opacity(0.18))
                        DockIcon(.users)
                            .dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockAccent)
                    }
                    .frame(width: 30, height: 30)
                } else {
                    if let bot = botMode.visibleBots.first(where: {
                        $0.id.caseInsensitiveCompare(assignee) == .orderedSame
                    }) {
                        BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: 30)
                    } else {
                        KanbanAssigneeInitialAvatar(assignee: assignee)
                    }
                }
                Text(assignee == "All" ? "All assignees" : assignee)
                    .dockFont(.navigation, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    DockIcon(.check)
                        .dockFont(.body, weight: .bold)
                        .foregroundStyle(Color.dockAccent)
                }
            }
            .dockPadding(.horizontal, 8)
            .dockPadding(.vertical, 5)
            .background(isSelected ? Color.dockAccent.opacity(0.11) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
    }

    func applyKanbanFilters(
        trigger: ControlCenterModel.KanbanRefreshTrigger = .user
    ) {
        control.refreshVisibleKanban(
            filter: KanbanListFilter(
                status: kanbanStatusFilter == "All" ? nil : kanbanStatusFilter.lowercased(),
                assignee: kanbanAssigneeFilter == "All" ? nil : kanbanAssigneeFilter,
                mine: kanbanMineOnly,
                sessionID: kanbanCurrentSessionOnly ? model.kanbanSessionID : nil,
                sort: kanbanSort
            ), trigger: trigger)
    }

    var createKanbanTaskForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DockIcon(.plus)
                    .dockFont(.metadata, weight: .bold)
                    .foregroundStyle(Color.dockAccent)
                Text("ADD TASK")
                    .dockFont(.body, weight: .semibold)
                    .tracking(1.1)
                    .foregroundStyle(Color.dockSecondaryText)
            }
            HStack(spacing: 8) {
                dockTextField("What needs to be done?", text: $kanbanTitle)
                Button {
                    isShowingKanbanConfirmation = true
                } label: {
                    Group {
                        if control.isCreatingKanbanTask {
                            ProgressView().controlSize(.small).tint(Color.dockPrimaryText)
                        } else {
                            DockIcon(.arrowUpRight)
                                .dockFont(.navigation, weight: .bold)
                        }
                    }
                }
                .buttonStyle(.dockPrimary)
                .opacity(canCreateKanbanTask && !control.isCreatingKanbanTask ? 1 : 0.42)
                .disabled(!canCreateKanbanTask || control.isCreatingKanbanTask)
                .help("Create task")
            }
            .dockButtonSize(.standard)
            DockTextField("Add context for Herm (optional)", text: $kanbanBody, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .dockFont(.navigation)
                .foregroundStyle(Color.dockPrimaryText)
                .dockPadding(.horizontal, 10)
                .dockPadding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(
                        Color.dockSurface)
                )
                .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        }
        .dockCard(padding: 12)
    }

    func selectKanbanTask(_ task: KanbanTaskSummary) {
        selectedKanbanTask = task
        kanbanInspectorTab = .overview
        control.loadKanbanTask(task)
    }

    /// Done and Blocked release a worker claim, so a drop there goes through
    /// the same confirmation as the card menu; other lanes move immediately.
    func dropKanbanTask(_ task: KanbanTaskSummary, on lane: KanbanLane) {
        // Lanes a card cannot enter already refuse the drag with the
        // forbidden cursor, so `.none` and `.refused` never reach here.
        switch KanbanBoardPresentation.dropOutcome(taskStatus: task.status, target: lane) {
        case .move(let lane):
            control.moveKanbanTask(task, to: lane)
        case .confirm(let action):
            requestKanbanAction(task, action: action)
        case .none, .refused:
            break
        }
    }

    func requestKanbanAction(_ task: KanbanTaskSummary, action: KanbanTaskAction) {
        kanbanChangeRequest = KanbanChangeRequest(task: task, action: action)
        isShowingKanbanChangeConfirmation = true
    }

    func kanbanMetadataPill(_ value: String, tint: Color) -> some View {
        Text(value)
            .dockFont(.compactStatus, weight: .semibold)
            .foregroundStyle(tint)
            .lineLimit(1)
            .dockPadding(.horizontal, 7)
            .dockPadding(.vertical, 4)
            .background(tint.opacity(0.10))
            .clipShape(Capsule())
    }

    func kanbanAssigneePill(
        _ assignee: String,
        presentation: KanbanBoardPresentation.Snapshot
    ) -> some View {
        HStack(spacing: 5) {
            if let bot = presentation.visibleBot(for: assignee) {
                BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: 18)
            } else {
                KanbanAssigneeInitialAvatar(assignee: assignee, size: 18)
            }
            Text(assignee)
                .lineLimit(1)
        }
        .dockFont(.compactStatus, weight: .semibold)
        .foregroundStyle(Color.dockSecondaryText)
        .dockPadding(.leading, 3)
        .dockPadding(.trailing, 8)
        .dockPadding(.vertical, 3)
        .background(Color.dockSecondaryText.opacity(0.10))
        .clipShape(Capsule())
    }

    func kanbanModelMetadataRow(_ metadata: KanbanModelMetadataPresentation) -> some View {
        HStack(spacing: 5) {
            DockIcon(metadata.isOverride ? .arrowsClockwise : .cpu)
                .dockFont(.metadata, weight: .semibold)
            Text(metadata.isOverride ? "OVERRIDE · \(metadata.label)" : metadata.label)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .dockFont(.compactStatus, weight: .medium, design: .monospaced)
        .foregroundStyle(metadata.isOverride ? Color.dockWarning : Color.dockMetadataText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func isRedundantKanbanStatus(_ event: String, for lane: KanbanLane) -> Bool {
        let normalizedEvent =
            event
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        let normalizedLane = lane.rawValue.lowercased()
        return normalizedEvent == normalizedLane
            || (lane == .done && ["complete", "completed", "archived"].contains(normalizedEvent))
            || (lane == .blocked && ["failed", "error"].contains(normalizedEvent))
    }

    func kanbanDetailPanel(
        _ task: KanbanTaskSummary,
        presentation: KanbanBoardPresentation.Snapshot
    ) -> some View {
        let lane = KanbanBoardPresentation.lane(for: task.status)
        let laneColor = lane.color

        let detail =
            control.kanbanDetail ?? ControlCenterModel.fallbackKanbanTaskDetail(task, boardSlug: task.boardSlug)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(detail.title)
                        .dockFont(.pageTitle, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(3)
                    HStack(spacing: 7) {
                        Text(detail.id)
                            .dockFont(.compactStatus, weight: .regular, design: .monospaced)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    .dockFont(.metadata, weight: .medium)
                }
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    DockMenu {
                        kanbanDetailActions(task, lane: lane)
                    } label: {
                        kanbanDetailHeaderIcon(.dotsThree)
                    }
                    // `.borderlessButton` drops custom labels on macOS, leaving only the indicator.
                    .buttonStyle(.dockHover)
                    .fixedSize()
                    .help("Task actions")
                    .accessibilityLabel("Task actions")
                    Button {
                        selectedKanbanTask = nil
                    } label: {
                        kanbanDetailHeaderIcon(.x)
                    }
                    .buttonStyle(.dockHover)
                    .help("Close")
                    .accessibilityLabel("Close task details")
                }
            }
            .foregroundStyle(Color.dockSecondaryText)
            .dockPadding(.horizontal, 16)
            .dockPadding(.top, 16)
            .dockPadding(.bottom, 12)

            HStack(spacing: 0) {
                ForEach(KanbanInspectorTab.allCases) { tab in
                    Button(tab.rawValue) { kanbanInspectorTab = tab }
                        .dockFont(.metadata, weight: .semibold)
                        .foregroundStyle(kanbanInspectorTab == tab ? Color.dockPrimaryText : Color.dockMetadataText)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .overlay(alignment: .bottom) {
                            if kanbanInspectorTab == tab { Color.dockAccent.frame(height: 2) }
                        }
                        .buttonStyle(.dockHover)
                }
            }
            .overlay(alignment: .top) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = control.kanbanDetailError, !error.isEmpty {
                        HStack(spacing: 8) {
                            DockIcon(.warning)
                            Text(error).lineLimit(3)
                            Spacer()
                            Button("Retry") { control.loadKanbanTask(task) }
                                .buttonStyle(.dockCompact)
                        }
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockWarning)
                    }
                    if control.loadingKanbanDetailTaskID == task.id {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Refreshing task details…")
                        }
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                    }

                    if kanbanInspectorTab == .overview {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 7) {
                                kanbanMetadataPill(detail.status.capitalized, tint: laneColor)
                                if let priority = detail.priority {
                                    kanbanMetadataPill("P\(priority)", tint: .dockSecondaryText)
                                }
                                if let assignee = detail.assignee {
                                    kanbanAssigneePill(assignee, presentation: presentation)
                                }
                            }
                            kanbanModelMetadataRow(
                                KanbanModelMetadataPresentation.make(
                                    taskModel: detail.modelOverride ?? task.modelOverride,
                                    taskProvider: detail.providerOverride ?? task.providerOverride,
                                    bot: presentation.bot(for: detail.assignee ?? task.assignee)
                                ))
                            if let why = detail.blockExplanation { kanbanBlockExplanation(why) }
                            if let body = detail.body, !body.isEmpty {
                                Text("Description")
                                    .dockFont(.body, weight: .semibold)
                                    .foregroundStyle(Color.dockPrimaryText)
                                    .dockPadding(.top, 4)
                                MarkdownMessageView(markdown: body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text("No task description returned.")
                                    .dockFont(.body)
                                    .foregroundStyle(Color.dockMetadataText)
                            }
                            if !control.kanbanAttachments.isEmpty {
                                kanbanAttachmentSection
                            }
                        }
                    } else {
                        kanbanActivitySection(detail)
                            .task(id: "\(detail.id):\(hostVisible)") {
                                guard hostVisible else { return }
                                // ponytail: 4s poll of `kanban show`; Hermes has no per-task push stream.
                                while !Task.isCancelled, !["done", "archived"].contains(task.status.lowercased()) {
                                    try? await Task.sleep(for: .seconds(4))
                                    if Task.isCancelled { break }
                                    await control.refreshKanbanTaskQuietly(task)
                                }
                            }
                    }
                }
                .dockPadding(20)
                .frame(maxWidth: kanbanInspectorTab == .overview ? .infinity : 700, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dockCanvas)
        .overlay(alignment: .leading) { Color.dockBorderLight.frame(width: 0.5) }
    }

    var kanbanAttachmentSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("ATTACHMENTS")
                .dockFont(.compactStatus, weight: .semibold)
                .tracking(0.7)
                .foregroundStyle(Color.dockMetadataText)
            if control.kanbanAttachments.isEmpty {
                Text("No attachments")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
            } else {
                ForEach(control.kanbanAttachments) { attachment in
                    HStack(spacing: 7) {
                        DockIcon(.paperclip)
                        Text(attachment.name).lineLimit(1)
                        Spacer(minLength: 4)
                        if let kind = attachment.kind { Text(kind) }
                        if let size = attachment.sizeBytes {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        }
                    }
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockSecondaryText)
                    .dockPadding(.vertical, 5)
                    .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
                }
            }
        }
    }

    struct KanbanTimelineRow: Identifiable {
        let id: String, title: String, text: String?, date: Date?
    }

    /// Events and comments merged, newest first, capped so a long run stays light.
    func kanbanTimeline(_ detail: KanbanTaskDetail) -> [KanbanTimelineRow] {
        let events = detail.events.map {
            KanbanTimelineRow(
                id: "e-\($0.id)", title: $0.kind.replacingOccurrences(of: "_", with: " ").capitalized, text: $0.note,
                date: $0.createdAt)
        }
        let comments = detail.comments.map {
            KanbanTimelineRow(id: "c-\($0.id)", title: "\($0.author) commented", text: $0.body, date: $0.createdAt)
        }
        return Array((events + comments).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(60))
    }

    func kanbanActivitySection(_ detail: KanbanTaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let step = selectedKanbanTask?.currentStepKey, !step.isEmpty {
                kanbanInspectorSection("CURRENT STEP") {
                    Text(step)
                        .dockFont(.navigation, weight: .medium, design: .monospaced)
                        .foregroundStyle(Color.dockAccent)
                }
            }
            if let event = selectedKanbanTask?.latestEventKind, !event.isEmpty {
                kanbanInspectorSection("LATEST EVENT") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.replacingOccurrences(of: "_", with: " ").capitalized)
                            .dockFont(.navigation, weight: .medium)
                        if let note = selectedKanbanTask?.latestEventNote, !note.isEmpty {
                            Text(note).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                        }
                    }
                }
            }
            kanbanInspectorSection("TIMELINE · \(detail.events.count + detail.comments.count)") {
                let rows = kanbanTimeline(detail)
                if rows.isEmpty {
                    Text("No events yet. This updates live while the task runs.")
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                } else {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(row.title).dockFont(.metadata, weight: .semibold).foregroundStyle(Color.dockAccent)
                                Spacer()
                                if let date = row.date {
                                    Text(date.formatted(date: .omitted, time: .standard))
                                        .dockFont(.compactStatus, weight: .regular, design: .monospaced)
                                        .foregroundStyle(Color.dockMetadataText)
                                }
                            }
                            if let text = row.text {
                                Text(text).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).textSelection(
                                    .enabled)
                            }
                        }
                        .dockPadding(.vertical, 6)
                        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
                    }
                }
            }
            kanbanInspectorSection("RUN HISTORY · \(detail.runs.count)") {
                if detail.runs.isEmpty {
                    Text("No run history returned by Hermes.")
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                } else {
                    ForEach(detail.runs) { run in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(run.status.capitalized)
                                if let outcome = run.outcome { Text("· \(outcome)") }
                                Spacer()
                                if let elapsed = run.elapsed { Text(elapsed) }
                            }
                            .dockFont(.metadata, weight: .semibold)
                            .foregroundStyle(Color.dockAccent)
                            if let profile = run.profile {
                                Text(profile).dockFont(.compactStatus, weight: .regular, design: .monospaced)
                                    .foregroundStyle(Color.dockMetadataText)
                            }
                            if let summary = run.summary {
                                Text(summary).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                            }
                        }
                        .dockPadding(.vertical, 7)
                        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
                    }
                }
            }
        }
    }

    func kanbanBlockExplanation(_ why: KanbanTaskDetail.BlockExplanation) -> some View {
        kanbanInspectorSection(
            "WHY BLOCKED" + (why.kind.map { " · \($0.replacingOccurrences(of: "_", with: " "))" } ?? "")
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text(why.reason ?? "No reason was recorded.")
                    .dockFont(.body, weight: .medium)
                    .foregroundStyle(Color.dockWarning)
                if let error = why.lastError {
                    Text("Last run: \(error)").dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                }
            }
            .textSelection(.enabled)
            .dockPadding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dockWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    func kanbanInspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .dockFont(.compactStatus, weight: .semibold)
                .tracking(0.7)
                .foregroundStyle(Color.dockMetadataText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var canCreateKanbanTask: Bool {
        !kanbanTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func kanbanDetailHeaderIcon(_ name: Ph) -> some View {
        DockIcon(name)
            .dockFont(.body, weight: .semibold)
            .foregroundStyle(Color.dockSecondaryText)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).dockSurfaceFill(
                    Color.dockSurface2.opacity(0.6))
            )
            .contentShape(Rectangle())
    }

    /// Same lane rules as the card menu, plus the edit-style mutations.
    @ViewBuilder
    func kanbanDetailActions(_ task: KanbanTaskSummary, lane: KanbanLane) -> some View {
        let statusActions: [KanbanTaskAction] =
            switch lane {
            case .done: [.archive]
            case .blocked: [.unblock, .archive]
            default: [.complete, .block, .archive]
            }
        let available = statusActions.filter { control.capabilityAvailable("kanban.\($0.rawValue)") }
        let mutations = KanbanMutationKind.allCases.filter { control.capabilityAvailable($0.capabilityID) }
        ForEach(available, id: \.self) { action in
            Button(kanbanActionTitle(for: action), icon: kanbanActionIcon(for: action)) {
                requestKanbanAction(task, action: action)
            }
            .disabled(control.isActionPending(control.kanbanActionID(action, task: task)))
        }
        if !available.isEmpty, !mutations.isEmpty { Divider() }
        ForEach(mutations) { kind in
            Button(kind.title) {
                kanbanMutationRequest = KanbanMutationRequest(task: task, kind: kind, value: "", reclaimFirst: false)
            }
        }
        if available.isEmpty, mutations.isEmpty {
            Text("No actions available")
        }
    }

    func kanbanActionTitle(for action: KanbanTaskAction) -> String {
        switch action {
        case .complete: "Mark Done"
        case .block: "Block"
        case .unblock: "Unblock"
        case .archive: "Archive"
        }
    }

    func kanbanActionIcon(for action: KanbanTaskAction) -> Ph {
        switch action {
        case .complete: .check
        case .block: .pause
        case .unblock: .arrowUUpLeft
        case .archive: .archive
        }
    }
}
