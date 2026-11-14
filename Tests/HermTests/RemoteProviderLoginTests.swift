import Foundation
import Testing

@testable import Herm

@MainActor
struct RemoteProviderLoginTests {
    @Test func dismissalClosesAfterConfirmedCancellation() async {
        let client = SuspendedLoginClient()
        client.refuseDelete = false
        let login = HermesRemoteProviderLoginService()
        var dismissed = false
        login.begin(client: client, profile: "work", provider: "codex", current: { true }, onApproved: {})
        await client.waitForStart()
        let close = Task { await RemoteProviderLoginSheet.cancelAndDismiss(login: login) { dismissed = true } }
        await client.waitForCancellation()
        #expect(!dismissed)
        client.releaseStart()
        await close.value
        #expect(dismissed)
        #expect(!login.cancellationInDoubt)
    }

    @Test func dismissalWaitsForCancellationAndShowsRefusal() async {
        let client = SuspendedLoginClient()
        let login = HermesRemoteProviderLoginService()
        var dismissed = false
        login.begin(client: client, profile: "work", provider: "codex", current: { true }, onApproved: {})
        await client.waitForStart()
        let close = Task { await RemoteProviderLoginSheet.cancelAndDismiss(login: login) { dismissed = true } }
        await client.waitForCancellation()
        #expect(!dismissed)
        client.releaseStart()
        await close.value
        #expect(!dismissed)
        #expect(login.cancellationInDoubt)
        #expect(login.message.contains("may still complete"))
        await RemoteProviderLoginSheet.cancelAndDismiss(login: login) { dismissed = true }
        #expect(dismissed)
    }

    @Test func approvalCallsBackOnce() async {
        let client = ExpiringLoginClient()
        client.onPoll = {}
        let login = HermesRemoteProviderLoginService(sleep: { _ in })
        var approvals = 0
        await withCheckedContinuation { continuation in
            login.begin(client: client, profile: "work", provider: "codex", current: { true }) {
                approvals += 1
                continuation.resume()
            }
        }
        #expect(login.approved)
        #expect(approvals == 1)
        #expect(client.pollCount == 1)
    }

    @Test func approvalFromOldContextIsRejected() async {
        let client = ExpiringLoginClient()
        var current = true
        var approvals = 0
        client.onPoll = { current = false }
        let login = HermesRemoteProviderLoginService(sleep: { _ in })
        login.begin(
            client: client, profile: "work", provider: "codex", current: { current },
            onApproved: { approvals += 1 })
        await client.waitForDelete()
        _ = await login.cancel()
        #expect(!login.approved)
        #expect(approvals == 0)
        #expect(client.pollCount == 1)
    }

    @Test func latePollApprovalIsRejectedAndCleanedUp() async {
        let clock = LoginTestClock()
        let client = ExpiringLoginClient()
        client.onPoll = { clock.date.addTimeInterval(10) }
        let login = HermesRemoteProviderLoginService(
            now: { clock.date },
            sleep: { seconds in
                clock.date.addTimeInterval(seconds)
            })
        login.begin(client: client, profile: nil, provider: "codex", current: { true }, onApproved: {})
        await client.waitForDelete()
        _ = await login.cancel()
        #expect(client.pollCount == 1)
        #expect(!login.approved)
        #expect(!login.cancellationInDoubt)
    }

    @Test func deadlineBoundsSleepAndCleansUpWithoutPolling() async {
        let clock = LoginTestClock()
        let client = ExpiringLoginClient()
        let login = HermesRemoteProviderLoginService(
            now: { clock.date },
            sleep: { seconds in
                clock.slept = seconds
                clock.date.addTimeInterval(seconds)
            })
        login.begin(client: client, profile: nil, provider: "codex", current: { true }, onApproved: {})
        await client.waitForDelete()
        _ = await login.cancel()
        #expect(clock.slept == 5)
        #expect(client.pollCount == 0)
        #expect(!login.cancellationInDoubt)
    }

    @Test func lateStartDeletionFailureBlocksRetryAndWarns() async {
        let client = SuspendedLoginClient()
        let login = HermesRemoteProviderLoginService()
        login.begin(client: client, profile: "work", provider: "codex", current: { true }, onApproved: {})
        await client.waitForStart()
        let cancellation = Task { await login.cancel() }
        await client.waitForCancellation()
        client.releaseStart()
        let confirmed = await cancellation.value
        #expect(!confirmed)
        #expect(login.cancellationInDoubt)
        #expect(login.message.contains("may still complete"))
        #expect(client.deletePath?.contains("profile=work") == true)
        login.begin(client: client, profile: "other", provider: "codex", current: { true }, onApproved: {})
        #expect(client.startCount == 1)
    }

    @Test func validatesDeviceResponse() throws {
        let response: [String: Any] = [
            "session_id": "session-1", "flow": "device_code", "user_code": "ABCD-1234",
            "verification_url": "https://example.com/device", "expires_in": 300, "poll_interval": 2,
        ]
        let start = try HermesRemoteProviderLoginService.decodeStart(response)
        #expect(start.code == "ABCD-1234")
        #expect(start.interval == 2)
        var unsafe = response
        unsafe["verification_url"] = "https://user@example.com/device"
        #expect(throws: (any Error).self) { try HermesRemoteProviderLoginService.decodeStart(unsafe) }
        unsafe["session_id"] = "../other"
        #expect(throws: (any Error).self) { try HermesRemoteProviderLoginService.decodeStart(unsafe) }
    }

    @Test func encodesProfileAndPath() {
        let path = HermesRemoteProviderLoginService.path(["api", "providers", "oauth", "a/b"], profile: "work & home")
        #expect(path.contains("a%2Fb"))
        #expect(path.contains("work%20%26%20home"))
        #expect(HermesRemoteProviderLoginService.path(["api"], profile: nil).contains("profile=default"))
    }
}

@MainActor
private final class SuspendedLoginClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var refuseDelete = true
    var startCount = 0
    var deletePath: String?
    private var startContinuation: CheckedContinuation<[String: Any], any Error>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancelWaiter: CheckedContinuation<Void, Never>?
    private var cancelled = false

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        ["providers": [["id": "codex", "flow": "device_code"]]]
    }

    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        if method == "DELETE" {
            deletePath = path
            if refuseDelete { throw URLError(.cannotConnectToHost) }
            return [:]
        }
        startCount += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                startWaiter?.resume()
                startWaiter = nil
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelled = true
                self.cancelWaiter?.resume()
                self.cancelWaiter = nil
            }
        }
    }

    func waitForStart() async {
        if startContinuation != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func waitForCancellation() async {
        if cancelled { return }
        await withCheckedContinuation { cancelWaiter = $0 }
    }

    func releaseStart() {
        startContinuation?.resume(returning: [
            "session_id": "session-1", "flow": "device_code", "user_code": "ABCD-1234",
            "verification_url": "https://example.com/device", "expires_in": 300, "poll_interval": 2,
        ])
        startContinuation = nil
    }
}

@MainActor
private final class LoginTestClock {
    var date = Date(timeIntervalSince1970: 1_000)
    var slept: TimeInterval?
}

@MainActor
private final class ExpiringLoginClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var pollCount = 0
    var onPoll: (() -> Void)?
    private var deleted = false
    private var deleteWaiter: CheckedContinuation<Void, Never>?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if path.contains("/poll/") {
            pollCount += 1
            onPoll?()
            return ["status": "approved"]
        }
        return ["providers": [["id": "codex", "flow": "device_code"]]]
    }
    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        if method == "DELETE" {
            deleted = true
            deleteWaiter?.resume()
            deleteWaiter = nil
            return [:]
        }
        return [
            "session_id": "session-1", "flow": "device_code", "user_code": "ABCD-1234",
            "verification_url": "https://example.com/device", "expires_in": 5, "poll_interval": onPoll == nil ? 10 : 1,
        ]
    }
    func waitForDelete() async {
        if deleted { return }
        await withCheckedContinuation { deleteWaiter = $0 }
    }
}
