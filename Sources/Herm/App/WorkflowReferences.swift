import Foundation

struct PinnedSource: Codable, Identifiable, Equatable {
    var id = UUID()
    let origin: QuickDestination
    let url: String
    var label: String?
    var revisionID: String? = nil
}

struct RoutineReference: Identifiable, Equatable {
    let profileID: String?
    let job: CronSummary
    let run: CronRunSummary?
    var id: String { "routine/\(profileID ?? "")/\(job.id)" }
    @MainActor var running: Bool {
        AutomationWorkspaceRowPresentation.make(job: job, latestRun: run).result == .running
    }
    @MainActor var needsAttention: Bool {
        (!running
            && AutomationWorkspaceRowPresentation.make(job: job, latestRun: run).result == .failed)
            || job.details.deliveryError != nil || job.details.pausedReason != nil
    }
    @MainActor var row: EdgeNotchTask {
        EdgeNotchTask(
            id: id, title: job.name, phase: needsAttention ? .attention : running ? .working : .pending,
            statusLabel: running
                ? "Running" : needsAttention ? "Routine needs attention" : "Pinned routine",
            detail: job.details.deliveryError != nil
                ? "Delivery needs review" : job.lastError ?? job.schedule,
            updatedAt: (run?.claimedAt ?? job.lastRunAt).flatMap { HumanDateFormatting.date($0) },
            isCurrent: false, isStatusCurrent: true, session: nil, routine: self)
    }
}

struct IntegrationDestination: Identifiable {
    var id = UUID()
    let profileID: String?
    var name: String? = nil
}
