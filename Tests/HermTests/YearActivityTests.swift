import Foundation
import Testing

@testable import Herm

@MainActor
struct YearActivityTests {
    @Test func spendLoadsRecentReportFirstAndSharesRequestsAcrossTabChanges() async {
        let client = YearActivityClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        client.onFetch = {
            if client.paths.last == "/api/analytics/usage?days=365" {
                #expect(control.tokenUsage != nil)
                #expect(control.refreshState(for: "token.usage")?.isRefreshing == false)
            }
        }
        let parent = Task { @MainActor in
            let load = control.refreshSpend()
            withUnsafeCurrentTask { $0?.cancel() }
            return load
        }
        let first = await parent.value
        let second = control.refreshSpend(force: true)
        await first.value
        await second.value
        #expect(
            client.paths.filter { $0.contains("/usage?") } == [
                "/api/analytics/usage?days=30", "/api/analytics/usage?days=365",
            ])
        #expect(client.timeouts == [60, 60])
        #expect(control.tokenUsage != nil)
        #expect(control.yearActivity != nil)
        #expect(control.spendRefreshTask == nil)

        let paths = client.paths
        await control.refreshSpend().value
        #expect(client.paths == paths)
        await control.refreshSpend(force: true).value
        #expect(client.paths.filter { $0.contains("/usage?") }.count == 4)
    }

    @Test func spendWaitsForSlowProviderAccountingWithoutBlockingYear() async {
        let client = YearActivityClient()
        client.modelDelay = .milliseconds(150)
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        client.onFetch = {
            if client.paths.last == "/api/analytics/usage?days=365" {
                #expect(control.refreshState(for: "usage.providers")?.isRefreshing == true)
            }
        }
        await control.refreshSpend().value
        #expect(control.refreshState(for: "usage.providers")?.isRefreshing == false)
        #expect(control.providerUsageTask == nil)
        #expect(control.spendRefreshTask == nil)
    }

    @Test func switchingRuntimeClearsWorkCalendarCaches() {
        let control = ControlCenterModel()
        let month = Calendar.current.dateInterval(of: .month, for: Date())!.start
        control.workCalendar = WorkCalendarIndex.build(
            month: month, sessions: [], tasks: [], commits: [], runs: [], usage: [])
        control.workCalendarMonth = month
        control.workCalendarSources[month] = (sessions: [], commits: [], pullRequests: [], usage: [])
        control.workCalendarPaths[month] = ["/fixture"]
        control.workCalendarLoadedAt[month] = Date()
        control.bind(to: DockModel(rpcClient: YearActivityClient()))
        #expect(control.workCalendar == nil)
        #expect(control.workCalendarMonth == nil)
        #expect(control.workCalendarSources.isEmpty)
        #expect(control.workCalendarPaths.isEmpty)
        #expect(control.workCalendarLoadedAt.isEmpty)
    }

    @Test func sameMonthReadIsSharedAndExpiredCacheRetries() {
        let control = ControlCenterModel()
        let month = Calendar.current.dateInterval(of: .month, for: Date())!.start
        control.workCalendarMonth = month
        control.workCalendarPaths[month] = []
        let pending = Task { @MainActor in }
        control.workCalendarTask = pending
        let generation = control.workCalendarGeneration
        control.refreshWorkCalendar(month: month, repoPaths: [], force: true)
        #expect(control.workCalendarGeneration == generation)
        #expect(!pending.isCancelled)
        control.workCalendarTask = nil
        control.workCalendarSources[month] = (sessions: [], commits: [], pullRequests: [], usage: [])
        control.workCalendarLoadedAt[month] = Date().addingTimeInterval(-120)
        control.refreshWorkCalendar(month: month, repoPaths: [])
        // No RPC is bound: an expired cache must expose unavailable, never certify stale data.
        #expect(control.refreshState(for: "work.calendar")?.lastSuccess == nil)
        #expect(control.workCalendar == nil)
    }

    @Test func cachedMonthCancelsPreviousMonthAndSettlesRefresh() {
        let control = ControlCenterModel()
        let month = Calendar.current.dateInterval(of: .month, for: Date())!.start
        let previous = Calendar.current.date(byAdding: .month, value: -1, to: month)!
        control.workCalendarMonth = previous
        control.workCalendarSources[month] = (sessions: [], commits: [], pullRequests: [], usage: [])
        control.workCalendarLoadedAt[month] = Date()
        let oldGeneration = control.workCalendarGeneration
        control.beginProjectionRefresh("work.calendar")
        control.refreshWorkCalendar(month: month, repoPaths: [])
        #expect(control.workCalendar?.month == month)
        #expect(control.workCalendarGeneration != oldGeneration)
        #expect(control.refreshState(for: "work.calendar")?.isRefreshing == false)
    }

    @Test func tokenUsageSharesInflightReadsAndKeepsGoodDataOnTimeout() async {
        let client = YearActivityClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let first = control.refreshTokenUsage(days: 30)
        let second = control.refreshTokenUsage(days: 30)
        await first?.value
        await second?.value
        #expect(client.paths.filter { $0.contains("/usage?") }.count == 1)
        let previous = control.tokenUsage
        client.failure = URLError(.timedOut)
        await control.refreshTokenUsage(days: 30)?.value
        #expect(control.tokenUsage == previous)
        #expect(control.refreshState(for: "token.usage")?.isRefreshing == false)
        #expect(control.refreshState(for: "token.usage")?.isStale == true)
    }

    @Test func loadsYearIndependentlyAndRetainsItOnFailure() async {
        let client = YearActivityClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        await control.refreshYearActivity()
        #expect(client.paths == ["/api/analytics/usage?days=365"])
        #expect(control.yearActivity?.first?.inputTokens == 100)
        #expect(control.tokenUsage == nil)
        #expect(control.refreshState(for: "usage.year")?.isStale == false)

        client.response = [:]
        await control.refreshYearActivity()
        #expect(control.yearActivity?.first?.inputTokens == 100)
        #expect(control.refreshState(for: "usage.year")?.isStale == true)
        #expect(control.refreshState(for: "usage.year")?.error != nil)
    }

    @Test func emptySuccessDiffersFromUnavailable() async {
        let unavailable = ControlCenterModel()
        await unavailable.refreshYearActivity()
        #expect(unavailable.yearActivity == nil)
        #expect(unavailable.projectionState(for: "usage.year") != nil)

        let client = YearActivityClient()
        client.response = ["daily": [[String: Any]]()]
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        await control.refreshYearActivity()
        #expect(control.yearActivity?.isEmpty == true)
        #expect(control.refreshState(for: "usage.year")?.lastSuccess != nil)
    }

    @Test func discardsResponseFromPreviousBinding() async {
        let client = YearActivityClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        client.onFetch = { control.clientBindingGeneration &+= 1 }
        await control.refreshYearActivity()
        #expect(control.yearActivity == nil)
    }

    @Test func providerAccountingLoadsSeparatelyAndCannotReuseOldCostsAfterFailure() async {
        let client = YearActivityClient()
        client.modelResponse = [
            "period_days": 30,
            "models": [
                [
                    "model": "example", "provider": "direct", "input_tokens": 100,
                    "output_tokens": 20, "estimated_cost": 2,
                ]
            ],
        ]
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        await control.refreshTokenUsage(days: 30)?.value
        for _ in 0..<100 {
            if control.refreshState(for: "usage.providers")?.isRefreshing == false { break }
            try? await Task.sleep(for: .milliseconds(3))
        }
        #expect(control.tokenUsage?.costRankedProviders?.first?.estimatedCost == 2)
        #expect(control.refreshState(for: "usage.providers")?.error == nil)

        client.modelFailure = URLError(.timedOut)
        await control.refreshTokenUsage(days: 30)?.value
        for _ in 0..<100 {
            if control.refreshState(for: "usage.providers")?.isRefreshing == false { break }
            try? await Task.sleep(for: .milliseconds(3))
        }
        #expect(control.tokenUsage != nil)
        #expect(control.tokenUsage?.costRankedProviders == nil)
        #expect(control.refreshState(for: "usage.providers")?.isRefreshing == false)
        #expect(control.refreshState(for: "usage.providers")?.error != nil)
    }
}

@MainActor
private final class YearActivityClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var paths: [String] = []
    var timeouts: [TimeInterval] = []
    var failure: Error?
    var onFetch: (() -> Void)?
    var response: [String: Any] = ["period_days": 30, "daily": [["day": "2026-10-20", "input_tokens": 100]]]
    var modelResponse: [String: Any] = ["period_days": 30, "models": [[String: Any]]()]
    var modelFailure: Error?
    var modelDelay: Duration = .zero
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        paths.append(path)
        onFetch?()
        try await Task.sleep(for: path.contains("/models?") ? modelDelay : .milliseconds(10))
        if let failure { throw failure }
        if path.contains("/models?"), let modelFailure { throw modelFailure }
        return path.contains("/models?") ? modelResponse : response
    }
    func fetchHTTP(_ path: String, timeout: TimeInterval) async throws -> [String: Any] {
        timeouts.append(timeout)
        return try await fetchHTTP(path)
    }
}
