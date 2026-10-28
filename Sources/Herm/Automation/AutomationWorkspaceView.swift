import SwiftUI

enum AutomationWorkspaceTab: String, CaseIterable, Identifiable {
    case history
    case details

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum AutomationWorkspaceLayout {
    static let inspectorBreakpoint: CGFloat = 1_000
    static let listWidth: CGFloat = 280

    /// Whether the run-detail panel sits beside the history instead of a sheet.
    static func usesPersistentInspector(width: CGFloat) -> Bool {
        width >= inspectorBreakpoint
    }
}

struct AutomationWorkspaceRowPresentation: Equatable {
    enum Result: Equatable {
        case paused
        case noRun
        case running
        case succeeded
        case failed
        case unknown

        var title: String {
            switch self {
            case .paused: "Paused"
            case .noRun: "No run yet"
            case .running: "Running"
            case .succeeded: "Succeeded"
            case .failed: "Failed"
            case .unknown: "Outcome unavailable"
            }
        }
    }

    let result: Result
    let detail: String?

    @MainActor static func make(job: CronSummary, latestRun: CronRunSummary?) -> Self {
        guard job.enabled else { return Self(result: .paused, detail: job.lastRunAt) }
        if let latestRun {
            let outcome = result(for: latestRun)
            if outcome == .unknown, let status = job.lastStatus,
                let jobDate = job.lastRunAt.flatMap(HumanDateFormatting.date),
                let runDate = latestRun.claimedAt.flatMap(HumanDateFormatting.date),
                jobDate >= runDate
            {
                return Self(
                    result: result(status: status, error: job.lastError), detail: job.lastRunAt)
            }
            return Self(result: outcome, detail: latestRun.claimedAt)
        }
        if let status = job.lastStatus, job.lastRunAt != nil {
            return Self(result: result(status: status, error: job.lastError), detail: job.lastRunAt)
        }
        return Self(result: .noRun, detail: nil)
    }

    static func result(for run: CronRunSummary) -> Result {
        result(status: run.status, error: run.error)
    }

    private static func result(status: String, error: String?) -> Result {
        if failed(status, error: error) { return .failed }
        let status = status.lowercased()
        if ["running", "claimed", "pending"].contains(status) { return .running }
        return ["completed", "success", "succeeded", "ok"].contains(status) ? .succeeded : .unknown
    }

    @MainActor static func isOverdue(_ job: CronSummary, now: Date = .now) -> Bool {
        guard job.enabled, let next = job.nextRun.flatMap(HumanDateFormatting.date) else {
            return false
        }
        return next < now.addingTimeInterval(-60)
    }

    private static func failed(_ status: String, error: String?) -> Bool {
        let status = status.lowercased()
        return (error?.isEmpty == false) || status.contains("fail") || status.contains("error")
    }
}

struct AutomationWorkspaceView: View {
    @ObservedObject var control: ControlCenterModel

    @State private var selectedJobID: String?
    @State private var selectedRunID: String?
    @State private var isRunPanelOpen = true
    @State private var isCompactList = false
    @State private var tab: AutomationWorkspaceTab = .history
    @State private var searchText = ""
    @State private var isShowingCreationSheet = false
    @State private var editingJob: CronSummary?
    @State private var pauseRequest: CronSummary?
    @State private var removeRequest: CronSummary?
    @State private var runRequest: CronSummary?
    @State private var isShowingRemoveConfirmation = false
    @State private var isShowingRunConfirmation = false
    @State private var pendingCreatedJobID: String?

    private var selectedJob: CronSummary? {
        control.cronJobs.first { $0.id == selectedJobID }
    }

    private var filteredJobs: [CronSummary] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return control.cronJobs }
        return control.cronJobs.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    /// Per-job history when loaded; otherwise whatever the capped global feed holds.
    private func runs(for job: CronSummary) -> [CronRunSummary] {
        control.cronRunsByJob[job.id] ?? control.cronRuns.filter { $0.jobID == job.id }
    }

    private func presentation(for job: CronSummary) -> AutomationWorkspaceRowPresentation {
        AutomationWorkspaceRowPresentation.make(job: job, latestRun: runs(for: job).first)
    }

    @AppStorage("herm.automationListCollapsed") private var isJobListCollapsed = false
    /// Narrow widths or the sidebar toggle swap the list for a picker.
    private var hidesJobList: Bool { isCompactList || isJobListCollapsed }

    private var activeCount: Int { control.cronJobs.filter(\.enabled).count }

    private var attentionCount: Int {
        control.cronJobs.filter { presentation(for: $0).result == .failed }.count
    }

    private var overdueCount: Int {
        control.cronJobs.filter { AutomationWorkspaceRowPresentation.isOverdue($0) }.count
    }

    private var isRefreshing: Bool {
        control.isRefreshing || control.refreshState(for: "cron.history")?.isRefreshing == true
    }

    var body: some View {
        // Wide: the Kanban-style resizable inspector beside the page. Narrow (the
        // minimized panel): the run detail replaces the page, and below 760pt the
        // schedule list collapses into a menu.
        VStack(spacing: 0) {
            workspaceHeader
            GeometryReader { geo in
                let wide = AutomationWorkspaceLayout.usesPersistentInspector(width: geo.size.width)
                Group {
                    if wide {
                        HSplitView {
                            page.frame(minWidth: 640)
                            if isRunPanelOpen, let job = selectedJob {
                                runPanel(for: job)
                                    .frame(
                                        minWidth: 320, idealWidth: 380, maxWidth: 480,
                                        maxHeight: .infinity,
                                        alignment: .topLeading
                                    )
                                    .background(Color.dockCanvas)
                                    .overlay(alignment: .leading) {
                                        Color.dockBorder.frame(width: DockLayout.hairline)
                                    }
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                    } else if isRunPanelOpen, let job = selectedJob {
                        runPanel(for: job).background(Color.dockCanvas)
                    } else {
                        page
                    }
                }
                .onChange(of: wide, initial: true) { _, wide in isRunPanelOpen = wide }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dockSheet(isPresented: $isShowingCreationSheet) {
            AutomationCreationSheet(control: control) { id in
                pendingCreatedJobID = id
                selectedJobID = id
                refreshWorkspace()
            }
        }
        .dockSheet(item: $editingJob) { job in
            CronEditEditor(job: job, control: control)
        }
        .confirmationDialog(
            pauseRequest?.enabled == true ? "Pause automation?" : "Resume automation?",
            isPresented: Binding(
                get: { pauseRequest != nil }, set: { if !$0 { pauseRequest = nil } })
        ) {
            if let job = pauseRequest {
                Button(job.enabled ? "Pause" : "Resume") {
                    let reference = RoutineReference(
                        profileID: control.profileForRoutine(job), job: job,
                        run: runs(for: job).first)
                    Task {
                        await control.recoverRoutine(reference, run: false, paused: job.enabled)
                    }
                }
            }
            Button("Cancel", role: .cancel) { pauseRequest = nil }
        }
        .confirmationDialog("Remove automation?", isPresented: $isShowingRemoveConfirmation) {
            if let removeRequest {
                Button("Remove \(removeRequest.name)", role: .destructive) {
                    control.removeCron(removeRequest)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently removes \(removeRequest?.name ?? "the schedule") from profile \(removeRequest.flatMap { control.profileForRoutine($0) } ?? "Launch profile")."
            )
        }
        .confirmationDialog("Run automation now?", isPresented: $isShowingRunConfirmation) {
            if let runRequest {
                Button("Run \(runRequest.name)") { control.runCronNow(runRequest) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This starts a new execution of \(runRequest?.name ?? "the routine") in profile \(runRequest.flatMap { control.profileForRoutine($0) } ?? "Launch profile"). It does not retry delivery or change the schedule."
            )
        }
        .onAppear {
            applyRequestedRoutineSelection()
            reconcileSelection()
        }
        .task(id: "\(control.routineProfileID ?? "")/\(selectedJobID ?? "")") {
            guard let selectedJobID else { return }
            while !Task.isCancelled {
                control.refreshCronRuns(jobID: selectedJobID)
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .onChange(of: control.cronJobs) { _, _ in applyRequestedRoutineSelection() }
        .onChange(of: control.requestedAutomationDidNavigate) { _, _ in
            applyRequestedRoutineSelection()
        }
        .onChange(of: control.requestedAutomationJobID, initial: true) { _, id in
            applyRequestedRoutineSelection()
        }
        .onChange(of: selectedJobID) { _, id in
            selectedRunID = nil
            if let id { control.refreshCronRuns(jobID: id) }
        }
        .onChange(of: control.cronRuns) { _, _ in
            // A global history refresh (periodic, or after Run now) means new runs may exist.
            if let selectedJobID { control.refreshCronRuns(jobID: selectedJobID) }
        }
        .onChange(of: control.cronJobs) { _, _ in
            reconcileSelection()
            if let pendingCreatedJobID,
                let created = control.cronJobs.first(where: { $0.id == pendingCreatedJobID })
            {
                selectedJobID = created.id
                self.pendingCreatedJobID = nil
            }
        }
    }

    @ViewBuilder
    private func runPanel(for job: CronSummary) -> some View {
        if let run = selectedRun(for: job) {
            AutomationRunDetailPanel(
                run: run, job: job, control: control, onClose: { isRunPanelOpen = false }
            )
            .id(
                "\(control.clientBindingGeneration)/\(control.profileForRoutine(job) ?? "")/\(job.id)"
            )
        } else {
            emptyRunPanel
        }
    }

    private var emptyRunPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Run output")
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockMetadataText)
                Spacer()
                Button {
                    isRunPanelOpen = false
                } label: {
                    DockIcon(.x).dockFont(.metadata, weight: .semibold).frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .foregroundStyle(Color.dockSecondaryText)
                .help("Close run output")
                .accessibilityLabel("Close run output")
            }
            .padding(.horizontal, 16)
            .frame(height: 64)
            .dockPaneTint(Color.dockSurface2)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
            placeholder(
                "No run selected",
                detail: "Runs for this automation appear in History. Pick one to read its output.")
        }
    }

    private var page: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if control.cronJobs.isEmpty,
                    control.refreshState(for: "cron.jobs")?.isRefreshing == true
                {
                    DockLoadingState(
                        title: "Loading schedules…", detail: "Reading recurring jobs from Hermes.")
                } else if control.cronJobs.isEmpty,
                    let error = control.refreshState(for: "cron.jobs")?.error
                {
                    VStack(alignment: .leading, spacing: 12) {
                        placeholder("Automations unavailable", detail: error)
                        Button("Retry") { refreshWorkspace() }.buttonStyle(.dockSecondary).padding(
                            .horizontal, 22)
                    }
                } else if control.cronJobs.isEmpty, !control.cronControlAvailable {
                    placeholder(
                        "Automations unavailable",
                        detail:
                            "Connect to Hermes and refresh to load schedules and their available controls."
                    )
                } else if control.cronJobs.isEmpty {
                    emptyWorkspace
                } else {
                    HStack(spacing: 0) {
                        if !hidesJobList {
                            jobList
                                .frame(width: AutomationWorkspaceLayout.listWidth)
                            Divider().overlay(Color.dockBorderLight)
                        }
                        VStack(spacing: 0) {
                            if hidesJobList {
                                DockMenuPicker(
                                    title: selectedJob?.name ?? "Select an automation",
                                    selection: $selectedJobID
                                ) {
                                    ForEach(control.cronJobs) {
                                        DockMenuOption($0.name, value: Optional($0.id))
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                Divider().overlay(Color.dockBorderLight)
                            }
                            Group {
                                if let selectedJob {
                                    jobPanel(selectedJob)
                                } else {
                                    placeholder(
                                        "Select an automation",
                                        detail: "Choose a schedule to see its run history.")
                                }
                            }
                            .frame(
                                maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.dockCanvas)
            .onChange(of: geometry.size.width < 760, initial: true) { _, compact in
                isCompactList = compact
            }
        }
    }

    // MARK: Header

    private var workspaceHeader: some View {
        DockPageHeader(
            title: "Automation",
            subtitle: control.refreshState(for: "cron.jobs")?.error.map {
                "Schedules are not current · " + $0
            }
                ?? (overdueCount > 0
                    ? "\(overdueCount) overdue · The Hermes scheduler may not be running"
                    : "Recurring work Hermes runs on your behalf"),
            onRefresh: refreshWorkspace,
            isRefreshing: isRefreshing,
            sidebarCollapsed: $isJobListCollapsed
        ) {
            HStack(spacing: 6) {
                summaryChip("\(activeCount)", label: "active", tint: Color.dockSuccess)
                if attentionCount > 0 {
                    summaryChip("\(attentionCount)", label: "failing", tint: Color.dockDestructive)
                }
            }
            Button {
                isShowingCreationSheet = true
            } label: {
                DockIconLabel("New automation", icon: .plus)
            }
            .buttonStyle(.dockSecondary)
            .controlSize(.small)
            .disabled(!control.cronControlAvailable)
            .help(
                control.cronControlAvailable
                    ? "Create a new schedule"
                    : "Automation control is unavailable through this Hermes gateway.")
        }
    }

    private func summaryChip(_ value: String, label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(value).dockFont(.metadata, weight: .semibold, design: .monospaced).foregroundStyle(
                tint)
            Text(label).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)

    }

    // MARK: Job list

    private var jobList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DockIcon(.magnifyingGlass, size: 14, color: .dockMetadataText)
                TextField("Filter automations", text: $searchText)
                    .textFieldStyle(.plain)
                    .dockFont(.body)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius).dockSurfaceFill(
                    Color.dockControlSurface)
            )
            .padding(12)
            HStack {
                Text("SCHEDULES").dockFont(.sectionLabel)
                Spacer()
                Text("\(filteredJobs.count)").dockFont(.machineMetadata)
            }
            .foregroundStyle(Color.dockMetadataText)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            ScrollView(.vertical) {
                LazyVStack(spacing: 4) {
                    if filteredJobs.isEmpty {
                        placeholder(
                            "No matching automations", detail: "Try a different name or job ID.")
                    }
                    ForEach(filteredJobs) { job in jobRow(job) }
                }
                .padding(8)
            }
        }
        .dockPaneTint(Color.dockSidebar)
    }

    private func jobRow(_ job: CronSummary) -> some View {
        let result = presentation(for: job)
        let overdue = AutomationWorkspaceRowPresentation.isOverdue(job)
        let selected = job.id == selectedJobID
        return Button {
            selectedJobID = job.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                statusDot(result.result)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.name)
                        .dockFont(.body, weight: .medium)
                        .foregroundStyle(
                            job.enabled ? Color.dockPrimaryText : Color.dockSecondaryText
                        )
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(CronScheduleFormatting.humanReadable(job.schedule))
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(result.result.title)
                            .foregroundStyle(statusColor(result.result))
                        if job.enabled, let next = job.nextRun {
                            Text("·")
                            Text(overdue ? "Overdue" : "Next \(HumanDateFormatting.relative(next))")
                                .foregroundStyle(
                                    overdue ? Color.dockWarning : Color.dockMetadataText)
                        }
                    }
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius).dockSelectionFill(
                    selected, fallback: selected ? Color.dockAccentMuted : Color.clear)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(Color.dockAccent).frame(width: 3).padding(.vertical, 12)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .contextMenu { menuActions(for: job) }
    }

    // MARK: Selected job

    private func jobPanel(_ job: CronSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            jobHeader(job)
            statStrip(job)
                .padding(.horizontal, 20)
            HStack(spacing: 12) {
                DockTabBar(
                    options: AutomationWorkspaceTab.allCases, selection: $tab, title: \.title)
                Spacer(minLength: 0)
                Button {
                    isRunPanelOpen.toggle()
                } label: {
                    DockIconLabel(
                        isRunPanelOpen ? "Hide output" : "Run output", icon: .sidebarSimple)
                }
                .buttonStyle(.dockCompact)
                .accessibilityLabel(isRunPanelOpen ? "Hide run output" : "Show run output")
                .accessibilityValue(isRunPanelOpen ? "Expanded" : "Collapsed")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider().overlay(Color.dockBorderLight)
            ScrollView {
                if tab == .history {
                    history(job)
                } else {
                    details(job)
                }
            }
        }
    }

    private func jobHeader(_ job: CronSummary) -> some View {
        let overdue = AutomationWorkspaceRowPresentation.isOverdue(job)
        let reference = RoutineReference(
            profileID: control.profileForRoutine(job), job: job, run: runs(for: job).first)
        return VStack(alignment: .leading, spacing: 8) {
            Text(job.name)
                .dockFont(.pageTitle)
                .foregroundStyle(Color.dockPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statePill(
                    job.enabled ? (overdue ? "Overdue" : "Active") : "Paused",
                    tint: !job.enabled
                        ? Color.dockMetadataText : (overdue ? Color.dockWarning : Color.dockSuccess)
                )
                Text(CronScheduleFormatting.humanReadable(job.schedule))
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Edit") { editingJob = job }
                    .buttonStyle(.dockSecondary)
                    .disabled(!control.cronControlAvailable)
                    .help(
                        control.cronControlAvailable
                            ? "Edit this automation" : "Editing is unavailable through this Hermes gateway.")
                Button {
                    runRequest = job
                    isShowingRunConfirmation = true
                } label: {
                    DockIconLabel("Run now", icon: .play)
                }
                .buttonStyle(.dockPrimary)
                .disabled(
                    !control.canTriggerRoutine(
                        RoutineReference(
                            profileID: control.profileForRoutine(job), job: job,
                            run: runs(for: job).first)))
                Spacer(minLength: 0)
                if hasMenuActions(for: job) {
                    DockMenu {
                        menuActions(for: job)
                    } label: {
                        Ph.dotsThree.image(size: 14, color: NSColor(Color.dockSecondaryText))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .fixedSize()
                    .help("More actions")
                    .accessibilityLabel("More actions for \(job.name)")
                }
            }
            .controlSize(.small)
            Text(
                control.routineActionErrors[reference.id]
                    ?? (control.routineActions.contains(reference.id)
                        ? "Waiting for Hermes to confirm the operation…" : " ")
            )
            .dockFont(.body)
            .foregroundStyle(
                control.routineActionErrors[reference.id] != nil
                    ? Color.dockWarning : Color.dockMetadataText
            )
            .lineLimit(1)
            .frame(height: 18, alignment: .topLeading)
            .help(control.routineActionErrors[reference.id] ?? "")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private func statStrip(_ job: CronSummary) -> some View {
        let overdue = AutomationWorkspaceRowPresentation.isOverdue(job)
        let result = presentation(for: job)
        let jobRuns = runs(for: job)
        let outcomes = jobRuns.map { AutomationWorkspaceRowPresentation.result(for: $0) }
        let failures = outcomes.filter { $0 == .failed }.count
        let successes = outcomes.filter { $0 == .succeeded }.count
        let knownOutcomes = successes + failures
        return HStack(spacing: 0) {
            statTile(
                "Next run",
                icon: .clock,
                value: nextRunPrimary(job, overdue: overdue),
                detail: job.enabled
                    ? job.nextRun.map(HumanDateFormatting.dateAndTime) : job.details.pausedReason,
                tint: !job.enabled
                    ? Color.dockMetadataText
                    : (overdue ? Color.dockWarning : DockCategoryTone.automation.color)
            )
            Divider().overlay(Color.dockBorderLight).padding(.vertical, 12)
            statTile(
                "Last run",
                icon: .clockCounterClockwise,
                value: result.result == .unknown ? "Unknown" : result.result.title,
                detail: result.detail.map { HumanDateFormatting.relative($0) },
                tint: statusColor(result.result)
            )
            Divider().overlay(Color.dockBorderLight).padding(.vertical, 12)
            statTile(
                "Success rate",
                icon: .checkCircle,
                value: knownOutcomes == 0
                    ? "Not reported"
                    : "\(Int((Double(successes) / Double(knownOutcomes) * 100).rounded()))%",
                detail: knownOutcomes == 0
                    ? "Awaiting a confirmed outcome" : "\(knownOutcomes) confirmed outcomes",
                tint: knownOutcomes == 0
                    ? Color.dockMetadataText
                    : (failures > 0 ? Color.dockWarning : Color.dockSuccess)
            )
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    private func history(_ job: CronSummary) -> some View {
        let jobRuns = runs(for: job)
        let state = control.refreshState(for: control.cronRunsProjectionKey(jobID: job.id))
        let selected = isRunPanelOpen ? selectedRun(for: job)?.id : nil
        return LazyVStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("RUN HISTORY")
                    .dockFont(.sectionLabel)
                Text("\(jobRuns.count)")
                    .dockFont(.machineMetadata)
                Spacer()
                Text(state?.error != nil ? "History not current" : "Outcome")
                    .dockFont(.metadata)
                    .foregroundStyle(
                        state?.error != nil ? Color.dockWarning : Color.dockMetadataText
                    )
                    .help(state?.error ?? "Reported execution status")
            }
            .foregroundStyle(Color.dockMetadataText)
            .padding(.horizontal, 20)
            .frame(height: 32)
            .dockPaneTint(Color.dockSurface2)
            if jobRuns.isEmpty {
                if state?.isRefreshing == true {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading run history…")
                    }
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
                    .padding(20)
                } else if let error = state?.error {
                    callout("Run history unavailable", message: error, tint: Color.dockWarning)
                        .padding(20)
                } else {
                    placeholder(
                        "No runs yet",
                        detail: "Runs appear here after the schedule fires or you run it manually.")
                }
            } else {
                ForEach(jobRuns) { run in
                    runRow(run, selected: run.id == selected) {
                        selectedRunID = run.id
                        isRunPanelOpen = true
                    }
                }
            }
        }
    }

    private func runRow(_ run: CronRunSummary, selected: Bool, action: @escaping () -> Void)
        -> some View
    {
        let result = AutomationWorkspaceRowPresentation.result(for: run)
        return Button(action: action) {
            HStack(spacing: 12) {
                statusDot(result)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.claimedAt.map(HumanDateFormatting.dateAndTime) ?? "Unknown time")
                        .dockFont(.body, weight: .medium)
                        .foregroundStyle(Color.dockPrimaryText)
                    Text(
                        run.claimedAt.map { HumanDateFormatting.relative($0) }
                            ?? "Start time unavailable"
                    )
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    if let error = run.error {
                        Text(error)
                            .dockFont(.machineMetadata)
                            .foregroundStyle(Color.dockDestructive)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                statePill(run.status.capitalized, tint: statusColor(result))
                DockIcon(.caretRight, size: 12, color: .dockMetadataText)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Rectangle().dockSelectionFill(
                    selected, fallback: selected ? Color.dockAccentMuted : Color.clear)
            )
            .overlay(alignment: .leading) {
                if selected { Color.dockAccent.frame(width: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func details(_ job: CronSummary) -> some View {
        let details = job.details
        return VStack(alignment: .leading, spacing: 18) {
            if let error = job.lastError, !error.isEmpty {
                callout("Last run failed", message: error, tint: Color.dockDestructive)
            }
            if let deliveryError = details.deliveryError {
                callout("Delivery failed", message: deliveryError, tint: Color.dockWarning)
            }

            if (job.prompt?.isEmpty == false) || details.script != nil {
                section("Request") {
                    if let script = details.script {
                        detailRow("Script", script, monospaced: true)
                    }
                    if let prompt = job.prompt, !prompt.isEmpty {
                        Text(prompt)
                            .dockFont(.body)
                            .foregroundStyle(Color.dockSecondaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2)
                                    .dockSurfaceFill(
                                        Color.dockSurface.opacity(0.5)))
                    }
                }
            }

            section("Schedule") {
                detailRow("Cadence", CronScheduleFormatting.humanReadable(job.schedule))
                detailRow("Expression", job.schedule, monospaced: true)
                detailRow("Repeats", details.repeats.map { $0.capitalizedFirst } ?? "Not reported")
            }

            section("Configuration") {
                detailRow("Model", modelDescription(details))
                if !details.skills.isEmpty {
                    detailRow("Skills", details.skills.joined(separator: ", "))
                }
                if !details.toolsets.isEmpty {
                    detailRow("Toolsets", details.toolsets.joined(separator: ", "))
                }
                if let workdir = details.workdir { detailRow("Workdir", workdir, monospaced: true) }
                detailRow(
                    "Delivery", job.delivery?.isEmpty == false ? job.delivery! : "Not reported")
            }

            section("Identifiers") {
                detailRow("Job", job.id, monospaced: true)
                if let sessionID = job.sessionID {
                    detailRow("Session", sessionID, monospaced: true)
                }
            }
        }
        .padding(20)
    }

    // MARK: Shared pieces

    private func selectedRun(for job: CronSummary) -> CronRunSummary? {
        let jobRuns = runs(for: job)
        return jobRuns.first { $0.id == selectedRunID } ?? jobRuns.first
    }

    private func nextRunPrimary(_ job: CronSummary, overdue: Bool) -> String {
        guard job.enabled else { return "Paused" }
        guard let next = job.nextRun else { return "Not reported" }
        return overdue ? "Overdue" : HumanDateFormatting.relative(next).capitalizedFirst
    }

    private func modelDescription(_ details: CronJobDetails) -> String {
        switch (details.provider, details.model) {
        case (let provider?, let model?): "\(model) · \(provider)"
        case (nil, let model?): model
        default: "Default model"
        }
    }

    private func statusDot(_ result: AutomationWorkspaceRowPresentation.Result) -> some View {
        Circle()
            .strokeBorder(statusColor(result), lineWidth: 1.5)
            .background(
                Circle().fill(result == .paused || result == .noRun ? .clear : statusColor(result))
            )
            .frame(width: 8, height: 8)
    }

    private func statePill(_ title: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title).dockFont(.metadata, weight: .semibold)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
    }

    private func statTile(_ title: String, icon: Ph, value: String, detail: String?, tint: Color)
        -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                DockIcon(icon, size: 12, color: tint)
                Text(title)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
            }
            Text(value)
                .dockFont(.body, weight: .medium)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail ?? " ")
                .dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
    }

    private func callout(_ title: String, message: String, tint: Color) -> some View {
        AutomationCallout(title: title, message: message, tint: tint)
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        AutomationDetailRow(label: label, value: value, monospaced: monospaced)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .dockFont(.compactStatus, weight: .semibold, design: .monospaced)
                .foregroundStyle(Color.dockMetadataText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func placeholder(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
            Text(detail)
                .dockFont(.body)
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func menuActions(for job: CronSummary) -> some View {
        let reference = RoutineReference(
            profileID: control.profileForRoutine(job), job: job, run: runs(for: job).first)
        Button(
            CommandCenterPreferencesStore.shared.routinePins.contains(reference.id)
                ? "Unpin from notch" : "Pin to notch"
        ) {
            CommandCenterPreferencesStore.shared.toggleRoutinePin(reference.id)
        }
        if control.cronControlAvailable {
            Button(job.enabled ? "Pause…" : "Resume…") { pauseRequest = job }
                .disabled(
                    control.routineActions.contains(reference.id)
                        || control.unavailableRoutineActions.contains(
                            job.enabled ? "pause" : "resume")
                )
        }
        if control.routineNeedsReview(reference) {
            Button("I reviewed the run; allow another") {
                Task { await control.confirmRoutineReview(reference) }
            }.disabled(control.routineActions.contains(reference.id))
        }
        Button("Integrations…") {
            control.integrationDestination = IntegrationDestination(profileID: reference.profileID)
        }
        if control.cronControlAvailable || control.capabilityAvailable("cron.runNow") {
            Button("Run now", icon: .play) {
                runRequest = job
                isShowingRunConfirmation = true
            }.disabled(!control.canTriggerRoutine(reference))
        }
        if control.cronControlAvailable {
            Button("Edit", icon: .pencilSimple) { editingJob = job }
        }
        if control.cronControlAvailable {
            Divider()
            Button("Remove", icon: .trash, role: .destructive) {
                removeRequest = job
                isShowingRemoveConfirmation = true
            }
        }
    }

    private func applyRequestedRoutineSelection() {
        guard control.requestedAutomationDidNavigate, let id = control.requestedAutomationJobID,
            control.requestedAutomationMatchesInventory(),
            control.cronJobs.contains(where: { $0.id == id })
        else { return }
        selectedJobID = id
        control.requestedAutomationJobID = nil
        control.requestedAutomationOwner = nil
        control.requestedAutomationDidNavigate = false
    }
    private func hasMenuActions(for job: CronSummary) -> Bool { true }

    private var emptyWorkspace: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No automations")
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
            Text("Create a schedule when Hermes should run work without you.")
                .dockFont(.body)
                .foregroundStyle(Color.dockMetadataText)
            Button("New automation") { isShowingCreationSheet = true }
                .buttonStyle(.dockCompact)
                .foregroundStyle(Color.dockAccent)
                .disabled(!control.cronControlAvailable)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
    }

    private func reconcileSelection() {
        if let selectedJobID, control.cronJobs.contains(where: { $0.id == selectedJobID }) {
            return
        }
        selectedJobID = control.cronJobs.first?.id
    }

    private func refreshWorkspace() {
        control.refresh()
        control.refreshCronRuns()
        if let selectedJobID { control.refreshCronRuns(jobID: selectedJobID) }
    }

    private func statusColor(_ result: AutomationWorkspaceRowPresentation.Result) -> Color {
        switch result {
        case .paused, .noRun: Color.dockMetadataText
        case .running: Color.dockAccent
        case .succeeded: Color.dockSuccess
        case .failed: Color.dockDestructive
        case .unknown: Color.dockMetadataText
        }
    }
}

/// Third panel: one run's metadata plus the report Hermes recorded for it.
private struct AutomationRunDetailPanel: View {
    let run: CronRunSummary
    let job: CronSummary
    @ObservedObject var control: ControlCenterModel
    var onClose: (() -> Void)?

    @State private var report: CronReportDetail?
    @State private var loadError: String?
    @State private var isLoading = false

    private var request: CronReportRequest? { control.cronReportRequest(for: run) }

    var body: some View {
        let result = AutomationWorkspaceRowPresentation.result(for: run)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Run output")
                            .dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockPrimaryText)
                        Text(run.status.capitalized)
                            .dockFont(.metadata, weight: .semibold)
                            .foregroundStyle(
                                result == .failed
                                    ? Color.dockDestructive
                                    : (result == .running
                                        ? Color.dockAccent
                                        : (result == .succeeded
                                            ? Color.dockSuccess : Color.dockMetadataText)))
                    }
                    Text(run.claimedAt.map(HumanDateFormatting.dateAndTime) ?? "Unknown time")
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let output = report?.markdown ?? run.outputPreview {
                    DockCopyButton(
                        output, label: "Copy", accessibilityLabel: "Copy run output", iconSize: 13
                    )
                    .buttonStyle(.dockCompact)
                }
                if let onClose {
                    Button(action: onClose) {
                        DockIcon(.x).dockFont(.metadata, weight: .semibold).frame(
                            width: 28, height: 28
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .foregroundStyle(Color.dockSecondaryText)
                    .keyboardShortcut(.cancelAction)
                    .help("Close run output")
                    .accessibilityLabel("Close run output")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 64)
            .dockPaneTint(Color.dockSurface2)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = run.error {
                        Color.dockBorderLight.frame(height: 0.5)
                        AutomationCallout(
                            title: "Error", message: error, tint: Color.dockDestructive
                        )
                        .padding(18)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(run.source == "cron_output" ? "OUTPUT PREVIEW" : "OUTPUT")
                            .dockFont(.sectionLabel)
                            .foregroundStyle(Color.dockMetadataText)
                        output
                    }
                    .padding(18)
                    Divider().overlay(Color.dockBorderLight)
                    DisclosureGroup("Run details") {
                        VStack(alignment: .leading, spacing: 6) {
                            AutomationDetailRow(label: "Automation", value: job.name)
                            if let claimedAt = run.claimedAt {
                                AutomationDetailRow(
                                    label: "Started",
                                    value: HumanDateFormatting.relative(claimedAt).capitalizedFirst)
                            }
                            if let source = run.source {
                                AutomationDetailRow(label: "Source", value: source)
                            }
                            AutomationDetailRow(label: "Run ID", value: run.id, monospaced: true)
                            if let sessionID = run.sessionID {
                                AutomationDetailRow(
                                    label: "Session", value: sessionID, monospaced: true)
                            }
                        }
                        .padding(.top, 12)
                    }
                    .disclosureGroupStyle(DockDisclosureGroupStyle())
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .padding(18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: run) { await load() }
    }

    @ViewBuilder
    private var output: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading output…")
            }
            .dockFont(.body)
            .foregroundStyle(Color.dockMetadataText)
        } else if let report {
            MarkdownMessageView(markdown: report.markdown, bodySize: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let preview = run.outputPreview, loadError == nil {
            Text(preview)
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(
                loadError
                    ?? (run.source == "cron_output"
                        ? "Hermes recorded a script-only run without a stored preview."
                        : "No transcript is linked to this execution record. Refresh run history to load Hermes-recorded sessions.")
            )
            .dockFont(.body)
            .foregroundStyle(Color.dockMetadataText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @MainActor
    private func load() async {
        report = nil
        loadError = nil
        isLoading = false
        guard let request else { return }
        isLoading = true
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let report = try await control.cronReport(for: request)
            guard !Task.isCancelled else { return }
            self.report = report
        } catch {
            guard !Task.isCancelled else { return }
            loadError = ControlCenterModel.safeUserDiagnostic(error.localizedDescription)
        }
    }
}

private struct AutomationDetailRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .dockFont(size: monospaced ? 11 : 12, design: monospaced ? .monospaced : .default)
                .foregroundStyle(Color.dockSecondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AutomationCallout: View {
    let title: String
    let message: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(tint)
            Text(message)
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius).fill(tint.opacity(0.08))
        )
        .overlay(alignment: .leading) { tint.frame(width: 2) }
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius))
    }
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

private struct AutomationCreationSheet: View {
    @ObservedObject var control: ControlCenterModel
    let onSuccess: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var schedule = ""
    @State private var prompt = ""
    @State private var configuration = CronConfigurationDraft()
    @State private var error: String?
    @State private var isSubmitting = false
    @State private var creationBindingGeneration: UInt64?
    @State private var creationProfileID: String?

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !configuration.delivery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        DockModal(
            icon: .magicWand, title: "New automation",
            subtitle: "Define when Hermes should run and what it should do.", width: 560
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    labeledField("Name") {
                        DockTextField("Nightly review", text: $name).textFieldStyle(.dockGlass)
                    }
                    labeledField("Schedule", hint: "every 2h or 0 9 * * *") {
                        DockTextField("When should Hermes run this?", text: $schedule)
                            .textFieldStyle(
                                .dockGlass)
                    }
                    ModalNote(
                        text: schedule.isEmpty
                            ? "Enter an interval or a cron expression."
                            : CronScheduleFormatting.humanReadable(schedule), icon: .clock
                    )
                    .frame(minHeight: 24, alignment: .leading)
                    labeledField("Request") {
                        DockTextField("What should Hermes do?", text: $prompt, axis: .vertical)
                            .lineLimit(4...8)
                            .textFieldStyle(.dockGlass)
                    }
                    CronConfigurationFields(draft: $configuration)
                    if let error { ModalNote(text: error, icon: .warning, tone: .dockWarning) }
                }
                .padding(2)
                .disabled(isSubmitting)
            }.frame(height: 440)
        } footer: {
            modalActions(
                primaryTitle: "Create automation",
                pendingTitle: "Creating…",
                isDisabled: !valid || isSubmitting || !control.cronControlAvailable,
                isPending: isSubmitting,
                onCancel: { dismiss() }
            ) { submit() }
        }
        .interactiveDismissDisabled(isSubmitting)
        .onAppear {
            creationBindingGeneration = control.clientBindingGeneration
            creationProfileID = control.routineProfileID
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        guard creationBindingGeneration == control.clientBindingGeneration,
            creationProfileID == control.routineProfileID
        else {
            error =
                "The Hermes connection or profile changed. Close this form and create the automation in the intended profile."
            return
        }
        let submittedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmitting = true
        error = nil
        Task {
            let succeeded = await control.createCron(
                name: submittedName, schedule: schedule, prompt: prompt,
                configuration: configuration)
            await MainActor.run {
                isSubmitting = false
                if succeeded {
                    if creationBindingGeneration == control.clientBindingGeneration,
                        creationProfileID == control.routineProfileID,
                        let createdID = control.lastCreatedCronJobID
                    {
                        onSuccess(createdID)
                    }
                    dismiss()
                } else {
                    error = control.lastError ?? "Hermes could not create this automation."
                }
            }
        }
    }
}
