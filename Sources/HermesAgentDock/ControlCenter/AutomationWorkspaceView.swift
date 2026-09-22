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
        guard job.enabled else { return Self(result: .paused, detail: nil) }
        guard let latestRun else { return Self(result: .noRun, detail: nil) }
        let status = latestRun.status.lowercased()
        let failed = latestRun.error != nil || status.contains("fail") || status.contains("error")
        return Self(
            result: failed ? .failed : .succeeded,
            detail: latestRun.claimedAt
        )
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

                if control.cronJobs.isEmpty {
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
                    automationInspector(job: selectedJob)
                        .frame(minWidth: 440, minHeight: 560)
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
                Button("Remove (removeRequest.name)", role: .destructive) {
                    control.removeCron(removeRequest)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the schedule from Hermes.")
        }
        .confirmationDialog("Run automation now?", isPresented: $isShowingRunConfirmation) {
            if let runRequest {
                Button("Run (runRequest.name)") { control.runCronNow(runRequest) }
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
                    else { LucideImage(systemName: "refresh-cw") }
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
                Label("New automation", systemImage: "plus")
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

    private func automationTable(opensInspector: Bool) -> some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 760
            VStack(spacing: 0) {
                tableToolbar
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

    private var tableToolbar: some View {
        HStack(spacing: 10) {
            Text("Schedules")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Text("\(control.cronJobs.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.dockMetadataText)
            Spacer()
            Text("Hermes order")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.dockMetadataText)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func tableHeader(compact: Bool) -> some View {
        HStack(spacing: 0) {
            Text("").frame(width: 28)
            Text("AUTOMATION").frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text("SCHEDULE").frame(width: 150, alignment: .leading)
                Text("NEXT RUN").frame(width: 160, alignment: .leading)
                Text("RESULT").frame(width: 110, alignment: .leading)
                Text("DELIVERY").frame(width: 130, alignment: .leading)
            }
            Text("").frame(width: 88)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.dockMetadataText)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func automationRow(_ job: CronSummary, compact: Bool, opensInspector: Bool) -> some View {
        let latest = control.cronRuns.first { $0.jobID == job.id }
        let presentation = AutomationWorkspaceRowPresentation.make(job: job, latestRun: latest)
        let selected = job.id == selectedJobID
        let pendingRun = control.isActionPending(control.cronActionID("run", job: job))

        return HStack(spacing: 0) {
            Circle()
                .strokeBorder(statusColor(presentation.result), lineWidth: 1.5)
                .background(Circle().fill(presentation.result == .succeeded ? statusColor(presentation.result) : .clear))
                .frame(width: 8, height: 8)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                if let prompt = job.prompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text(CronScheduleFormatting.humanReadable(job.schedule))
                    .frame(width: 150, alignment: .leading)
                Text(job.nextRun.map(HumanDateFormatting.dateAndTime) ?? "Not reported")
                    .frame(width: 160, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.result.title)
                    if let detail = presentation.detail {
                        Text(HumanDateFormatting.dateAndTime(detail))
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
                .frame(width: 110, alignment: .leading)
                Text(job.delivery?.isEmpty == false ? job.delivery! : "—")
                    .frame(width: 130, alignment: .leading)
            }
            HStack(spacing: 2) {
                if control.capabilityAvailable("cron.runNow") {
                    Button {
                        runRequest = job
                        isShowingRunConfirmation = true
                    } label: {
                        Group { pendingRun ? AnyView(ProgressView().controlSize(.small)) : AnyView(LucideImage(systemName: "play.fill")) }
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.dockAccent)
                    .disabled(pendingRun)
                    .help("Run now")
                }
                Menu { menuActions(for: job) } label: {
                    LucideImage(systemName: "ellipsis")
                        .frame(width: 38, height: 38)
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(Color.dockSecondaryText)
                .help("More actions")
            }
            .frame(width: 88)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.dockSecondaryText)
        .padding(.horizontal, 18)
        .frame(minHeight: 56)
        .background(selected ? Color.dockAccent.opacity(0.13) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { select(job, opensInspector: opensInspector) }
        .contextMenu { menuActions(for: job) }
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    @ViewBuilder
    private func menuActions(for job: CronSummary) -> some View {
        if control.capabilityAvailable("cron.runNow") {
            Button("Run now", systemImage: "play.fill") {
                runRequest = job
                isShowingRunConfirmation = true
            }
        }
        if control.capabilityAvailable("cron.edit"), !job.editableFields.isEmpty {
            Button("Edit", systemImage: "pencil") { editingJob = job }
        }
        if control.capabilityAvailable("rpc-scheduling") {
            Divider()
            Button("Remove", systemImage: "trash", role: .destructive) {
                removeRequest = job
                isShowingRemoveConfirmation = true
            }
        }
    }

    private func automationInspector(job: CronSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            inspectorHeader(job)
            Picker("Inspector", selection: $inspectorTab) {
                ForEach(AutomationWorkspaceTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
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

    private func inspectorHeader(_ job: CronSummary) -> some View {
        let latest = control.cronRuns.first { $0.jobID == job.id }
        let result = AutomationWorkspaceRowPresentation.make(job: job, latestRun: latest)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(3)
                    Text(job.enabled ? "Enabled" : "Paused")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(job.enabled ? Color.dockSuccess : Color.dockWarning)
                }
                Spacer(minLength: 6)
                Circle().fill(statusColor(result.result)).frame(width: 8, height: 8).padding(.top, 5)
                Menu { menuActions(for: job) } label: {
                    LucideImage(systemName: "ellipsis").frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
            }
            HStack(spacing: 8) {
                if control.capabilityAvailable("cron.runNow") {
                    Button("Run now") {
                        runRequest = job
                        isShowingRunConfirmation = true
                    }
                    .buttonStyle(.dockPrimary)
                    .font(.system(size: 11, weight: .semibold))
                }
                if control.capabilityAvailable("cron.edit"), !job.editableFields.isEmpty {
                    Button("Edit") { editingJob = job }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.dockAccent)
                }
            }
        }
        .padding(18)
    }

    private func overview(_ job: CronSummary) -> some View {
        let latest = control.cronRuns.first { $0.jobID == job.id }
        return VStack(alignment: .leading, spacing: 16) {
            inspectorSection("Next run") {
                Text(job.nextRun.map(HumanDateFormatting.dateAndTime) ?? "Not reported by Hermes")
                    .font(.system(size: 19, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.dockPrimaryText)
            }
            inspectorSection("Schedule") {
                inspectorValue(CronScheduleFormatting.humanReadable(job.schedule))
                inspectorValue(job.schedule, monospaced: true)
            }
            if let prompt = job.prompt, !prompt.isEmpty {
                inspectorSection("Request") { inspectorValue(prompt) }
            }
            inspectorSection("Delivery") {
                inspectorValue(job.delivery?.isEmpty == false ? job.delivery! : "Not reported by Hermes")
                inspectorValue("Job ID · \(job.id)", monospaced: true)
                if let sessionID = job.sessionID { inspectorValue("Session ID · \(sessionID)", monospaced: true) }
            }
            if let latest {
                inspectorSection("Latest result") {
                    let result = AutomationWorkspaceRowPresentation.make(job: job, latestRun: latest)
                    Text(result.result.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(statusColor(result.result))
                    if let date = latest.claimedAt { inspectorValue(HumanDateFormatting.dateAndTime(date)) }
                    if let error = latest.error, !error.isEmpty { Text(error).foregroundStyle(Color.dockWarning).font(.system(size: 12)) }
                }
                if let request = control.cronReportRequest(for: latest) {
                    Button("Open latest report") { reportRequest = request }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.dockAccent)
                }
            }
        }
        .padding(18)
    }

    private func runsInspector(_ job: CronSummary) -> some View {
        let runs = historyScope == .selected
            ? control.cronRuns.filter { $0.jobID == job.id }
            : control.cronRuns
        return VStack(alignment: .leading, spacing: 12) {
            Picker("History", selection: $historyScope) {
                ForEach(AutomationWorkspaceHistoryScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
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
            Circle().fill(run.error == nil ? Color.dockSuccess : Color.dockWarning).frame(width: 7, height: 7).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.status.capitalized).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText)
                if let claimedAt = run.claimedAt { Text(HumanDateFormatting.dateAndTime(claimedAt)).foregroundStyle(Color.dockMetadataText) }
                if let job { Text(job.name).foregroundStyle(Color.dockSecondaryText).lineLimit(1) }
                if let source = run.source, !source.isEmpty { Text(source).foregroundStyle(Color.dockMetadataText).lineLimit(1) }
                if let error = run.error { Text(error).foregroundStyle(Color.dockWarning).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if control.cronReportRequest(for: run) != nil {
                LucideImage(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.dockAccent).padding(.top, 4)
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

    private func inspectorValue(_ value: String, monospaced: Bool = false) -> some View {
        Text(value)
            .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12))
            .foregroundStyle(Color.dockSecondaryText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
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
        case .failed: Color.dockWarning
        }
    }
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New automation").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.dockPrimaryText)
                Text("Define when Hermes should run and what it should do.").font(.system(size: 12)).foregroundStyle(Color.dockMetadataText)
            }
            creationField("Name", placeholder: "Nightly review", text: $name)
            VStack(alignment: .leading, spacing: 6) {
                creationField("Schedule", placeholder: "every 2h or 0 9 * * *", text: $schedule)
                if !schedule.isEmpty { Text(CronScheduleFormatting.humanReadable(schedule)).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Request").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dockSecondaryText)
                TextField("What should Hermes do?", text: $prompt, axis: .vertical)
                    .lineLimit(4...8)
                    .textFieldStyle(.dockGlass)
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Color.dockWarning).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.borderless).foregroundStyle(Color.dockSecondaryText)
                Spacer()
                Button(isSubmitting ? "Creating…" : "Create automation") { submit() }
                    .buttonStyle(.dockPrimary)
                    .disabled(!valid || isSubmitting || !control.capabilityAvailable("rpc-scheduling"))
            }
        }
        .padding(24)
        .frame(width: 520, height: 430)
        .background(Color.dockCanvas)
    }

    private func creationField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dockSecondaryText)
            TextField(placeholder, text: text).textFieldStyle(.dockGlass)
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
