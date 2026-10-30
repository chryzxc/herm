import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceActivitySidebar {
    var automationsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            cronStatusLine
            cronWorkspace
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { reconcileSelectedCronJob() }
    }

    var automationIsRefreshing: Bool {
        control.isRefreshing || control.refreshState(for: "cron.history")?.isRefreshing == true
    }

    func refreshAutomations() {
        control.refresh()
        control.refreshCronRuns()
    }

    func reconcileSelectedCronJob() {
        selectedCronJobID = AutomationHistoryPresentation.selectedJobID(
            currentID: selectedCronJobID,
            jobs: control.cronJobs
        )
    }

    var cronStatusLine: some View {
        let activeCount = control.cronJobs.filter(\.enabled).count
        let successfulRuns = control.cronRuns.filter(cronRunIsSuccessful).count
        let failedRuns = control.cronRuns.count - successfulRuns
        let successText =
            control.cronRuns.isEmpty
            ? "No run history"
            : "\(Int((Double(successfulRuns) / Double(control.cronRuns.count)) * 100))% success"
        let nextRun = control.cronJobs.first(where: { $0.nextRun != nil })?.nextRun.map(HumanDateFormatting.dateAndTime)

        return HStack(spacing: 8) {
            Text("\(activeCount) active")
            Text("·")
            Text(successText)
                .foregroundStyle(failedRuns > 0 ? Color.dockWarning : Color.dockMetadataText)
            if let nextRun {
                Text("·")
                Text("Next \(nextRun)")
            }
            Spacer(minLength: 0)
        }
        .dockFont(.metadata, weight: .regular, design: .monospaced)
        .foregroundStyle(Color.dockMetadataText)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(minHeight: 24, alignment: .leading)
    }

    var cronWorkspace: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 22) {
                cronSchedulesColumn
                    .frame(width: 350, alignment: .topLeading)
                cronDetailColumn
                    .frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 22) {
                cronSchedulesColumn
                cronDetailColumn
            }
        }
    }

    var cronSchedulesColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            cronSectionHeading("Schedules", count: control.cronJobs.count, icon: .calendarDots)
            if control.cronJobs.isEmpty {
                emptyState(
                    icon: .clock, title: "No schedules",
                    detail: "Create an automation when work needs to run without you.")
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(control.cronJobs) { job in
                            cronScheduleRow(job, isSelected: selectedCronJobID == job.id)
                        }
                    }
                }
                .frame(maxHeight: 520)
            }
        }
    }

    var cronDetailColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let selectedCronJobID,
                let job = control.cronJobs.first(where: { $0.id == selectedCronJobID })
            {
                cronDetailSummary(job)
                cronHistorySection
            } else {
                emptyState(
                    icon: .cursorClick, title: "Select a schedule",
                    detail: "Choose a schedule to inspect its cadence, latest result, and run history.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func cronDetailSummary(_ job: CronSummary) -> some View {
        let health = AutomationHealthPresentation.make(
            job: job,
            runs: control.cronRuns,
            capabilityAvailable: true,
            mcpErrorObserved: false
        )
        let latestRun = control.cronRuns.first { $0.jobID == job.id }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(job.name)
                    .dockFont(.pageTitle, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(health.state.rawValue.uppercased())
                    .dockFont(.compactStatus, weight: .bold)
                    .foregroundStyle(
                        health.state == .healthy
                            ? Color.dockSuccess : health.state == .degraded ? Color.dockWarning : Color.dockMetadataText
                    )
            }
            Text(job.enabled ? "Enabled and scheduled" : "Paused")
                .dockFont(.metadata, weight: .medium)
                .foregroundStyle(job.enabled ? Color.dockSuccess : Color.dockMetadataText)

            Divider().overlay(Color.dockBorderLight)
            cronDetailRow("Schedule", value: CronScheduleFormatting.humanReadable(job.schedule))
            cronDetailRow("Expression", value: job.schedule, monospaced: true)
            cronDetailRow(
                "Next run", value: job.nextRun.map(HumanDateFormatting.dateAndTime) ?? "Not reported by Hermes")
            cronDetailRow("Job ID", value: job.id, monospaced: true)
            if let delivery = job.delivery, !delivery.isEmpty {
                cronDetailRow("Delivery", value: delivery.uppercased())
            }
            if let prompt = job.prompt, !prompt.isEmpty {
                cronDetailRow("Request", value: prompt)
            }
            if let latestRun {
                cronDetailRow(
                    "Last run", value: latestRun.claimedAt.map(HumanDateFormatting.dateAndTime) ?? latestRun.id)
                HStack(spacing: 6) {
                    Circle().fill(cronRunIsSuccessful(latestRun) ? Color.dockSuccessFill : Color.dockWarningFill).frame(
                        width: 5, height: 5)
                    Text("Last status")
                    Text(latestRun.status.uppercased())
                }
                .dockFont(.metadata, weight: .medium)
                .foregroundStyle(cronRunIsSuccessful(latestRun) ? Color.dockSuccess : Color.dockWarning)
                if let error = latestRun.error, !error.isEmpty {
                    Text(error)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(3)
                }
            }
            if let latestRun, let request = control.cronReportRequest(for: latestRun) {
                Divider().overlay(Color.dockBorderLight)
                Button("Open latest report") { cronReportRequest = request }
                    .buttonStyle(.dockCompact)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockAccent)
            }
        }
        .dockPadding(.bottom, 6)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    func cronDetailRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: 72, alignment: .leading)
                .foregroundStyle(Color.dockMetadataText)
            Text(value)
                .dockFont(size: monospaced ? 11 : 12, design: monospaced ? .monospaced : .default)
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    var cronHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DockIcon(.pulse)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockAccent)
                Text("Run history")
                    .dockFont(.conversation, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                Text("\(filteredCronRuns.count)")
                    .dockFont(.body, weight: .semibold, design: .monospaced)
                    .foregroundStyle(Color.dockMetadataText)
                Spacer()
                DockTabBar(options: AutomationHistoryScope.allCases, selection: $automationHistoryScope, title: \.title)
            }
            .dockPadding(.bottom, 5)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            if let state = control.refreshState(for: "cron.history"), state.isStale {
                Text("Showing the last successful history while Hermes reconnects.")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockWarning)
            }
            if !control.cronHistoryAvailable && control.cronRuns.isEmpty {
                Text("Hermes automation history is unavailable through the installed CLI.")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if filteredCronRuns.isEmpty {
                Text(
                    automationHistoryScope == .selected
                        ? "No runs recorded for this schedule." : "No automation runs recorded."
                )
                .dockFont(.body)
                .foregroundStyle(Color.dockMetadataText)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredCronRuns) { run in
                            if let request = control.cronReportRequest(for: run) {
                                Button {
                                    cronReportRequest = request
                                } label: {
                                    cronRunRow(run, canViewReport: true)
                                }
                                .buttonStyle(.dockHover)
                                .help("View this run's report")
                            } else {
                                cronRunRow(run, canViewReport: false)
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
    }

    var filteredCronRuns: [CronRunSummary] {
        AutomationHistoryPresentation.runs(
            control.cronRuns,
            scope: automationHistoryScope,
            selectedJobID: selectedCronJobID
        )
    }

    var cronHistoryColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            cronSectionHeading("Run history", count: control.cronRuns.count, icon: .pulse)
            if let state = control.refreshState(for: "cron.history"), state.isStale {
                Text("Showing the last successful history while Hermes reconnects. \(state.error ?? "")")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .dockPadding(.bottom, 3)
            }
            if !control.cronHistoryAvailable && control.cronRuns.isEmpty {
                Text("Hermes automation history is unavailable through the installed CLI.")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if control.cronRuns.isEmpty {
                Text("No automation runs recorded.")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(control.cronRuns) { run in
                            if let request = control.cronReportRequest(for: run) {
                                Button {
                                    cronReportRequest = request
                                } label: {
                                    cronRunRow(run, canViewReport: true)
                                }
                                .buttonStyle(.dockHover)
                                .help("View this run's report")
                            } else {
                                cronRunRow(run, canViewReport: false)
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
    }

    func cronSectionHeading(_ title: String, count: Int, icon: Ph) -> some View {
        HStack(spacing: 8) {
            DockIcon(icon)
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockAccent)
            Text(title)
                .dockFont(.conversation, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
            Text("\(count)")
                .dockFont(.body, weight: .semibold, design: .monospaced)
                .foregroundStyle(Color.dockMetadataText)
            Spacer()
        }
        .dockPadding(.bottom, 5)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    var automationComposer: some View {
        DockModal(
            icon: .magicWand, title: "New Automation", subtitle: "Set the intent once; Hermes will keep the cadence.",
            width: 520
        ) {
            HStack(alignment: .top, spacing: 10) {
                labeledField("Name") {
                    DockTextField("Morning review", text: $automationName).textFieldStyle(.dockGlass)
                }
                labeledField("Schedule", hint: "every 2h · 0 9 * * *") {
                    DockTextField("When should Hermes run this?", text: $automationSchedule).textFieldStyle(.dockGlass)
                }
            }
            labeledField("Request") {
                DockTextField("What should Hermes do?", text: $automationPrompt, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.dockGlass)
            }
        } footer: {
            modalActions(
                primaryTitle: "Review and Create",
                isDisabled: !canCreateAutomation || !control.cronControlAvailable,
                isPending: false,
                onCancel: { isShowingAutomationComposer = false }
            ) {
                isShowingAutomationConfirmation = true
            }
        }
    }

    func cronScheduleRow(_ job: CronSummary, isSelected: Bool) -> some View {
        let health = AutomationHealthPresentation.make(
            job: job,
            runs: control.cronRuns,
            // A loaded job is not unavailable just because a mutation capability is missing.
            capabilityAvailable: true,
            mcpErrorObserved: false
        )
        return HStack(spacing: 10) {
            Circle()
                .fill(job.enabled ? Color.dockSuccessFill : Color.dockMetadataText)
                .frame(width: 8, height: 8)
            Button {
                selectedCronJobID = job.id
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(job.name)
                            .dockFont(.navigation, weight: isSelected ? .medium : .regular)
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(1)
                        if !job.enabled {
                            Text("PAUSED")
                                .dockFont(.metadata, weight: .bold)
                                .tracking(0.5)
                                .foregroundStyle(Color.dockWarning)
                        }
                    }
                    Text(CronScheduleFormatting.humanReadable(job.schedule))
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                    if let nextRun = job.nextRun {
                        Text("Next \(HumanDateFormatting.dateAndTime(nextRun))")
                            .dockFont(.compactStatus, weight: .regular, design: .monospaced)
                            .foregroundStyle(Color.dockMetadataText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dockPadding(.trailing, 18)
                .overlay(alignment: .trailing) {
                    DockIcon(.caretRight, size: 12, color: .dockSecondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)

            Text(health.state.rawValue.uppercased())
                .dockFont(.metadata, weight: .bold)
                .foregroundStyle(
                    health.state == .healthy
                        ? Color.dockSuccess : health.state == .degraded ? Color.dockWarning : Color.dockMetadataText
                )
                .lineLimit(1)

            if control.capabilityAvailable("cron.runNow") {
                Button {
                    cronRunRequest = job
                    isShowingCronRunConfirmation = true
                } label: {
                    Group {
                        if control.routineRunRequestIDs.contains(control.routineReference(for: job).id) {
                            ProgressView().controlSize(.small)
                        } else {
                            DockIcon(.play, weight: .fill)
                                .dockFont(.body, weight: .semibold)
                        }
                    }
                    .foregroundStyle(Color.dockAccent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .disabled(!control.canTriggerRoutine(control.routineReference(for: job)))
                .help(control.routineFeedback(control.routineReference(for: job)) ?? "Run \(job.name) now")
                .accessibilityLabel("Run \(job.name) now")
                .accessibilityValue(control.routineFeedback(control.routineReference(for: job)) ?? "")
            }

            DockMenu {
                cronContextActions(job)
            } label: {
                DockIcon(.dotsThree)
                    .dockFont(.conversation, weight: .medium)
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .help("More actions for \(job.name)")
        }
        .dockPadding(.leading, 10)
        .dockPadding(.trailing, 2)
        .frame(minHeight: 66)
        .background(isSelected ? Color.dockAccent.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
        .contextMenu { cronContextActions(job) }
    }

    @ViewBuilder
    func cronContextActions(_ job: CronSummary) -> some View {
        if control.capabilityAvailable("cron.runNow") {
            Button("Run now", icon: .play) {
                cronRunRequest = job
                isShowingCronRunConfirmation = true
            }
            .disabled(!control.canTriggerRoutine(control.routineReference(for: job)))
        }
        if control.capabilityAvailable("cron.edit"), !job.editableFields.isEmpty {
            Button("Edit", icon: .pencilSimple) { cronEditJob = job }
        }
        if control.cronControlAvailable {
            Divider()
            Button("Remove", icon: .trash, role: .destructive) {
                cronRemovalRequest = job
                isShowingCronRemovalConfirmation = true
            }
        }
    }

    func cronJobActions(_ job: CronSummary) -> some View {
        HStack(spacing: 14) {
            if control.capabilityAvailable("cron.runNow") {
                Button {
                    cronRunRequest = job
                    isShowingCronRunConfirmation = true
                } label: {
                    DockActionLabel(
                        title: "RUN NOW", pendingTitle: "STARTING…",
                        isPending: control.routineRunRequestIDs.contains(control.routineReference(for: job).id))
                }
                .disabled(!control.canTriggerRoutine(control.routineReference(for: job)))
                .help(control.routineFeedback(control.routineReference(for: job)) ?? "Run \(job.name) now")
            } else {
                Text("RUN NOW UNAVAILABLE")
                    .dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(Color.dockMetadataText)
                    .help("The installed Hermes CLI does not advertise the run-now automation capability.")
            }
            if control.capabilityAvailable("cron.edit"), !job.editableFields.isEmpty {
                Button {
                    cronEditJob = job
                } label: {
                    DockActionLabel(
                        title: "EDIT", pendingTitle: "SAVING…",
                        isPending: control.isActionPending(control.cronActionID("edit", job: job)))
                }
                .disabled(control.isActionPending(control.cronActionID("edit", job: job)))
            }
            if control.cronControlAvailable {
                Button {
                    cronRemovalRequest = job
                    isShowingCronRemovalConfirmation = true
                } label: {
                    DockActionLabel(
                        title: "REMOVE", pendingTitle: "REMOVING…",
                        isPending: control.isActionPending(control.cronActionID("remove", job: job)),
                        tint: Color.dockWarning)
                }
                .foregroundStyle(Color.dockWarning)
                .disabled(control.isActionPending(control.cronActionID("remove", job: job)))
            }
            Spacer()
        }
        .buttonStyle(.dockHover)
        .dockFont(.body, weight: .semibold)
        .foregroundStyle(Color.dockAccent)
    }

    func cronReportCard(_ job: CronSummary) -> some View {
        let latestRun = control.cronRuns.first { $0.jobID == job.id }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                DockIcon(job.enabled ? .clock : .clock)
                    .dockFont(.conversation, weight: .semibold)
                    .foregroundStyle(job.enabled ? Color.dockSuccess : Color.dockMetadataText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name)
                        .dockFont(.navigation, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(2)
                    Text(job.enabled ? "ENABLED AND SCHEDULED" : "PAUSED")
                        .dockFont(.metadata, weight: .semibold)
                        .tracking(0.45)
                        .foregroundStyle(job.enabled ? Color.dockSuccess : Color.dockMetadataText)
                }
                Spacer(minLength: 0)
            }

            Divider()
                .overlay(Color.dockBorderLight)
                .dockPadding(.vertical, 5)

            reportRow("SCHEDULE", value: CronScheduleFormatting.humanReadable(job.schedule))
            reportRow("AUTOMATION", value: job.schedule)
            reportRow("NEXT RUN", value: job.nextRun.map(HumanDateFormatting.dateAndTime) ?? "Not reported by Hermes")
            reportRow("JOB ID", value: job.id)
            if let delivery = job.delivery, !delivery.isEmpty {
                reportRow("DELIVERY", value: delivery.uppercased())
            }
            if let prompt = job.prompt, !prompt.isEmpty {
                reportRow("REQUEST", value: prompt)
            }
            if let latestRun {
                reportRow("LAST RUN", value: latestRun.claimedAt.map(HumanDateFormatting.dateAndTime) ?? latestRun.id)
                HStack(spacing: 6) {
                    Circle().fill(cronRunIsSuccessful(latestRun) ? Color.dockSuccessFill : Color.dockWarningFill).frame(
                        width: 5, height: 5)
                    Text("LAST STATUS")
                    Text(latestRun.status.uppercased())
                }
                .dockFont(.metadata, weight: .semibold)
                .foregroundStyle(cronRunIsSuccessful(latestRun) ? Color.dockSuccess : Color.dockWarning)
                if let error = latestRun.error, !error.isEmpty {
                    Text(error)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(3)
                }
            } else {
                reportRow("LAST RUN", value: "No execution recorded")
            }
            if let report = job.report, !report.isEmpty {
                Divider().overlay(Color.dockBorderLight)
                Button {
                    withAnimation(.dockEase(duration: 0.2)) {
                        if expandedCronReportIDs.contains(job.id) {
                            expandedCronReportIDs.remove(job.id)
                        } else {
                            expandedCronReportIDs.insert(job.id)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        DockIcon(expandedCronReportIDs.contains(job.id) ? .caretDown : .caretRight)
                            .dockFont(.compactStatus, weight: .bold)
                        Text(expandedCronReportIDs.contains(job.id) ? "HIDE REPORT" : "VIEW LATEST REPORT")
                            .dockFont(.metadata, weight: .semibold)
                    }
                    .foregroundStyle(Color.dockAccent)
                }
                .buttonStyle(.dockHover)
                if expandedCronReportIDs.contains(job.id) {
                    MarkdownMessageView(markdown: report)
                        .dockPadding(10)
                        .background(
                            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                .dockSurfaceFill(Color.dockSurface2.opacity(0.72))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else if job.sessionID != nil {
                Divider().overlay(Color.dockBorderLight)
                VStack(alignment: .leading, spacing: 6) {
                    Text("REPORT AVAILABLE")
                        .dockFont(.metadata, weight: .semibold)
                        .foregroundStyle(Color.dockSuccess)
                    Text("Hermes saved the full output in this job's latest run session.")
                        .dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("OPEN LATEST REPORT") {
                        if let sessionID = job.sessionID {
                            cronReportRequest = CronReportRequest(job: job, sessionID: sessionID)
                        }
                    }
                    .buttonStyle(.dockCompact)
                    .dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(Color.dockAccent)
                }
            } else {
                Divider().overlay(Color.dockBorderLight)
                VStack(alignment: .leading, spacing: 6) {
                    Text("REPORT BODY UNAVAILABLE")
                        .dockFont(.metadata, weight: .semibold)
                        .foregroundStyle(Color.dockMetadataText)
                    Text(
                        "Hermes recorded this run, but the installed CLI only provides execution status and delivery metadata—not the response body. "
                            + (job.delivery?.lowercased() == "origin"
                                ? "This job delivers its result to its origin chat." : "")
                    )
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("RETURN TO CHAT") {
                        onClose()
                        model.requestComposerFocus()
                    }
                    .buttonStyle(.dockCompact)
                    .dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(Color.dockAccent)
                }
            }
        }
    }

    func reportRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label == label.uppercased() ? label.lowercased().capitalized : label)
                .frame(width: 88, alignment: .leading)
                .foregroundStyle(Color.dockMetadataText)
            Text(value)
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(2)
        }
        .dockPadding(.vertical, 2)
        .dockFont(.metadata)
    }

    func cronRunIsSuccessful(_ run: CronRunSummary) -> Bool {
        let status = run.status.lowercased()
        return ["ok", "success", "successful", "completed", "complete", "succeeded"].contains(status)
    }

    func cronRunRow(_ run: CronRunSummary, canViewReport: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(cronRunIsSuccessful(run) ? Color.dockSuccessFill : Color.dockWarningFill)
                .frame(width: 7, height: 7)
                .dockPadding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(run.status.uppercased())
                        .dockFont(.body, weight: .medium)
                        .foregroundStyle(Color.dockPrimaryText)
                    Spacer(minLength: 4)
                    if canViewReport {
                        HStack(spacing: 4) {
                            Text("REPORT")
                            DockIcon(.caretRight)
                                .dockFont(.metadata, weight: .bold)
                        }
                        .dockFont(.compactStatus, weight: .semibold)
                        .foregroundStyle(Color.dockAccent)
                    }
                }
                if let claimedAt = run.claimedAt {
                    Text(HumanDateFormatting.dateAndTime(claimedAt))
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                }
                if let jobID = run.jobID {
                    if let job = control.cronJobs.first(where: { $0.id == jobID }) {
                        Text(job.name)
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(1)
                    }
                    Text(jobID)
                        .dockFont(.compactStatus, weight: .regular, design: .monospaced)
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                }
                if let error = run.error {
                    Text(error)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(3)
                }
            }
        }
        .dockPadding(.vertical, 10)
        .dockPadding(.horizontal, 4)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    func dockTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .dockFont(.navigation)
            .foregroundStyle(Color.dockPrimaryText)
            .dockPadding(.horizontal, 10)
            .dockPadding(.vertical, 8)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .dockSurfaceFill(Color.dockSurface, stroke: Color.dockBorder, lineWidth: 0.5)
            )
    }

    var canCreateAutomation: Bool {
        !automationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !automationSchedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !automationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var tabBadges: ControlTabBadgeState {
        ControlTabBadgeState.make(
            changeCount: workflow.repository.conflictedFiles > 0
                ? workflow.repository.conflictedFiles : workflow.repository.changedFiles
        )
    }

    func badgeCount(for tab: ControlTab) -> Int {
        tabBadges.count(for: tab)
    }

    func badgeLabel(for tab: ControlTab) -> String {
        let count = badgeCount(for: tab)
        return count > 99 ? "99+" : "\(count)"
    }

    func badgeIsUrgent(for tab: ControlTab) -> Bool {
        tabBadges.isUrgent(for: tab)
    }
}
