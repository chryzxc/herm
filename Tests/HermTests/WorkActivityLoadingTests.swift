import Foundation
import Testing

@testable import Herm

@MainActor
struct WorkActivityLoadingTests {
    @Test func interruptedMonthReloadsAndPublishesDelayedUsage() async throws {
        let client = ControlledActivityClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let month = Calendar.current.dateInterval(of: .month, for: Date())!.start
        let previous = Calendar.current.date(byAdding: .month, value: -1, to: month)!
        control.refreshWorkCalendar(month: month, repoPaths: [])
        let first = control.workCalendarTask
        try await waitUntil { control.workCalendar?.month == month && client.pending.count == 1 }
        #expect(control.workCalendarLoadedAt[month] == nil)
        control.refreshWorkCalendar(month: previous, repoPaths: [])
        let second = control.workCalendarTask
        control.refreshWorkCalendar(month: month, repoPaths: [])
        let third = control.workCalendarTask
        try await waitUntil { client.pending.count >= 2 }
        #expect(client.sessionCalls >= 2)
        client.releaseAll()
        await first?.value
        await second?.value
        await third?.value
        #expect(control.workCalendarSources[month]?.usage.first?.inputTokens == 123)
        #expect(control.workCalendarLoadedAt[month] != nil)
    }

    @Test func usageFailureStillCompletesCalendar() async throws {
        let client = ControlledActivityClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let month = Calendar.current.dateInterval(of: .month, for: Date())!.start
        control.refreshWorkCalendar(month: month, repoPaths: [])
        let task = control.workCalendarTask
        try await waitUntil { control.workCalendar?.month == month && !client.pending.isEmpty }
        client.releaseAll(failure: true)
        await task?.value
        #expect(control.workCalendarSources[month]?.usage.isEmpty == true)
        #expect(control.workCalendarLoadedAt[month] != nil)
        #expect(control.workCalendar?.range(from: month, to: .distantFuture).sessions.count == 1)
    }

    @Test func oldUsageCannotPublishAfterRebinding() async throws {
        let client = ControlledActivityClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let month = Calendar.current.dateInterval(of: .month, for: Date())!.start
        control.refreshWorkCalendar(month: month, repoPaths: [])
        let task = control.workCalendarTask
        try await waitUntil { control.workCalendar?.month == month && !client.pending.isEmpty }
        let dock = DockModel(rpcClient: WorkActivityLoadingClient())
        control.bind(to: dock)
        client.releaseAll()
        await task?.value
        #expect(control.workCalendarSources.isEmpty)
        #expect(control.workCalendarLoadedAt.isEmpty)
        #expect(control.workCalendar == nil)
    }

    @Test func monthCacheEvictsLeastRecentlyVisitedSourcesAndMetadata() throws {
        let control = ControlCenterModel()
        let calendar = Calendar.current
        let current = try #require(calendar.dateInterval(of: .month, for: Date())?.start)
        let months = try (0..<4).map { offset in
            try #require(calendar.date(byAdding: .month, value: -offset, to: current))
        }
        for month in months.prefix(3) {
            control.refreshWorkCalendar(month: month, repoPaths: [])
            control.workCalendarSources[month] = (sessions: [], commits: [], pullRequests: [], usage: [])
            control.workCalendarPaths[month] = []
            control.workCalendarLoadedAt[month] = .now
        }
        control.refreshWorkCalendar(month: months[0], repoPaths: [])
        control.refreshWorkCalendar(month: months[3], repoPaths: [])

        #expect(control.workCalendarRecentMonths == [months[2], months[0], months[3]])
        #expect(control.workCalendarSources[months[0]] != nil)
        #expect(control.workCalendarSources[months[1]] == nil)
        #expect(control.workCalendarPaths[months[1]] == nil)
        #expect(control.workCalendarLoadedAt[months[1]] == nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for activity state")
    }

    @Test func sessionsBecomeVisibleBeforeSlowUsageFinishes() async throws {
        let client = WorkActivityLoadingClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let month = Calendar.current.dateInterval(of: .month, for: Date())!.start
        let clock = ContinuousClock()
        let start = clock.now
        control.refreshWorkCalendar(month: month, repoPaths: [])
        let pending = control.workCalendarTask
        defer { pending?.cancel() }
        for _ in 0..<100 where !client.sessionsReturned || !client.usageStarted {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(client.sessionsReturned)
        #expect(client.usageStarted)
        for _ in 0..<100 where control.workCalendar == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        print(
            "Activity reproduction: elapsed=\(start.duration(to: clock.now)), "
                + "sessionsReturned=\(client.sessionsReturned), usageFinished=\(client.usageFinished), "
                + "calendarVisible=\(control.workCalendar != nil)"
        )
        #expect(!client.usageFinished)
        #expect(control.workCalendar?.month == month)
        #expect(control.workCalendar?.range(from: month, to: .distantFuture).sessions.count == 1)
        pending?.cancel()
        await pending?.value
    }
}

@MainActor
private final class ControlledActivityClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var sessionCalls = 0
    var pending: [CheckedContinuation<Bool, Never>] = []

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if path.hasPrefix("/api/sessions?") {
            sessionCalls += 1
            return ["data": [["id": "fixture", "updated_at": Date().timeIntervalSince1970]], "has_more": false]
        }
        if path.hasPrefix("/api/analytics/usage?") {
            let failure = await withCheckedContinuation { pending.append($0) }
            if failure { throw URLError(.timedOut) }
            return ["daily": [["day": "2026-10-20", "input_tokens": 123]]]
        }
        return [:]
    }

    func releaseAll(failure: Bool = false) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting { continuation.resume(returning: failure) }
    }
}

@MainActor
private final class WorkActivityLoadingClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var sessionsReturned = false
    var usageStarted = false
    var usageFinished = false

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if path.hasPrefix("/api/sessions?") {
            sessionsReturned = true
            return [
                "data": [["id": "activity-fixture", "title": "Fixture", "updated_at": Date().timeIntervalSince1970]],
                "has_more": false,
            ]
        }
        if path.hasPrefix("/api/analytics/usage?") {
            usageStarted = true
            try await Task.sleep(for: .seconds(3))
            usageFinished = true
            return ["daily": [[String: Any]]()]
        }
        return [:]
    }
}
