import Foundation

/// Every item the status bar can show. Each appears only when its condition is
/// true, and each can be turned off on its own except Needs attention.
enum StatusBarItem: String, CaseIterable, Identifiable {
    case agentActivity, processes, nextSchedule, simulator
    case needsYou, stalled, readyToReview, unpushed, reviewRequested
    case nextMeeting, verification, planProgress, queued

    enum Group: String, CaseIterable {
        case liveWork = "Live work"
        case decisions = "Attention and review"
        case context = "Context"
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agentActivity: "Running work"
        case .processes: "Local dev server"
        case .nextSchedule: "Next schedule"
        case .simulator: "Simulator"
        case .needsYou: "Needs attention"
        case .stalled: "Agent stalled"
        case .readyToReview: "Ready to review"
        case .unpushed: "Unpushed work"
        case .reviewRequested: "Review requested"
        case .nextMeeting: "Next meeting"
        case .verification: "Verification"
        case .planProgress: "Plan progress"
        case .queued: "Queued prompts"
        }
    }

    var detail: String {
        switch self {
        case .agentActivity: "A count of running sessions, routines, and tasks"
        case .processes: "A reachable server started from this workspace’s terminals"
        case .nextSchedule: "The nearest routine in the next 30 minutes"
        case .simulator: "A booted simulator keeps using memory"
        case .needsYou: "Approvals, questions, blocked tasks, and failures"
        case .stalled: "Working with no new output"
        case .readyToReview: "Finished sessions with changes"
        case .unpushed: "Commits that are not on the remote"
        case .reviewRequested: "Pull requests waiting on your review"
        case .nextMeeting: "The nearest event in the next 30 minutes, with Calendar access"
        case .verification: "A failed test run for the current repository state"
        case .planProgress: "Current step in a planned session"
        case .queued: "Prompts waiting for a busy agent"
        }
    }

    var group: Group {
        switch self {
        case .agentActivity, .processes, .nextSchedule, .simulator: .liveWork
        case .needsYou, .stalled, .readyToReview, .unpushed, .reviewRequested: .decisions
        case .nextMeeting, .verification, .planProgress, .queued: .context
        }
    }

    /// The attention queue always appears when it has work.
    var isLocked: Bool { self == .needsYou }

    var isOnByDefault: Bool { isLocked || self == .nextSchedule || self == .nextMeeting }

    /// Where the item's data comes from, so the gateway decides whether it can show.
    var resource: BackendReach.Resource {
        switch self {
        case .unpushed, .verification: .repositoryFiles
        case .processes: .localPreviews
        case .reviewRequested: .pullRequests
        case .nextMeeting: .macCalendar
        case .simulator: .simulator
        default: .hermes
        }
    }
}
