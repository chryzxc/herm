import Foundation
import Testing

@testable import Herm

@MainActor
struct LocalPreviewDiscoveryModelTests {
    private let server = LocalPreviewServer(pid: 42, port: 3000, processName: "node")

    @Test func inactiveSurfacesDoNotDiscoverAndRootsAreNormalized() async {
        var calls: [[Int32]] = []
        let model = LocalPreviewDiscoveryModel { roots in
            calls.append(roots)
            return []
        }
        model.configure(processIDs: [0, 42, 42, -1], active: false)
        await model.refresh()
        #expect(calls.isEmpty)
        model.configure(processIDs: [0, 42, 42, -1], active: true)
        await model.refresh()
        #expect(calls == [[42]])
        #expect(!model.isRefreshing)
    }

    @Test func simultaneousRefreshesAreCoalesced() async {
        var continuation: CheckedContinuation<[LocalPreviewServer], any Error>?
        var calls = 0
        let model = LocalPreviewDiscoveryModel { _ in
            calls += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        model.configure(processIDs: [42], active: true)
        let pending = Task { await model.refresh() }
        while continuation == nil { await Task.yield() }
        #expect(model.isRefreshing)
        await model.refresh()
        #expect(calls == 1)
        continuation?.resume(returning: [server])
        await pending.value
        #expect(model.servers == [server])
        #expect(!model.isRefreshing)
    }

    @Test func obsoleteResultsCannotCrossTerminalScopes() async {
        var continuation: CheckedContinuation<[LocalPreviewServer], any Error>?
        let current = LocalPreviewServer(pid: 99, port: 8080)
        let model = LocalPreviewDiscoveryModel { roots in
            if roots == [99] { return [current] }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        model.configure(processIDs: [42], active: true)
        let previous = Task { await model.refresh() }
        while continuation == nil { await Task.yield() }
        model.configure(processIDs: [99], active: true)
        await model.refresh()
        continuation?.resume(returning: [server])
        await previous.value
        #expect(model.servers == [current])
        #expect(model.error == nil)
        #expect(!model.isRefreshing)
    }

    @Test func refreshFailureRetainsPreviousResultsAndCanRecover() async {
        var fail = false
        let model = LocalPreviewDiscoveryModel { _ in
            if fail {
                throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Discovery unavailable"])
            }
            return [server]
        }
        model.configure(processIDs: [42], active: true)
        await model.refresh()
        fail = true
        await model.refresh()
        #expect(model.servers == [server])
        #expect(model.error != nil)
        #expect(!model.isRefreshing)
        fail = false
        await model.refresh()
        #expect(model.error == nil)
    }

    @Test func hiddenSurfaceRejectsInFlightResults() async {
        var continuation: CheckedContinuation<[LocalPreviewServer], any Error>?
        let model = LocalPreviewDiscoveryModel { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        model.configure(processIDs: [42], active: true)
        let pending = Task { await model.refresh() }
        while continuation == nil { await Task.yield() }
        model.configure(processIDs: [42], active: false)
        continuation?.resume(returning: [server])
        await pending.value
        #expect(model.servers.isEmpty)
        #expect(!model.isRefreshing)
    }
}
