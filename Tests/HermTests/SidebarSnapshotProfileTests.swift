import Foundation
import Testing

@testable import Herm

/// Opt-in timing for the rail rebuild that runs on every running-session tick:
/// `HERM_SIDEBAR_PROFILE=1 swift test -c release --filter SidebarSnapshotProfileTests`.
@MainActor
struct SidebarSnapshotProfileTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HERM_SIDEBAR_PROFILE"] == "1"))
    func releaseRebuildTimings() async throws {
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

        let model = DockModel(initialSessionID: "s0", loadArchives: false)
        defer { model.shutdown() }
        let control = ControlCenterModel()
        control.projects = projects
        control.projectIDBySessionID = projectIDBySessionID
        model.sessions = sessions
        model.sessionProjectionState = .ready(sessions)
        let sidebar = SessionNavSidebarModel(
            model: model, control: control,
            store: WorkspaceStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let passes = 12
        for synchronous in [true, false] {
            model.sessions = sessions
            model.sessionProjectionState = .ready(sessions)
            sidebar.refresh()
            let started = mainThreadCPUMilliseconds()
            for tick in 0..<passes {
                let title = "Tick \(synchronous)-\(tick)"
                model.sessions[tick % 4] = HermesSession(
                    id: "s\(tick % 4)", profileID: "p", title: title, preview: "",
                    startedAt: base, updatedAt: base.addingTimeInterval(Double(10_000 + tick)), messageCount: 10,
                    source: "conversation", isHidden: false)
                model.sessionProjectionState = .ready(model.sessions)
                if synchronous { sidebar.refresh() }
                for _ in 0..<80 where sidebar.snapshot.conversations.first?.title != title {
                    try await Task.sleep(for: .milliseconds(25))
                }
                try #require(sidebar.snapshot.conversations.first?.title == title)
            }
            let cpu = mainThreadCPUMilliseconds() - started
            print("sidebar_pipeline synchronous=\(synchronous) updates=\(passes) main_cpu_ms=\(cpu)")
        }
    }
}
