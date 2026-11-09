import SwiftUI

struct EdgeRoutinePreview: View {
    @MainActor static func executionLabel(for reference: RoutineReference) -> String {
        AutomationWorkspaceRowPresentation.make(job: reference.job, latestRun: reference.run).result.title
    }
    let reference: RoutineReference
    @ObservedObject var control: ControlCenterModel
    @ObservedObject var preferences: CommandCenterPreferencesStore
    let back: () -> Void
    let openAutomation: () -> Void
    @State private var confirming: String?
    @State private var report: EdgeResultContent?
    @State private var error: String?
    @State private var reportTask: Task<Void, Never>?
    @State private var loading = false
    private var currentReference: RoutineReference {
        guard control.routineProfileID == reference.profileID,
            let job = control.cronJobs.first(where: { $0.id == reference.job.id })
        else { return reference }
        return control.routineReference(for: job)
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Text(reference.job.name).dockFont(.body, weight: .semibold).lineLimit(1)
                    Spacer()
                    Button("Back", action: back).buttonStyle(.dockCompact)
                }.dockPadding(.horizontal, 10).frame(width: geometry.size.width, height: 40)
                Divider().overlay(Color.dockBorderLight)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            fact(
                                "Execution",
                                control.routineStatusUnavailable(currentReference)
                                    ? "Status unavailable" : Self.executionLabel(for: currentReference))
                            if let execution = reference.run?.error ?? reference.job.lastError {
                                detail(execution)
                            }
                            fact(
                                "Delivery",
                                reference.job.details.deliveryError == nil ? "No recorded error" : "Failed")
                            if let delivery = reference.job.details.deliveryError { detail(delivery) }
                            if let reason = reference.job.details.pausedReason {
                                fact("Configuration", HermesDiagnosticsService.safeSummary(reason))
                            }
                            if let next = reference.job.nextRun {
                                fact("Next run", HumanDateFormatting.dateAndTime(next))
                            }
                            fact("Profile", reference.profileID ?? "Launch profile")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dockPadding(10)
                        .dockWell()
                        if let report {
                            Text(report.text).textSelection(.enabled)
                        } else if loading {
                            ProgressView().controlSize(.small)
                        }
                        if let error = error ?? control.routineActionErrors[reference.id] {
                            Text(error).foregroundStyle(Color.dockWarning)
                        } else if let feedback = control.routineFeedback(currentReference) {
                            Text(feedback).foregroundStyle(Color.dockSecondaryText)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button("Run now…") { confirming = "Start a new run" }
                                    .buttonStyle(.dockPrimary)
                                    .disabled(!control.canTriggerRoutine(currentReference))
                                Button(reference.job.enabled ? "Pause…" : "Resume…") {
                                    confirming = reference.job.enabled ? "Pause" : "Resume"
                                }.disabled(
                                    !control.cronControlAvailable
                                        || control.unavailableRoutineActions.contains(
                                            reference.job.enabled ? "pause" : "resume")
                                )
                                if report == nil && !loading {
                                    Button("View report") {
                                        reportTask?.cancel()
                                        reportTask = Task { await loadReport() }
                                    }
                                }
                            }.buttonStyle(.dockSecondary).disabled(control.routineActions.contains(reference.id))
                            if control.routineNeedsReview(reference) {
                                Button("I reviewed the run; allow another…") { confirming = "Record reviewed run" }
                                    .buttonStyle(.dockSecondary)
                            }
                            Text("Run now starts a new execution. It does not retry delivery.").dockFont(.metadata)
                                .foregroundStyle(Color.dockSecondaryText)
                        }
                        HStack(spacing: 14) {
                            Button(preferences.routinePins.contains(reference.id) ? "Unpin routine" : "Pin routine") {
                                preferences.toggleRoutinePin(reference.id)
                            }
                            Button("Integrations…") {
                                control.integrationDestination = IntegrationDestination(
                                    profileID: reference.profileID)
                                openAutomation()
                            }
                        }.buttonStyle(.dockLink)
                    }.dockFont(.body).dockPadding(10).frame(
                        width: geometry.size.width, alignment: .leading)
                }.frame(width: geometry.size.width, height: max(0, geometry.size.height - 86))
                Divider().overlay(Color.dockBorderLight)
                HStack {
                    Spacer()
                    Button("Open Automation", action: openAutomation).buttonStyle(.dockCompact)
                }.dockFont(.body).dockPadding(.horizontal, 10).frame(
                    width: geometry.size.width, height: 44)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .foregroundStyle(Color.dockPrimaryText)
            .onDisappear { reportTask?.cancel() }
            .task(id: "\(control.clientBindingGeneration)/\(reference.id)") {
                while !Task.isCancelled {
                    guard await control.refreshRoutineProgress(jobID: reference.job.id, profileID: reference.profileID)
                    else { return }
                    let active = control.routineRunRequestIDs.contains(reference.id) || currentReference.running
                    do { try await Task.sleep(for: .seconds(active ? 3 : 15)) } catch { return }
                }
            }
            .confirmationDialog(
                "\(confirming ?? "Change") \(reference.job.name)?",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
            ) {
                Button(confirming ?? "Confirm") {
                    let action = confirming
                    confirming = nil
                    if action == "Start a new run" {
                        control.runCronNow(currentReference.job)
                    } else {
                        Task {
                            if action == "Record reviewed run" {
                                await control.confirmRoutineReview(currentReference)
                            } else {
                                await control.recoverRoutine(currentReference, run: false, paused: action == "Pause")
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) { confirming = nil }
            } message: {
                Text(
                    "\(confirming == "Record reviewed run" ? "Check the recorded history first. This allows a separate, deliberate new execution and does not resend the earlier request. " : "")Applies to \(reference.job.name) in profile \(reference.profileID ?? "Launch profile")."
                )
            }
        }
    }
    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                .frame(width: 76, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func detail(_ message: String) -> some View {
        Text(HermesDiagnosticsService.safeSummary(message)).dockFont(.metadata)
            .foregroundStyle(Color.dockWarning).padding(.leading, 84)
    }
    private func loadReport() async {
        guard let sessionID = reference.run?.sessionID ?? reference.job.sessionID,
            let service = control.routineReportClient
        else {
            error = "No accessible report session was recorded. Open Automation for the recorded outcome."
            return
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let session = HermesSession(
                id: sessionID, profileID: reference.profileID, title: reference.job.name,
                preview: "", startedAt: nil, messageCount: 0, source: "cron")
            let result = try await service.sessionMessages(
                sessionID: sessionID, profileID: reference.profileID, latest: true)
            guard !Task.isCancelled else { return }
            report = try EdgeResultContent.parse(result, session: session)
            if report == nil { error = "No readable report body was recorded. Open Automation." }
        } catch { self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription) }
    }
}
