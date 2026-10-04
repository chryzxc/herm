import SwiftUI

enum AutomationWorkspaceTab: String, CaseIterable, Identifiable {
    case history
    case details

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum AutomationWorkspaceLayout {
    static let inspectorBreakpoint: CGFloat = 1_000
    static let listWidth: CGFloat = 290

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

        var title: String {
            switch self {
            case .paused: "Paused"
            case .noRun: "No run yet"
            case .running: "Running"
            case .succeeded: "Succeeded"
            case .failed: "Failed"
            }
        }
    }

    let result: Result
    let detail: String?

    static func make(job: CronSummary, latestRun: CronRunSummary?) -> Self {
        guard job.enabled else { return Self(result: .paused, detail: job.lastRunAt) }
        // Run history may be unavailable; the job's own last_status is still authoritative.
        if let latestRun {
            return Self(result: result(for: latestRun), detail: latestRun.claimedAt)
        }
        if let status = job.lastStatus, job.lastRunAt != nil {
            return Self(result: failed(status, error: job.lastError) ? .failed : .succeeded, detail: job.lastRunAt)
        }
        return Self(result: .noRun, detail: nil)
    }

    static func result(for run: CronRunSummary) -> Result {
        if failed(run.status, error: run.error) { return .failed }
        let status = run.status.lowercased()
        return status.contains("run") || status.contains("claim") || status.contains("pending") ? .running : .succeeded
    }

    @MainActor static func isOverdue(_ job: CronSummary, now: Date = .now) -> Bool {
        guard job.enabled, let next = job.nextRun.flatMap(HumanDateFormatting.date) else { return false }
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
    @State private var tab: AutomationWorkspaceTab = .history
    @State private var searchText = ""
    @State private var isShowingCreationSheet = false
    @State private var editingJob: CronSummary?
    @State private var removeRequest: CronSummary?
    @State private var runRequest: CronSummary?
    @State private var isShowingRemoveConfirmation = false
    @State private var isShowingRunConfirmation = false
    @State private var pendingCreatedName: String?

    private var selectedJob: CronSummary? {
        control.cronJobs.first { $0.id == selectedJobID }
    }

    private var filteredJobs: [CronSummary] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return control.cronJobs }
        return control.cronJobs.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    /// Per-job history when loaded; otherwise whatever the capped global feed holds.
    private func runs(for job: CronSummary) -> [CronRunSummary] {
        control.cronRunsByJob[job.id] ?? control.cronRuns.filter { $0.jobID == job.id }
    }

    private func presentation(for job: CronSummary) -> AutomationWorkspaceRowPresentation {
        AutomationWorkspaceRowPresentation.make(job: job, latestRun: runs(for: job).first)
    }

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
        // Same shell as the Kanban inspector: a full-height, resizable,
        // closable sibling panel rather than a column inside the page.
        HSplitView {
            page
                .frame(minWidth: 600)
            if isRunPanelOpen, let job = selectedJob {
                Group {
                    if let run = selectedRun(for: job) {
                        AutomationRunDetailPanel(run: run, job: job, control: control, onClose: { isRunPanelOpen = false })
                    } else {
                        emptyRunPanel
                    }
                }
                .frame(minWidth: 340, idealWidth: 400, maxWidth: 520, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.dockCanvas)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isShowingCreationSheet) {
            AutomationCreationSheet(control: control) { name in
                pendingCreatedName = name
                refreshWorkspace()
            }
        }
        .sheet(item: $editingJob) { job in
            CronEditEditor(
                job: job,
                isPending: control.isActionPending(control.cronActionID("edit", job: job)),
                submit: { draft in control.editCron(job, draft: draft) }
            )
        }
        .confirmationDialog("Remove automation?", isPresented: $isShowingRemoveConfirmation) {
            if let removeRequest {
                Button("Remove \(removeRequest.name)", role: .destructive) {
                    control.removeCron(removeRequest)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the schedule from Hermes.")
        }
        .confirmationDialog("Run automation now?", isPresented: $isShowingRunConfirmation) {
            if let runRequest {
                Button("Run \(runRequest.name)") { control.runCronNow(runRequest) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This starts an additional run immediately and does not change the schedule.")
        }
        .onAppear { reconcileSelection() }
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
            if let pendingCreatedName,
               let created = control.cronJobs.first(where: { $0.name == pendingCreatedName }) {
                selectedJobID = created.id
                self.pendingCreatedName = nil
            }
        }
    }

    private var emptyRunPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("RUN DETAIL")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.05)
                    .foregroundStyle(Color.dockMetadataText)
                Spacer()
                Button { isRunPanelOpen = false } label: {
                    DockIcon(.x).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockSecondaryText)
                .help("Close run panel")
            }
            .padding(.horizontal, 16)
            .frame(height: 64)
            .background(Color.dockSurface2)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
            placeholder("No run selected", detail: "Runs for this automation appear in History. Pick one to read its output.")
        }
    }

    private var page: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider().overlay(Color.dockBorderLight)
            if overdueCount > 0 { overdueBanner }

            if control.cronJobs.isEmpty, control.refreshState(for: "cron.jobs")?.isRefreshing == true {
                DockLoadingState(title: "Loading schedules…", detail: "Reading recurring jobs from Hermes.")
            } else if control.cronJobs.isEmpty {
                emptyWorkspace
            } else {
                HStack(spacing: 0) {
                    jobList
                        .frame(width: AutomationWorkspaceLayout.listWidth)
                    Divider().overlay(Color.dockBorderLight)
                    Group {
                        if let selectedJob { jobPanel(selectedJob) }
                        else { placeholder("Select an automation", detail: "Choose a schedule to see its run history.") }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dockCanvas)
    }

    // MARK: Header

    private var workspaceHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Automation")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Text("Recurring work Hermes runs on your behalf")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                summaryChip("\(control.cronJobs.count)", label: "schedules", tint: Color.dockSecondaryText)
                summaryChip("\(activeCount)", label: "active", tint: Color.dockSuccess)
                if attentionCount > 0 {
                    summaryChip("\(attentionCount)", label: "failing", tint: Color.dockDestructive)
                }
            }
            Button(action: refreshWorkspace) {
                Group {
                    if isRefreshing { ProgressView().controlSize(.small) }
                    else { DockIcon(.arrowsClockwise) }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.dockSecondaryText)
            .disabled(isRefreshing)
            .help("Refresh automations")
            Button {
                isShowingCreationSheet = true
            } label: {
                Label("New automation", icon: .plus)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
            }
            .buttonStyle(.dockPrimary)
            .disabled(!control.cronControlAvailable)
            .help(control.cronControlAvailable ? "Create a new schedule" : "Automation control is unavailable through this Hermes gateway.")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func summaryChip(_ value: String, label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
            Text(label).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Capsule().fill(Color.dockSurface.opacity(0.5)))
        .overlay(Capsule().strokeBorder(Color.dockBorderLight, lineWidth: 0.5))
    }

    private var overdueBanner: some View {
        HStack(spacing: 8) {
            DockIcon(.warning)
                .font(.system(size: 11, weight: .semibold))
            Text("\(overdueCount) schedule\(overdueCount == 1 ? " is" : "s are") overdue. The Hermes scheduler may not be running.")
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.dockWarning)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.dockWarning.opacity(0.08))
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    // MARK: Job list

    private var jobList: some View {
        VStack(spacing: 0) {
            TextField("Filter automations", text: $searchText)
                .textFieldStyle(.dockGlass)
                .padding(10)
            Divider().overlay(Color.dockBorderLight)
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(filteredJobs) { job in jobRow(job) }
                }
            }
        }
    }

    private func jobRow(_ job: CronSummary) -> some View {
        let result = presentation(for: job)
        let overdue = AutomationWorkspaceRowPresentation.isOverdue(job)
        let selected = job.id == selectedJobID
        return HStack(alignment: .top, spacing: 10) {
            statusDot(result.result)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(job.enabled ? Color.dockPrimaryText : Color.dockSecondaryText)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(CronScheduleFormatting.humanReadable(job.schedule))
                    if job.enabled, let next = job.nextRun {
                        Text("·")
                        Text(overdue ? "overdue" : "next \(HumanDateFormatting.relative(next))")
                            .foregroundStyle(overdue ? Color.dockWarning : Color.dockMetadataText)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.dockAccent.opacity(0.10) : Color.clear)
        .overlay(alignment: .leading) {
            if selected { Color.dockAccent.frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedJobID = job.id }
        .contextMenu { menuActions(for: job) }
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    // MARK: Selected job

    private func jobPanel(_ job: CronSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            jobHeader(job)
            statStrip(job)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            DockTabBar(options: AutomationWorkspaceTab.allCases, selection: $tab, title: \.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statePill(
                    job.enabled ? (overdue ? "Overdue" : "Active") : "Paused",
                    tint: !job.enabled ? Color.dockMetadataText : (overdue ? Color.dockWarning : Color.dockSuccess)
                )
                Text(rowMetadata(job))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(alignment: .center, spacing: 10) {
                Text(job.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if control.capabilityAvailable("cron.edit"), !job.editableFields.isEmpty {
                    Button("Edit") { editingJob = job }
                        .buttonStyle(.dockSecondary)
                        .controlSize(.small)
                }
                if control.capabilityAvailable("cron.runNow") {
                    Button {
                        runRequest = job
                        isShowingRunConfirmation = true
                    } label: {
                        Label("Run now", icon: .play)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                    }
                    .buttonStyle(.dockPrimary)
                    .disabled(control.isActionPending(control.cronActionID("run", job: job)))
                }
                Button {
                    isRunPanelOpen.toggle()
                } label: {
                    DockIcon(isRunPanelOpen ? .sidebarSimple : .square)
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isRunPanelOpen ? Color.dockAccent : Color.dockSecondaryText)
                .help(isRunPanelOpen ? "Hide run panel" : "Show run panel")
                if hasMenuActions(for: job) {
                    Menu { menuActions(for: job) } label: {
                        Ph.dotsThree.image(size: 14, color: .secondaryLabelColor)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("More actions")
                    .accessibilityLabel("More actions for \(job.name)")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private func statStrip(_ job: CronSummary) -> some View {
        let overdue = AutomationWorkspaceRowPresentation.isOverdue(job)
        let result = presentation(for: job)
        let jobRuns = runs(for: job)
        let failures = jobRuns.filter { AutomationWorkspaceRowPresentation.result(for: $0) == .failed }.count
        return HStack(spacing: 10) {
            statTile(
                "Next run",
                value: nextRunPrimary(job, overdue: overdue),
                detail: job.enabled ? job.nextRun.map(HumanDateFormatting.dateAndTime) : job.details.pausedReason,
                tint: overdue ? Color.dockWarning : Color.dockPrimaryText
            )
            statTile(
                "Last run",
                value: result.result.title,
                detail: result.detail.map { HumanDateFormatting.relative($0) },
                tint: statusColor(result.result)
            )
            statTile(
                "Success",
                value: jobRuns.isEmpty ? "—" : "\(Int((Double(jobRuns.count - failures) / Double(jobRuns.count) * 100).rounded()))%",
                detail: jobRuns.isEmpty ? "No runs loaded" : "last \(jobRuns.count) run\(jobRuns.count == 1 ? "" : "s")",
                tint: failures > 0 ? Color.dockWarning : Color.dockPrimaryText
            )
        }
    }

    private func history(_ job: CronSummary) -> some View {
        let jobRuns = runs(for: job)
        let state = control.refreshState(for: control.cronRunsProjectionKey(jobID: job.id))
        let selected = isRunPanelOpen ? selectedRun(for: job)?.id : nil
        return LazyVStack(alignment: .leading, spacing: 0) {
            if jobRuns.isEmpty {
                if state?.isRefreshing == true {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading run history…")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .padding(20)
                } else if let error = state?.error {
                    callout("Run history unavailable", message: error, tint: Color.dockWarning)
                        .padding(20)
                } else {
                    placeholder("No runs yet", detail: "Runs appear here after the schedule fires or you run it manually.")
                }
            } else {
                if let error = state?.error {
                    Text("Showing cached history · \(error)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(2)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
                ForEach(jobRuns) { run in
                    runRow(run, selected: run.id == selected) {
                        selectedRunID = run.id
                        isRunPanelOpen = true
                    }
                }
            }
        }
    }

    private func runRow(_ run: CronRunSummary, selected: Bool, action: @escaping () -> Void) -> some View {
        let result = AutomationWorkspaceRowPresentation.result(for: run)
        return Button(action: action) {
            HStack(spacing: 12) {
                statusDot(result)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.claimedAt.map(HumanDateFormatting.dateAndTime) ?? "Unknown time")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text([run.claimedAt.map { HumanDateFormatting.relative($0) }, run.source].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.dockMetadataText)
                    if let error = run.error {
                        Text(error)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.dockDestructive)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(run.status.capitalized)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(statusColor(result))
                DockIcon(.caretRight)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.dockMetadataText)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.dockAccent.opacity(0.10) : Color.clear)
            .overlay(alignment: .leading) {
                if selected { Color.dockAccent.frame(width: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockSecondaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2).fill(Color.dockSurface.opacity(0.5)))
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
                if !details.skills.isEmpty { detailRow("Skills", details.skills.joined(separator: ", ")) }
                if !details.toolsets.isEmpty { detailRow("Toolsets", details.toolsets.joined(separator: ", ")) }
                if let workdir = details.workdir { detailRow("Workdir", workdir, monospaced: true) }
                detailRow("Delivery", job.delivery?.isEmpty == false ? job.delivery! : "Not reported")
            }

            section("Identifiers") {
                detailRow("Job", job.id, monospaced: true)
                if let sessionID = job.sessionID { detailRow("Session", sessionID, monospaced: true) }
            }
        }
        .padding(20)
    }

    // MARK: Shared pieces

    private func selectedRun(for job: CronSummary) -> CronRunSummary? {
        let jobRuns = runs(for: job)
        return jobRuns.first { $0.id == selectedRunID } ?? jobRuns.first
    }

    private func rowMetadata(_ job: CronSummary) -> String {
        var parts = [CronScheduleFormatting.humanReadable(job.schedule)]
        if let delivery = job.delivery, !delivery.isEmpty, delivery != "local" { parts.append(delivery) }
        return parts.joined(separator: " · ")
    }

    private func nextRunPrimary(_ job: CronSummary, overdue: Bool) -> String {
        guard job.enabled else { return "Paused" }
        guard let next = job.nextRun else { return "Not reported" }
        return overdue ? "Overdue" : HumanDateFormatting.relative(next).capitalizedFirst
    }

    private func modelDescription(_ details: CronJobDetails) -> String {
        switch (details.provider, details.model) {
        case let (provider?, model?): "\(model) · \(provider)"
        case let (nil, model?): model
        default: "Default model"
        }
    }

    private func statusDot(_ result: AutomationWorkspaceRowPresentation.Result) -> some View {
        Circle()
            .strokeBorder(statusColor(result), lineWidth: 1.5)
            .background(Circle().fill(result == .paused || result == .noRun ? .clear : statusColor(result)))
            .frame(width: 8, height: 8)
    }

    private func statePill(_ title: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
    }

    private func statTile(_ title: String, value: String, detail: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.dockMetadataText)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail ?? " ")
                .font(.system(size: 10))
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius).fill(Color.dockSurface.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius).strokeBorder(Color.dockBorderLight, lineWidth: 0.5))
    }

    private func callout(_ title: String, message: String, tint: Color) -> some View {
        AutomationCallout(title: title, message: message, tint: tint)
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        AutomationDetailRow(label: label, value: value, monospaced: monospaced)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func menuActions(for job: CronSummary) -> some View {
        if control.capabilityAvailable("cron.runNow") {
            Button("Run now", icon: .play) {
                runRequest = job
                isShowingRunConfirmation = true
            }
        }
        if control.capabilityAvailable("cron.edit"), !job.editableFields.isEmpty {
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

    private func hasMenuActions(for job: CronSummary) -> Bool {
        control.capabilityAvailable("cron.runNow")
            || (control.capabilityAvailable("cron.edit") && !job.editableFields.isEmpty)
            || control.cronControlAvailable
    }

    private var emptyWorkspace: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No automations")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Text("Create a schedule when Hermes should run work without you.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockMetadataText)
            Button("New automation") { isShowingCreationSheet = true }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockAccent)
                .disabled(!control.cronControlAvailable)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
    }

    private func reconcileSelection() {
        if let selectedJobID, control.cronJobs.contains(where: { $0.id == selectedJobID }) { return }
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
                        Text("RUN DETAIL")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.05)
                            .foregroundStyle(Color.dockMetadataText)
                        Text(run.status.capitalized)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(result == .failed ? Color.dockDestructive : (result == .running ? Color.dockAccent : Color.dockSuccess))
                    }
                    Text(run.claimedAt.map(HumanDateFormatting.dateAndTime) ?? "Unknown time")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let report {
                    DockCopyButton(report.markdown, label: "Copy", accessibilityLabel: "Copy run output", iconSize: 13)
                        .buttonStyle(.borderless)
                }
                if let onClose {
                    Button(action: onClose) {
                        DockIcon(.x).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.dockSecondaryText)
                    .keyboardShortcut(.cancelAction)
                    .help("Close run panel")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 64)
            .background(Color.dockSurface2)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        AutomationDetailRow(label: "Automation", value: job.name)
                        if let claimedAt = run.claimedAt {
                            AutomationDetailRow(label: "Started", value: HumanDateFormatting.relative(claimedAt).capitalizedFirst)
                        }
                        if let source = run.source { AutomationDetailRow(label: "Source", value: source) }
                        AutomationDetailRow(label: "Run ID", value: run.id, monospaced: true)
                        if let sessionID = run.sessionID { AutomationDetailRow(label: "Session", value: sessionID, monospaced: true) }
                    }
                    if let error = run.error {
                        AutomationCallout(title: "Error", message: error, tint: Color.dockDestructive)
                    }
                    Text("OUTPUT")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                    output
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: run.id) { await load() }
    }

    @ViewBuilder
    private var output: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading output…")
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.dockMetadataText)
        } else if let report {
            MarkdownMessageView(markdown: report.markdown)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(loadError ?? "Hermes did not record a session for this run.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @MainActor
    private func load() async {
        report = nil
        loadError = nil
        guard let request else { return }
        isLoading = true
        do {
            report = try await control.cronReport(for: request)
        } catch {
            // Script-only jobs never open an agent session, so the lookup 404s.
            loadError = (error as NSError).code == 404 || error.localizedDescription.contains("404")
                ? "This run did not record an agent session, so there is no transcript output. Script-only jobs report through their delivery target."
                : error.localizedDescription
        }
        isLoading = false
    }
}

private struct AutomationDetailRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12))
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.dockSecondaryText)
                .textSelection(.enabled)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius).fill(tint.opacity(0.08)))
        .overlay(alignment: .leading) { tint.frame(width: 2) }
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius))
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

private struct AutomationCreationSheet: View {
    @ObservedObject var control: ControlCenterModel
    let onSuccess: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var schedule = ""
    @State private var prompt = ""
    @State private var error: String?
    @State private var isSubmitting = false

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        DockModal(icon: .magicWand, title: "New Automation", subtitle: "Define when Hermes should run and what it should do.", width: 520) {
            labeledField("Name") {
                TextField("Nightly review", text: $name).textFieldStyle(.dockGlass)
            }
            labeledField("Schedule", hint: "every 2h or 0 9 * * *") {
                TextField("When should Hermes run this?", text: $schedule).textFieldStyle(.dockGlass)
            }
            if !schedule.isEmpty {
                ModalNote(text: CronScheduleFormatting.humanReadable(schedule), icon: .clock)
            }
            labeledField("Request") {
                TextField("What should Hermes do?", text: $prompt, axis: .vertical)
                    .lineLimit(4...8)
                    .textFieldStyle(.dockGlass)
            }
            if let error { ModalNote(text: error, icon: .warning, tone: .dockWarning) }
        } footer: {
            modalActions(
                primaryTitle: "Create Automation",
                pendingTitle: "Creating…",
                isDisabled: !valid || isSubmitting || !control.cronControlAvailable,
                isPending: isSubmitting,
                onCancel: { dismiss() }
            ) { submit() }
        }
    }

    private func submit() {
        let submittedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmitting = true
        error = nil
        Task {
            let succeeded = await control.createCron(name: submittedName, schedule: schedule, prompt: prompt)
            await MainActor.run {
                isSubmitting = false
                if succeeded {
                    onSuccess(submittedName)
                    dismiss()
                } else {
                    error = control.lastError ?? "Hermes could not create this automation."
                }
            }
        }
    }
}
