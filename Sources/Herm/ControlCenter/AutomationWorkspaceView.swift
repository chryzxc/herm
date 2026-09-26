import SwiftUI

enum AutomationWorkspaceTab: String, CaseIterable, Identifiable {
    case overview
    case runs

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum AutomationWorkspaceHistoryScope: String, CaseIterable, Identifiable {
    case selected
    case all

    var id: Self { self }
    var title: String { self == .selected ? "Selected" : "All runs" }
}

enum AutomationWorkspaceLayout {
    static let inspectorBreakpoint: CGFloat = 1_000
    static let inspectorWidth: CGFloat = 380

    static func usesPersistentInspector(width: CGFloat) -> Bool {
        width >= inspectorBreakpoint
    }
}

struct AutomationWorkspaceRowPresentation: Equatable {
    enum Result: Equatable {
        case paused
        case noRun
        case succeeded
        case failed

        var title: String {
            switch self {
            case .paused: "Paused"
            case .noRun: "No run yet"
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
            return Self(result: failed(latestRun.status, error: latestRun.error) ? .failed : .succeeded, detail: latestRun.claimedAt)
        }
        if let status = job.lastStatus, job.lastRunAt != nil {
            return Self(result: failed(status, error: job.lastError) ? .failed : .succeeded, detail: job.lastRunAt)
        }
        return Self(result: .noRun, detail: nil)
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
    @State private var inspectorTab: AutomationWorkspaceTab = .overview
    @State private var historyScope: AutomationWorkspaceHistoryScope = .selected
    @State private var isShowingCreationSheet = false
    @State private var isShowingCompactInspector = false
    @State private var editingJob: CronSummary?
    @State private var reportRequest: CronReportRequest?
    @State private var removeRequest: CronSummary?
    @State private var runRequest: CronSummary?
    @State private var isShowingRemoveConfirmation = false
    @State private var isShowingRunConfirmation = false
    @State private var pendingCreatedName: String?

    private var selectedJob: CronSummary? {
        control.cronJobs.first { $0.id == selectedJobID }
    }

    private var activeCount: Int {
        control.cronJobs.filter(\.enabled).count
    }

    private var attentionCount: Int {
        control.cronJobs.reduce(into: 0) { result, job in
            let latest = control.cronRuns.first { $0.jobID == job.id }
            if AutomationWorkspaceRowPresentation.make(job: job, latestRun: latest).result == .failed {
                result += 1
            }
        }
    }

    private var overdueCount: Int {
        control.cronJobs.filter { AutomationWorkspaceRowPresentation.isOverdue($0) }.count
    }

    private var headerSubtitle: String {
        let count = control.cronJobs.count
        if control.refreshState(for: "cron.jobs")?.isRefreshing == true, count == 0 {
            return "Loading schedules…"
        }
        let attention = attentionCount > 0 ? " · \(attentionCount) needs attention" : ""
        return "\(count) schedule\(count == 1 ? "" : "s") · \(activeCount) active\(attention)"
    }

    private var isRefreshing: Bool {
        control.isRefreshing || control.refreshState(for: "cron.history")?.isRefreshing == true
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                workspaceHeader
                Divider().overlay(Color.dockBorderLight)
                if overdueCount > 0 { overdueBanner }

                if control.cronJobs.isEmpty, control.refreshState(for: "cron.jobs")?.isRefreshing == true {
                    DockLoadingState(title: "Loading schedules…", detail: "Reading recurring jobs from Hermes.")
                } else if control.cronJobs.isEmpty {
                    emptyWorkspace
                } else if AutomationWorkspaceLayout.usesPersistentInspector(width: proxy.size.width) {
                    HStack(spacing: 0) {
                        automationTable(opensInspector: false)
                        Divider().overlay(Color.dockBorderLight)
                        if let selectedJob {
                            automationInspector(job: selectedJob)
                                .frame(width: AutomationWorkspaceLayout.inspectorWidth)
                                .transition(.opacity)
                        } else {
                            inspectorPlaceholder
                                .frame(width: AutomationWorkspaceLayout.inspectorWidth)
                        }
                    }
                } else {
                    automationTable(opensInspector: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.dockCanvas)
            .sheet(isPresented: $isShowingCompactInspector) {
                if let selectedJob {
                    automationInspector(job: selectedJob, onClose: { isShowingCompactInspector = false })
                        .frame(minWidth: 460, minHeight: 600)
                }
            }
        }
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
        .sheet(item: $reportRequest) { request in
            CronReportDetailSheet(request: request, control: control)
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
        .onChange(of: control.cronJobs) { _, _ in
            reconcileSelection()
            if let pendingCreatedName,
               let created = control.cronJobs.first(where: { $0.name == pendingCreatedName }) {
                selectedJobID = created.id
                self.pendingCreatedName = nil
            }
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Automation")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Text(headerSubtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(attentionCount > 0 ? Color.dockWarning : Color.dockMetadataText)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button(action: refreshWorkspace) {
                Group {
                    if isRefreshing { ProgressView().controlSize(.small) }
                    else { DockIcon(.arrowsClockwise) }
                }
                .frame(width: 36, height: 36)
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
                    .frame(height: 34)
            }
            .buttonStyle(.dockPrimary)
            .disabled(!control.capabilityAvailable("rpc-scheduling"))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
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
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(Color.dockWarning.opacity(0.08))
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func automationTable(opensInspector: Bool) -> some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 760
            VStack(spacing: 0) {
                tableHeader(compact: compact)
                Divider().overlay(Color.dockBorderLight)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(control.cronJobs) { job in
                            automationRow(job, compact: compact, opensInspector: opensInspector)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tableHeader(compact: Bool) -> some View {
        HStack(spacing: 0) {
            Text("").frame(width: 24)
            Text("AUTOMATION").frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text("NEXT RUN").frame(width: Self.timeColumnWidth, alignment: .leading)
                Text("LAST RUN").frame(width: Self.timeColumnWidth, alignment: .leading)
            }
            Text("").frame(width: Self.actionsWidth)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.dockMetadataText)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private static let timeColumnWidth: CGFloat = 150
    private static let actionsWidth: CGFloat = 72

    private func automationRow(_ job: CronSummary, compact: Bool, opensInspector: Bool) -> some View {
        let latest = control.cronRuns.first { $0.jobID == job.id }
        let presentation = AutomationWorkspaceRowPresentation.make(job: job, latestRun: latest)
        let overdue = AutomationWorkspaceRowPresentation.isOverdue(job)
        let selected = job.id == selectedJobID
        let pendingRun = control.isActionPending(control.cronActionID("run", job: job))

        return HStack(spacing: 0) {
            statusDot(presentation.result)
                .frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(job.enabled ? Color.dockPrimaryText : Color.dockSecondaryText)
                    .lineLimit(1)
                Text(rowMetadata(job, compact: compact))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 12)
            if !compact {
                timeCell(
                    primary: nextRunPrimary(job, overdue: overdue),
                    secondary: job.enabled ? job.nextRun.map(HumanDateFormatting.dateAndTime) : nil,
                    tint: overdue ? Color.dockWarning : Color.dockSecondaryText
                )
                timeCell(
                    primary: presentation.result.title,
                    secondary: presentation.detail.map { HumanDateFormatting.relative($0) },
                    tint: presentation.result == .failed ? Color.dockDestructive : Color.dockSecondaryText
                )
            }
            HStack(spacing: 0) {
                if control.capabilityAvailable("cron.runNow") {
                    Button {
                        runRequest = job
                        isShowingRunConfirmation = true
                    } label: {
                        Group {
                            if pendingRun { ProgressView().controlSize(.small) }
                            else { DockIcon(.play, weight: .fill).font(.system(size: 11)) }
                        }
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.dockAccent)
                    .disabled(pendingRun)
                    .help("Run now")
                }
                Menu { menuActions(for: job) } label: {
                    Ph.dotsThree.image(size: 14)
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions for \(job.name)")
            }
            .frame(width: Self.actionsWidth, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 54)
        .background(selected ? Color.dockAccent.opacity(0.10) : Color.clear)
        .overlay(alignment: .leading) {
            if selected { Color.dockAccent.frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { select(job, opensInspector: opensInspector) }
        .contextMenu { menuActions(for: job) }
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    /// Schedule · delivery on one quiet line; compact widths fold the next run in too.
    private func rowMetadata(_ job: CronSummary, compact: Bool) -> String {
        var parts = [CronScheduleFormatting.humanReadable(job.schedule)]
        if let delivery = job.delivery, !delivery.isEmpty, delivery != "local" { parts.append(delivery) }
        if compact, job.enabled, let next = job.nextRun { parts.append("next \(HumanDateFormatting.relative(next))") }
        return parts.joined(separator: " · ")
    }

    private func nextRunPrimary(_ job: CronSummary, overdue: Bool) -> String {
        guard job.enabled else { return "Paused" }
        guard let next = job.nextRun else { return "Not reported" }
        return overdue ? "Overdue \(HumanDateFormatting.relative(next))" : HumanDateFormatting.relative(next).capitalizedFirst
    }

    private func timeCell(primary: String, secondary: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(primary)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
            if let secondary {
                Text(secondary)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .lineLimit(1)
        .frame(width: Self.timeColumnWidth, alignment: .leading)
    }

    private func statusDot(_ result: AutomationWorkspaceRowPresentation.Result) -> some View {
        Circle()
            .strokeBorder(statusColor(result), lineWidth: 1.5)
            .background(Circle().fill(result == .succeeded || result == .failed ? statusColor(result) : .clear))
            .frame(width: 8, height: 8)
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
        if control.capabilityAvailable("rpc-scheduling") {
            Divider()
            Button("Remove", icon: .trash, role: .destructive) {
                removeRequest = job
                isShowingRemoveConfirmation = true
            }
        }
    }

    private func automationInspector(job: CronSummary, onClose: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            inspectorHeader(job, onClose: onClose)
            DockTabBar(options: AutomationWorkspaceTab.allCases, selection: $inspectorTab, title: \.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
            .padding(.bottom, 12)
            Divider().overlay(Color.dockBorderLight)
            ScrollView {
                if inspectorTab == .overview {
                    overview(job)
                } else {
                    runsInspector(job)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dockSurface.opacity(0.18))
    }

    private func inspectorHeader(_ job: CronSummary, onClose: (() -> Void)?) -> some View {
        let overdue = AutomationWorkspaceRowPresentation.isOverdue(job)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statePill(
                    job.enabled ? (overdue ? "Overdue" : "Active") : "Paused",
                    tint: !job.enabled ? Color.dockMetadataText : (overdue ? Color.dockWarning : Color.dockSuccess)
                )
                Text(CronScheduleFormatting.humanReadable(job.schedule))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let onClose {
                    Button(action: onClose) {
                        DockIcon(.x)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.dockSecondaryText)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
                }
            }
            Text(job.name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if control.capabilityAvailable("cron.runNow") {
                    Button {
                        runRequest = job
                        isShowingRunConfirmation = true
                    } label: {
                        Label("Run now", icon: .play)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                    }
                    .buttonStyle(.dockPrimary)
                    .disabled(control.isActionPending(control.cronActionID("run", job: job)))
                }
                if control.capabilityAvailable("cron.edit"), !job.editableFields.isEmpty {
                    Button("Edit") { editingJob = job }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dockAccent)
                }
                Spacer(minLength: 0)
                Menu { menuActions(for: job) } label: {
                    Ph.dotsThree.image(size: 14)
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .help("More actions")
            }
        }
        .padding(18)
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

    private func overview(_ job: CronSummary) -> some View {
        let latest = control.cronRuns.first { $0.jobID == job.id }
        let result = AutomationWorkspaceRowPresentation.make(job: job, latestRun: latest)
        let overdue = AutomationWorkspaceRowPresentation.isOverdue(job)
        let runError = latest?.error ?? job.lastError
        let details = job.details
        return VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                statTile(
                    "Next run",
                    value: job.enabled ? (nextRunPrimary(job, overdue: overdue)) : "Paused",
                    detail: job.enabled ? job.nextRun.map(HumanDateFormatting.dateAndTime) : details.pausedReason,
                    tint: overdue ? Color.dockWarning : Color.dockPrimaryText
                )
                statTile(
                    "Last run",
                    value: result.result.title,
                    detail: result.detail.map(HumanDateFormatting.dateAndTime),
                    tint: result.result == .failed ? Color.dockDestructive : (result.result == .succeeded ? Color.dockSuccess : Color.dockPrimaryText)
                )
                statTile("Cadence", value: CronScheduleFormatting.humanReadable(job.schedule), detail: job.schedule, tint: Color.dockPrimaryText)
                statTile("Repeats", value: details.repeats.map { $0.capitalizedFirst } ?? "Not reported", detail: nil, tint: Color.dockPrimaryText)
            }

            if let runError, !runError.isEmpty {
                callout("Last run failed", message: runError, tint: Color.dockDestructive)
            }
            if let deliveryError = details.deliveryError {
                callout("Delivery failed", message: deliveryError, tint: Color.dockWarning)
            }

            if (job.prompt?.isEmpty == false) || details.script != nil {
                inspectorSection("Request") {
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
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.dockSurface.opacity(0.5)))
                    }
                }
            }

            inspectorSection("Configuration") {
                detailRow("Model", modelDescription(details))
                if !details.skills.isEmpty { detailRow("Skills", details.skills.joined(separator: ", ")) }
                if !details.toolsets.isEmpty { detailRow("Toolsets", details.toolsets.joined(separator: ", ")) }
                if let workdir = details.workdir { detailRow("Workdir", workdir, monospaced: true) }
                detailRow("Delivery", job.delivery?.isEmpty == false ? job.delivery! : "Not reported")
            }

            inspectorSection("Identifiers") {
                detailRow("Job", job.id, monospaced: true)
                if let sessionID = job.sessionID { detailRow("Session", sessionID, monospaced: true) }
            }

            if let latest, let request = control.cronReportRequest(for: latest) {
                Button {
                    reportRequest = request
                } label: {
                    Label("Open latest report", icon: .fileText)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockAccent)
            }
        }
        .padding(18)
    }

    private func modelDescription(_ details: CronJobDetails) -> String {
        switch (details.provider, details.model) {
        case let (provider?, model?): "\(model) · \(provider)"
        case let (nil, model?): model
        default: "Default model"
        }
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.dockSurface.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dockBorderLight, lineWidth: 0.5))
    }

    private func callout(_ title: String, message: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.dockSecondaryText)
                .textSelection(.enabled)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.08)))
        .overlay(alignment: .leading) { tint.frame(width: 2) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runsInspector(_ job: CronSummary) -> some View {
        let runs = historyScope == .selected
            ? control.cronRuns.filter { $0.jobID == job.id }
            : control.cronRuns
        return VStack(alignment: .leading, spacing: 12) {
            DockTabBar(options: AutomationWorkspaceHistoryScope.allCases, selection: $historyScope, title: \.title)
            if let state = control.refreshState(for: "cron.history"), state.isStale {
                Text("History is stale while Hermes reconnects.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
            }
            if !control.cronHistoryAvailable && control.cronRuns.isEmpty {
                inspectorEmpty("Run history is unavailable through this Hermes CLI.")
            } else if runs.isEmpty {
                inspectorEmpty(historyScope == .selected ? "No runs recorded for this schedule." : "No automation runs recorded.")
            } else {
                ForEach(runs) { run in
                    runRow(run)
                }
            }
        }
        .padding(18)
    }

    private func runRow(_ run: CronRunSummary) -> some View {
        let job = run.jobID.flatMap { id in control.cronJobs.first { $0.id == id } }
        let content = HStack(alignment: .top, spacing: 8) {
            Circle().fill(run.error == nil ? Color.dockSuccess : Color.dockDestructive).frame(width: 7, height: 7).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.status.capitalized).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText)
                if let claimedAt = run.claimedAt { Text(HumanDateFormatting.dateAndTime(claimedAt)).foregroundStyle(Color.dockMetadataText) }
                if let job { Text(job.name).foregroundStyle(Color.dockSecondaryText).lineLimit(1) }
                if let source = run.source, !source.isEmpty { Text(source).foregroundStyle(Color.dockMetadataText).lineLimit(1) }
                if let error = run.error { Text(error).foregroundStyle(Color.dockWarning).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if control.cronReportRequest(for: run) != nil {
                DockIcon(.caretRight).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.dockAccent).padding(.top, 4)
            }
        }
        .font(.system(size: 11))
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
        if let request = control.cronReportRequest(for: run) {
            return AnyView(Button { reportRequest = request } label: { content }.buttonStyle(.plain))
        }
        return AnyView(content)
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
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

    private func inspectorEmpty(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(Color.dockMetadataText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 22)
    }

    private var inspectorPlaceholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Select an automation")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Text("Choose a schedule to inspect its configuration and runs.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockMetadataText)
        }
        .padding(22)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
    }

    private func select(_ job: CronSummary, opensInspector: Bool) {
        selectedJobID = job.id
        if inspectorTab == .runs { historyScope = .selected }
        // The table remains the primary surface on wide screens. On compact
        // windows selection opens the same inspector as a native sheet.
        if opensInspector {
            isShowingCompactInspector = true
        }
    }

    private func reconcileSelection() {
        if let selectedJobID, control.cronJobs.contains(where: { $0.id == selectedJobID }) { return }
        selectedJobID = control.cronJobs.first?.id
    }

    private func refreshWorkspace() {
        control.refresh()
        control.refreshCronRuns()
    }

    private func statusColor(_ result: AutomationWorkspaceRowPresentation.Result) -> Color {
        switch result {
        case .paused, .noRun: Color.dockMetadataText
        case .succeeded: Color.dockSuccess
        case .failed: Color.dockDestructive
        }
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
                isDisabled: !valid || isSubmitting || !control.capabilityAvailable("rpc-scheduling"),
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
