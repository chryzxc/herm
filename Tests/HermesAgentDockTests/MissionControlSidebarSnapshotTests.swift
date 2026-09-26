import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct MissionControlSidebarSnapshotTests {
    private func session(
        _ id: String,
        title: String = "Session",
        preview: String = "",
        updatedAt: Date? = nil,
        profileID: String? = nil,
        source: String = "conversation"
    ) -> HermesSession {
        HermesSession(
            id: id,
            profileID: profileID,
            title: title,
            preview: preview,
            startedAt: nil,
            updatedAt: updatedAt,
            messageCount: 1,
            source: source,
            isHidden: false
        )
    }

    private func project(
        _ id: String,
        name: String,
        sessionIDs: Set<String> = [],
        sessionCount: Int = 0
    ) -> ProjectSummary {
        ProjectSummary(
            id: id,
            name: name,
            repoCount: 1,
            sessionCount: sessionCount,
            sessionIDs: sessionIDs,
            preview: nil,
            isActive: false
        )
    }

    private func summary(_ id: String, title: String = "Summary", updatedAt: Date? = nil) -> SessionSummary {
        SessionSummary(id: id, title: title, state: "completed", preview: nil, updatedAt: updatedAt)
    }

    private func inputs(
        sessions: [HermesSession] = [],
        projects: [ProjectSummary] = [],
        projectIDBySessionID: [String: String] = [:],
        projectSessionsByProjectID: [String: [SessionSummary]] = [:],
        attention: [AttentionItem] = [],
        latestActivities: [LatestActivityItem] = [],
        profileScopeID: String? = "profile-main",
        projectProfileID: String? = "profile-main"
    ) -> MissionControlSidebarSnapshot.Inputs {
        .init(
            activeSessionID: nil,
            activeStatus: nil,
            profileScopeID: profileScopeID,
            agentDisplayName: "Hermes",
            isLoadingSessions: false,
            isCreatingSession: false,
            deletingSessionID: nil,
            renamingSessionID: nil,
            updatingSessionVisibilityID: nil,
            sessions: sessions,
            sessionProjectionState: .ready(sessions),
            activeSessions: [],
            projects: projects,
            projectIDBySessionID: projectIDBySessionID,
            projectSessionsByProjectID: projectSessionsByProjectID,
            projectProfileID: projectProfileID,
            isRefreshing: false,
            isRefreshingProjectNavigation: false,
            attention: attention,
            latestActivities: latestActivities
        )
    }

    @Test func renderableProjectsOwnGroupsAndSyntheticBucketsFallThroughToUnlinked() {
        let date = Date(timeIntervalSince1970: 100)
        let snapshot = MissionControlSidebarSnapshot(inputs: inputs(
            sessions: [session("s1", updatedAt: date), session("s2", updatedAt: date)],
            projects: [
                project("p1", name: "/repos/Alpha", sessionIDs: ["s1"], sessionCount: 1),
                project("p_0badc0de", name: "tmp", sessionIDs: ["s2"], sessionCount: 1)
            ],
            projectSessionsByProjectID: ["p_0badc0de": [summary("s2")]]
        ))

        #expect(snapshot.linkedProjectGroups.map(\.id) == ["project:p1"])
        #expect(snapshot.linkedProjectGroups.first?.title == "Alpha")

        #expect(snapshot.conversations.map(\.id).sorted() == ["s1", "s2"])
        let fallenThrough = snapshot.conversations.first { $0.id == "s2" }
        #expect(fallenThrough?.source == "conversation")
    }

    @Test func gatewaySummariesFillProjectsAndNewerSavedSessionsKeepTheirTitle() {
        let newer = Date(timeIntervalSince1970: 500)
        let older = Date(timeIntervalSince1970: 100)
        let snapshot = MissionControlSidebarSnapshot(inputs: inputs(
            sessions: [session("s1", title: "Saved newer", updatedAt: newer)],
            projects: [project("p1", name: "/repos/Alpha", sessionIDs: ["s1"], sessionCount: 2)],
            projectSessionsByProjectID: ["p1": [
                summary("s1", title: "Stale summary", updatedAt: older),
                summary("s9", title: "Gateway only")
            ]]
        ))

        let group = snapshot.linkedProjectGroups.first
        #expect(group?.sessions.map(\.id).sorted() == ["s1", "s9"])
        let saved = group?.sessions.first { $0.id == "s1" }
        #expect(saved?.title == "Saved newer")
        let gatewayOnly = group?.sessions.first { $0.id == "s9" }
        #expect(gatewayOnly?.title == "Gateway only")
        #expect(gatewayOnly?.source == "project")
    }

    @Test func projectMembershipAlsoComesFromTheSessionIndex() {
        let snapshot = MissionControlSidebarSnapshot(inputs: inputs(
            sessions: [session("s1", updatedAt: Date(timeIntervalSince1970: 10))],
            projects: [project("p1", name: "/repos/Alpha")],
            projectIDBySessionID: ["s1": "p1"]
        ))

        #expect(snapshot.linkedProjectGroups.first?.sessions.map(\.id) == ["s1"])
        #expect(snapshot.linkedSessionIDs == ["s1"])
        #expect(snapshot.projectNameBySessionID["s1"] == "Alpha")
    }

    @Test func conversationsDeduplicateByIDAndSortNewestFirstWithStableTiebreak() {
        let early = Date(timeIntervalSince1970: 10)
        let late = Date(timeIntervalSince1970: 20)
        let snapshot = MissionControlSidebarSnapshot(inputs: inputs(
            sessions: [
                session("b", updatedAt: early),
                session("a", updatedAt: early),
                session("z", updatedAt: late)
            ],
            projects: [project("p1", name: "/repos/Alpha", sessionIDs: ["z", "b"])]
        ))

        #expect(snapshot.conversations.map(\.id) == ["z", "a", "b"])
    }

    @Test func attentionDotsPreferOpenAttentionAndMapActivityStates() {
        let attention = [
            AttentionItem(
                id: "a1",
                reference: ControlReference(source: .hermesApproval, sourceID: "a1", sessionID: "s1"),
                kind: .approval,
                title: "Approval",
                detail: "",
                createdAt: Date(timeIntervalSince1970: 0),
                state: .open,
                actions: []
            )
        ]
        let activities = [
            LatestActivityItem(id: "l1", sessionID: "s2", sessionTitle: "T", state: "failed", activityName: "tool", timestamp: Date(timeIntervalSince1970: 5)),
            LatestActivityItem(id: "l2", sessionID: "s3", sessionTitle: "T", state: "running", activityName: "permission request", timestamp: Date(timeIntervalSince1970: 6))
        ]
        let snapshot = MissionControlSidebarSnapshot(inputs: inputs(attention: attention, latestActivities: activities))

        #expect(snapshot.attentionDots["s1"] == .warning)
        #expect(snapshot.attentionDots["s2"] == .failure)
        #expect(snapshot.attentionDots["s3"] == .warning)
    }

    @Test func identicalInputsProduceIdenticalSnapshots() {
        func build() -> MissionControlSidebarSnapshot.Inputs {
            inputs(
                sessions: [session("s1", updatedAt: Date(timeIntervalSince1970: 1))],
                projects: [project("p1", name: "/repos/Alpha", sessionIDs: ["s1"])]
            )
        }

        #expect(MissionControlSidebarSnapshot(inputs: build()) == MissionControlSidebarSnapshot(inputs: build()))
        #expect(build() == build())
    }

    @Test func emptyProjectsAreHiddenAndProjectsFollowLatestActivity() {
        let now = Date()
        let snapshot = MissionControlSidebarSnapshot(inputs: inputs(
            sessions: [
                session("old", updatedAt: now.addingTimeInterval(-600)),
                session("new", updatedAt: now)
            ],
            projects: [
                project("a", name: "/repo/alpha", sessionIDs: ["old"], sessionCount: 1),
                project("b", name: "/repo/beta", sessionIDs: ["new"], sessionCount: 1),
                project("c", name: "/repo/empty")
            ]
        ))

        #expect(snapshot.linkedProjectGroups.map(\.title) == ["beta", "alpha"])
    }
}
