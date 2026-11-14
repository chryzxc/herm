import Foundation
import Testing

@testable import Herm

/// Opt-in timing for the rail rebuild that runs on every running-session tick:
/// `HERM_SIDEBAR_PROFILE=1 swift test -c release --filter SidebarSnapshotProfileTests`.
@MainActor
struct SidebarSnapshotProfileTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HERM_SIDEBAR_PROFILE"] == "1"))
    func releaseRebuildTimings() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let projectCount = 25
        let sessionCount = 400
        let sessions = (0..<sessionCount).map { index in
            HermesSession(
                id: "s\(index)", profileID: "p", title: "Session \(index)", preview: "preview \(index)",
                startedAt: base, updatedAt: base.addingTimeInterval(Double(index)), messageCount: 10,
                source: "conversation", isHidden: false)
        }
        let projects = (0..<projectCount).map { project in
            ProjectSummary(
                id: "proj\(project)", name: "/tmp/herm-profile/project-\(project)", repoCount: 1,
                sessionCount: 8,
                sessionIDs: Set((0..<8).map { "s\(project * 8 + $0)" }), preview: nil, isActive: false)
        }
        var projectIDBySessionID: [String: String] = [:]
        for index in 200..<300 { projectIDBySessionID["s\(index)"] = "proj\(index % projectCount)" }
        var inputs = SessionNavSidebarSnapshot.Inputs(
            activeSessionID: "s0", activeStatus: .working, profileScopeID: "p", agentDisplayName: "Herm",
            isLoadingSessions: false, isCreatingSession: false, deletingSessionID: nil, renamingSessionID: nil,
            updatingSessionVisibilityID: nil, sessions: sessions, sessionProjectionState: .ready(sessions),
            activeSessions: [], projects: projects, projectIDBySessionID: projectIDBySessionID,
            projectSessionsByProjectID: [:], projectProfileID: "p", isLoadingProjects: false,
            isRefreshingProjectNavigation: false, attention: [], latestActivities: [])

        var snapshot = SessionNavSidebarSnapshot(inputs: inputs)
        let ticks = 500
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for tick in 0..<ticks {
                // Four running sessions take turns bumping `updatedAt`, as their events do.
                let running = tick % 4
                inputs.sessions[running] = HermesSession(
                    id: "s\(running)", profileID: "p", title: "Session \(running)", preview: "tick \(tick)",
                    startedAt: base, updatedAt: base.addingTimeInterval(Double(10_000 + tick)), messageCount: 10,
                    source: "conversation", isHidden: false)
                snapshot = SessionNavSidebarSnapshot(inputs: inputs, reusing: snapshot)
            }
        }
        let perRebuild = elapsed / ticks
        print(
            "sidebar_profile projects=\(projectCount) sessions=\(sessionCount) rebuilds=\(ticks) "
                + "total=\(elapsed) per_rebuild=\(perRebuild) groups=\(snapshot.linkedProjectGroups.count)")
        #expect(snapshot.linkedProjectGroups.count == projectCount)
    }
}
