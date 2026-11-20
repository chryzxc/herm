import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
struct ProjectionRefreshPublicationTests {
    private func makeModel() -> ControlCenterModel {
        ControlCenterModel(presentationDefaults: UserDefaults(suiteName: "projection-\(UUID().uuidString)")!)
    }

    @Test func beginningSeveralProjectionsPublishesOncePerDictionary() {
        let model = makeModel()
        model.recordProjectionSuccess("sessions", count: 3)
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }

        model.beginProjectionRefreshes(["sessions", "agents", "projects", "cron.jobs", "processes"])

        #expect(publications == 2)
        #expect(model.projectionStates["agents"] == .loading)
        #expect(model.projectionRefreshStates["agents"]?.isRefreshing == true)
        if case .stale(let count, _)? = model.projectionStates["sessions"] {
            #expect(count == 3)
        } else {
            Issue.record("a refreshing projection with a prior count stays stale with that count")
        }
        #expect(model.projectionRefreshStates["sessions"]?.isStale == true)
    }

    @Test func repeatedSuccessAdvancesFreshnessWithoutPublishing() {
        let model = makeModel()
        let first = Date(timeIntervalSince1970: 10)
        let second = first.addingTimeInterval(5)
        model.recordProjectionSuccess("core", count: 1, now: first)
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }

        model.recordProjectionSuccess("core", count: 1, now: second)

        #expect(model.refreshState(for: "core")?.lastSuccess == second)
        #expect(publications == 0)
        model.recordProjectionUnavailable("core")
        #expect(model.refreshState(for: "core")?.lastSuccess == nil)
    }

    @Test func processCapabilityFollowsTheVerifiedSession() {
        let model = makeModel()
        let clientWide = [HermesCapabilityService.activityCapability(available: false)]
        model.processSessionID = "first"
        model.verifiedProcessSessionID = "first"
        model.installCapabilities(clientWide)
        #expect(model.capabilityAvailable("rpc-activity"))

        model.processSessionID = "second"
        model.installCapabilities(clientWide)
        #expect(!model.capabilityAvailable("rpc-activity"))
    }

    @Test func repeatingAnUnchangedBatchDoesNotPublish() {
        let model = makeModel()
        model.beginProjectionRefreshes(["agents", "projects"])
        model.recordProjectionsUnavailable(["core"])
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }

        model.beginProjectionRefreshes(["agents", "projects"])
        model.recordProjectionsUnavailable(["core"])
        model.beginProjectionRefreshes([])

        #expect(publications == 0)
    }
}
