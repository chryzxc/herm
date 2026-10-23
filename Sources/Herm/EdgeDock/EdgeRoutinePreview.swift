import SwiftUI

struct EdgeRoutinePreview: View {
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
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Text(reference.job.name).dockFont(.body, weight: .semibold).lineLimit(1)
                    Spacer()
                    Button("Back", action: back).buttonStyle(.dockCompact)
                }.padding(.horizontal, 10).frame(width: geometry.size.width, height: 40)
                Divider().overlay(Color.dockBorderLight)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Profile: \(reference.profileID ?? "Launch profile")").dockFont(.metadata)
                            .foregroundStyle(Color.dockSecondaryText)
                        Text(
                            "Execution: \(reference.run?.status ?? reference.job.lastStatus ?? "No recorded run")"
                        )
                        if let execution = reference.run?.error ?? reference.job.lastError {
                            Text(HermesDiagnosticsService.safeSummary(execution))
                        }
                        Text(
                            "Delivery: \(reference.job.details.deliveryError == nil ? "No recorded delivery error" : "Failed")"
                        )
                        if let delivery = reference.job.details.deliveryError {
                            Text(HermesDiagnosticsService.safeSummary(delivery))
                        }
                        if let reason = reference.job.details.pausedReason {
                            Text("Configuration: \(HermesDiagnosticsService.safeSummary(reason))")
                        }
                        if let next = reference.job.nextRun {
                            Text("Next: \(HumanDateFormatting.dateAndTime(next))")
                        }
                        if let report {
                            Text(report.text).textSelection(.enabled)
                        } else if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("View report") {
                                reportTask?.cancel()
                                reportTask = Task { await loadReport() }
                            }.buttonStyle(.dockCompact)
                        }
                        if let error = error ?? control.routineActionErrors[reference.id] {
                            Text(error).foregroundStyle(Color.dockWarning)
                        }
                        HStack {
                            Button(reference.job.enabled ? "Pause…" : "Resume…") {
                                confirming = reference.job.enabled ? "Pause" : "Resume"
                            }.disabled(
                                !control.cronControlAvailable
                                    || control.unavailableRoutineActions.contains(
                                        reference.job.enabled ? "pause" : "resume")
                            )
                            Button("Run now…") { confirming = "Start a new run" }.disabled(
                                !control.canTriggerRoutine(reference))
                        }.buttonStyle(.dockCompact).disabled(control.routineActions.contains(reference.id))
                        if control.routineNeedsReview(reference) {
                            Button("I reviewed the run; allow another…") { confirming = "Record reviewed run" }
                                .buttonStyle(.dockCompact)
                        }
                        Text("Run now starts a new execution. It does not retry delivery.").font(
                            .system(size: 11)
                        ).foregroundStyle(Color.dockSecondaryText)
                        Button(preferences.routinePins.contains(reference.id) ? "Unpin routine" : "Pin routine") {
                            preferences.toggleRoutinePin(reference.id)
                        }.buttonStyle(.dockCompact)
                        Button("Integrations…") {
                            control.integrationDestination = IntegrationDestination(
                                profileID: reference.profileID)
                            openAutomation()
                        }.buttonStyle(.dockCompact)
                    }.dockFont(.body).padding(10).frame(
                        width: geometry.size.width, alignment: .leading)
                }.frame(width: geometry.size.width, height: max(0, geometry.size.height - 86))
                Divider().overlay(Color.dockBorderLight)
                HStack {
                    Spacer()
                    Button("Open Automation", action: openAutomation).buttonStyle(.dockCompact)
                }.dockFont(.body).padding(.horizontal, 10).frame(
                    width: geometry.size.width, height: 44)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .foregroundStyle(Color.dockPrimaryText)
            .onDisappear { reportTask?.cancel() }
            .confirmationDialog(
                "\(confirming ?? "Change") \(reference.job.name)?",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
            ) {
                Button(confirming ?? "Confirm") {
                    let action = confirming
                    confirming = nil
                    Task {
                        if action == "Record reviewed run" {
                            await control.confirmRoutineReview(reference)
                        } else {
                            await control.recoverRoutine(
                                reference, run: action == "Start a new run", paused: action == "Pause")
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
