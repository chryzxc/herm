import Foundation
import Testing

@testable import Herm

struct OfficeDeskEventTests {
    @Test func officeActivityOnlyUsesStepsReportedForTheSameProfile() {
        let sessions = ["atlas", "nova"].map { profile in
            SessionSummary(
                id: "runtime-\(profile)", title: profile, state: "working", preview: nil,
                profileID: profile, storedSessionID: "shared")
        }
        let items = sessions.map { session in
            LatestActivityItem(
                id: session.id, sessionID: session.id, sessionTitle: session.title, state: session.state,
                activityName: session.title, timestamp: .distantPast, profileID: session.profileID)
        }
        let unowned = LatestActivityItem(
            id: "unknown", sessionID: "shared", sessionTitle: "", state: "working",
            activityName: "Unverified", timestamp: .distantPast)
        let activity = OfficeSessionActivity(items + [unowned], sessions: sessions)
        #expect(activity.steps[ProfileScopedID(profileID: "atlas", resourceID: "shared")] == [items[0]])
        #expect(activity.steps[ProfileScopedID(profileID: "nova", resourceID: "shared")] == [items[1]])
        #expect(activity.steps.count == 2)
    }

    @Test func recentEventsKeepRealTimeOrderAndDistinctSources() {
        let start = Date(timeIntervalSince1970: 1_000)
        let step = LatestActivityItem(
            id: "same", sessionID: "chat", sessionTitle: "Incident review", state: "working",
            activityName: "Inspect logs", timestamp: start.addingTimeInterval(20))
        let handoff = BotActivityRecord(
            id: "same", originSessionID: "chat", botID: "atlas", botName: "Atlas",
            summary: "Verify the fix", state: .completed, createdAt: start, updatedAt: start.addingTimeInterval(10))
        let reference = BotActivityRecord(
            id: "reference", originSessionID: "chat", botID: "kanban-reference", botName: "Kanban",
            summary: "Linked task", state: .working, createdAt: start, updatedAt: start, linkedCardID: "card")
        let task = KanbanTaskSummary(
            id: "card", title: "Deploy fix", status: "review", detail: nil, priority: nil, assignee: "atlas",
            latestEventKind: "submitted", latestEventNote: "Ready for review", latestEventAt: start)
        let result = OfficeDeskEvent.recent(
            activity: [step, step], handoffs: [handoff, reference], tasks: [task],
            originTitles: ["chat": "Incident review"])
        #expect(result.map(\.kind) == [.step, .handoff, .kanban])
        #expect(result.map(\.title) == ["Inspect logs", "Verify the fix", "Ready for review"])
        #expect(result[1].context == "Incident review → Atlas · Completed")
    }

    @Test func frequentSessionStepsCannotCrowdOutHandoffs() {
        let start = Date(timeIntervalSince1970: 1_000)
        let activity = (1...20).map {
            LatestActivityItem(
                id: "\($0)", sessionID: "chat", sessionTitle: "Chat", state: "working",
                activityName: "Step \($0)", timestamp: start.addingTimeInterval(Double($0)))
        }
        let handoff = BotActivityRecord(
            originSessionID: "chat", botID: "atlas", botName: "Atlas", summary: "Try this",
            state: .working, createdAt: start, updatedAt: start)
        let result = OfficeDeskEvent.recent(activity: activity, handoffs: [handoff], tasks: [], originTitles: [:])
        #expect(result.count == 13)
        #expect(result.first?.title == "Step 20")
        #expect(result.last?.kind == .handoff)
    }
}
