import SwiftUI

extension KanbanLane {
    var emptyTitle: String {
        switch self {
        case .triage: "Nothing awaiting triage"
        case .todo: "No queued work"
        case .ready: "Nothing ready to start"
        case .running: "No active work"
        case .review: "Nothing awaiting review"
        case .scheduled: "Nothing scheduled"
        case .blocked: "No blocked work"
        case .done: "No completed work"
        }
    }

    var emptyDetail: String {
        switch self {
        case .triage: "New tasks will appear here for routing."
        case .todo: "Tasks waiting for an owner or next step appear here."
        case .ready: "Assigned tasks ready for execution appear here."
        case .running: "Tasks currently being worked will appear here."
        case .review: "Tasks submitted for review appear here."
        case .scheduled: "Tasks with a future dispatch time appear here."
        case .blocked: "Tasks needing attention or a dependency appear here."
        case .done: "Completed tasks remain visible here when reported."
        }
    }

    var icon: Ph {
        switch self {
        case .triage: .crosshair
        case .todo: .circleDashed
        case .ready: .circle
        case .running: .arrowsClockwise
        case .review: .eye
        case .scheduled: .clock
        case .blocked: .warningOctagon
        case .done: .checkCircle
        }
    }

    var color: Color {
        switch self {
        case .triage: Color.dockWarning
        case .todo, .review: Color.dockSecondaryText
        case .ready, .running, .scheduled: Color.dockAccent
        case .blocked: Color.dockWarning
        case .done: Color.dockSuccess
        }
    }
}
