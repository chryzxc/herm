import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
struct EdgeNotchPerformanceTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func notchUsesNarrowObservationAndIndependentPollers() throws {
        let text = try source("Sources/Herm/EdgeDock/EdgeDockController.swift")
        let view = try #require(text.components(separatedBy: "struct EdgeNotchView: View {").last)
        #expect(!view.contains("@ObservedObject var controlCenter"))
        #expect(view.contains("controlCenter.notchPresentationChanges"))
        #expect(!text.contains("BotService(client: model.controlRPCClient)"))
        #expect(text.contains("EdgeNotchPolling.kanbanInterval"))
        #expect(text.contains("EdgeNotchPolling.deliveryQuestionInterval"))
    }

    @Test func workspaceHostsReuseModelBotOwner() throws {
        let view = try source("Sources/Herm/Conversation/DockPopover.swift")
        let delegate = try source("Sources/Herm/App/HermDelegate.swift")
        let window = try source("Sources/Herm/App/DockWindowController.swift")
        #expect(!view.contains("@StateObject var botMode = BotModeModel()"))
        #expect(delegate.contains("botMode: model.botMode"))
        #expect(window.contains("botMode: model.botMode"))
    }

    @Test func kanbanCadencePreservesForceIdleAndOffline() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        for (elapsed, working, offline, force, expected) in [
            (14.0, true, false, false, false), (15, true, false, false, true),
            (59, false, false, false, false), (60, false, false, false, true),
            (0, false, false, true, true), (100, true, true, true, false),
        ] {
            let result = EdgeNotchPolling.shouldPollKanban(
                now: start.addingTimeInterval(elapsed), lastPoll: start,
                isWorking: working, isOffline: offline, force: force)
            #expect(result == expected)
        }
        let firstPoll = EdgeNotchPolling.shouldPollKanban(
            now: start, lastPoll: nil, isWorking: false, isOffline: false, force: false)
        #expect(firstPoll)
    }

    @Test func notchObservationFiltersUnrelatedChangesAndKeepsRelevantInputs() async {
        let control = ControlCenterModel()
        var updates = 0
        let subscription = control.notchPresentationChanges.sink { updates += 1 }
        control.pendingActionIDs.insert("unrelated")
        control.projects = []
        control.projectionRefreshStates["other"] = ProjectionRefreshState(
            lastSuccess: nil, error: nil, isStale: false, isRefreshing: true)
        await drainRunLoop()
        #expect(updates == 0)
        control.projectionRefreshStates["kanban.global"] = ProjectionRefreshState(
            lastSuccess: nil, error: nil, isStale: false, isRefreshing: true)
        await drainRunLoop()
        #expect(updates == 1)
        control.projectionRefreshStates["kanban.global"]?.lastSuccess = Date()
        await drainRunLoop()
        #expect(updates == 1)
        control.routineProfileID = "research"
        control.cronJobs = []
        control.cronRuns = []
        control.cronRunsByJob = [:]
        await drainRunLoop()
        #expect(updates == 5)
        #expect(control.routineProfileID == "research")
        withExtendedLifetime(subscription) {}
    }

    private func drainRunLoop() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform { continuation.resume() }
        }
    }
}
