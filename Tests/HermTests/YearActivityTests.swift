import Foundation
import Testing
@testable import Herm

@MainActor
struct YearActivityTests {
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
}

@MainActor
private final class YearActivityClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var paths: [String] = []
    var onFetch: (() -> Void)?
    var response: [String: Any] = ["daily": [["day": "2026-10-20", "input_tokens": 100]]]
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        paths.append(path)
        onFetch?()
        return response
    }
}
