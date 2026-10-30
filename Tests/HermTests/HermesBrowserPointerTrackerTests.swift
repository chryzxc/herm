import CoreGraphics
import Foundation
import Testing

@testable import Herm

@MainActor
struct HermesBrowserPointerTrackerTests {
    @Test func routesContextsBySessionAndMapsNestedFrames() async throws {
        var delivered: [AgentPointer] = []
        var invalidations = 0
        let tracker = HermesBrowserPointerTracker(
            rootSession: "root",
            send: { method, params, _ in
                switch method {
                case "DOM.getFrameOwner": return ["backendNodeId": params["frameId"] as? String == "child" ? 1 : 2]
                case "DOM.resolveNode": return ["object": ["objectId": "\(params["backendNodeId"]!)"]]
                case "Runtime.callFunctionOn":
                    let child = params["objectId"] as? String == "1"
                    return [
                        "result": [
                            "value": child
                                ? ["x": 100.0, "y": 50.0, "sx": 2.0, "sy": 2.0]
                                : ["x": 10.0, "y": 20.0, "sx": 0.5, "sy": 0.5]
                        ]
                    ]
                default: return [:]
                }
            }, active: { true }, deliver: { delivered.append($0) }, invalidatePointer: { invalidations += 1 })
        defer { tracker.stop() }
        tracker.receive("Page.frameNavigated", params: ["frame": ["id": "main"]], session: "root")
        tracker.receive("Page.frameAttached", params: ["frameId": "child", "parentFrameId": "main"], session: "root")
        tracker.receive(
            "Target.attachedToTarget",
            params: [
                "sessionId": "child-session", "targetInfo": ["type": "iframe", "targetId": "child"],
            ], session: "root")
        tracker.receive(
            "Page.frameAttached", params: ["frameId": "nested", "parentFrameId": "child"], session: "child-session")
        tracker.receive(
            "Runtime.executionContextCreated",
            params: [
                "context": ["id": 1, "name": "herm", "auxData": ["frameId": "main"]]
            ], session: "root")
        tracker.receive(
            "Runtime.executionContextCreated",
            params: [
                "context": ["id": 1, "name": "herm", "auxData": ["frameId": "nested"]]
            ], session: "child-session")
        tracker.receive(
            "Runtime.executionContextCreated",
            params: [
                "context": ["id": 2, "name": "herm", "auxData": ["frameId": "child"]]
            ], session: "child-session")
        tracker.receive(
            "Runtime.bindingCalled",
            params: [
                "name": "hermPointer", "executionContextId": 1, "payload": #"{"type":"down","x":8,"y":12}"#,
            ], session: "child-session")
        for _ in 0..<100 where delivered.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(delivered == [AgentPointer(kind: .down, point: CGPoint(x: 128, y: 102))])
        tracker.receive("Page.frameAttached", params: ["frameId": "other", "parentFrameId": "main"], session: "root")
        tracker.receive("Page.frameNavigated", params: ["frame": ["id": "other", "parentId": "main"]], session: "root")
        #expect(invalidations == 0)
        tracker.receive("Page.frameDetached", params: ["frameId": "child", "reason": "remove"], session: "root")
        #expect(invalidations == 1)
        #expect(tracker.contexts[.init(session: "root", id: 1)] == "main")
        #expect(tracker.contexts[.init(session: "child-session", id: 1)] == nil)
    }

    @Test func rejectsStaleAndUntrustedContexts() async throws {
        var delivered: [AgentPointer] = []
        let tracker = HermesBrowserPointerTracker(
            rootSession: "root", send: { _, _, _ in [:] }, active: { true },
            deliver: { delivered.append($0) }, invalidatePointer: {})
        defer { tracker.stop() }
        tracker.receive("Page.frameNavigated", params: ["frame": ["id": "main"]], session: "root")
        tracker.receive(
            "Runtime.executionContextCreated",
            params: [
                "context": ["id": 2, "name": "page", "auxData": ["frameId": "main"]]
            ], session: "root")
        tracker.receive(
            "Runtime.bindingCalled",
            params: [
                "name": "hermPointer", "executionContextId": 2, "payload": #"{"type":"down","x":1,"y":2}"#,
            ], session: "root")
        tracker.receive(
            "Runtime.executionContextCreated",
            params: [
                "context": ["id": 3, "name": "herm", "auxData": ["frameId": "main"]]
            ], session: "root")
        tracker.receive(
            "Runtime.bindingCalled",
            params: [
                "name": "hermPointer", "executionContextId": 3, "payload": #"{"type":"move","x":1,"y":2}"#,
            ], session: "root")
        tracker.receive("Page.frameNavigated", params: ["frame": ["id": "main"]], session: "root")
        try await Task.sleep(for: .milliseconds(30))
        #expect(delivered.isEmpty)
    }

    @Test func geometryRejectsInvalidScales() {
        #expect(HermesBrowserPointerTracker.Geometry(value: ["x": 10.0, "y": 20.0, "sx": 2.0, "sy": 0.5]) != nil)
        #expect(HermesBrowserPointerTracker.Geometry(value: ["x": 10.0, "y": 20.0, "sx": 0.0, "sy": 1.0]) == nil)
        #expect(
            HermesBrowserPointerTracker.Geometry(value: ["x": Double.infinity, "y": 0.0, "sx": 1.0, "sy": 1.0]) == nil)
    }

    @Test func frameProcessSwapKeepsItsParentAndDropsOldContexts() {
        let tracker = HermesBrowserPointerTracker(
            rootSession: "root", send: { _, _, _ in [:] }, active: { true }, deliver: { _ in }, invalidatePointer: {})
        defer { tracker.stop() }
        tracker.receive("Page.frameNavigated", params: ["frame": ["id": "main"]], session: "root")
        tracker.receive("Page.frameAttached", params: ["frameId": "child", "parentFrameId": "main"], session: "root")
        tracker.receive(
            "Target.attachedToTarget",
            params: [
                "sessionId": "remote", "targetInfo": ["type": "iframe", "targetId": "child"],
            ], session: "root")
        tracker.receive(
            "Runtime.executionContextCreated",
            params: [
                "context": ["id": 4, "name": "herm", "auxData": ["frameId": "child"]]
            ], session: "remote")
        tracker.receive("Page.frameDetached", params: ["frameId": "child", "reason": "swap"], session: "root")
        tracker.receive("Target.detachedFromTarget", params: ["sessionId": "remote"], session: "root")
        #expect(tracker.frames["child"]?.parent == "main")
        #expect(tracker.frames["child"]?.session == "root")
        #expect(tracker.contexts[.init(session: "remote", id: 4)] == nil)
        tracker.receive("Page.frameNavigated", params: ["frame": ["id": "child", "parentId": "main"]], session: "root")
        tracker.receive(
            "Runtime.executionContextCreated",
            params: [
                "context": ["id": 5, "name": "herm", "auxData": ["frameId": "child"]]
            ], session: "root")
        #expect(tracker.contexts[.init(session: "root", id: 5)] == "child")
    }

    @Test func associatesEventsThatArriveBeforeTheirFrame() {
        let tracker = HermesBrowserPointerTracker(
            rootSession: "root", send: { _, _, _ in [:] }, active: { true }, deliver: { _ in }, invalidatePointer: {})
        defer { tracker.stop() }
        tracker.receive("Page.frameNavigated", params: ["frame": ["id": "main"]], session: "root")
        tracker.receive(
            "Runtime.executionContextCreated",
            params: [
                "context": ["id": 3, "name": "herm", "auxData": ["frameId": "same"]]
            ], session: "root")
        tracker.receive("Page.frameAttached", params: ["frameId": "same", "parentFrameId": "main"], session: "root")
        #expect(tracker.contexts[.init(session: "root", id: 3)] == "same")
        tracker.receive(
            "Target.attachedToTarget",
            params: [
                "sessionId": "remote", "targetInfo": ["type": "iframe", "targetId": "cross"],
            ], session: "root")
        tracker.receive("Page.frameAttached", params: ["frameId": "cross", "parentFrameId": "main"], session: "root")
        tracker.receive(
            "Runtime.executionContextCreated",
            params: [
                "context": ["id": 4, "name": "herm", "auxData": ["frameId": "cross"]]
            ], session: "remote")
        #expect(tracker.contexts[.init(session: "remote", id: 4)] == "cross")
    }

    @Test func discardsGeometryReplyAfterFrameDetaches() async throws {
        var delivered: [AgentPointer] = []
        var waiting: CheckedContinuation<[String: Any], Error>?
        let tracker = HermesBrowserPointerTracker(
            rootSession: "root",
            send: { method, _, _ in
                if method == "DOM.getFrameOwner" {
                    return try await withCheckedThrowingContinuation { waiting = $0 }
                }
                if method == "DOM.resolveNode" { return ["object": ["objectId": "owner"]] }
                if method == "Runtime.callFunctionOn" {
                    return ["result": ["value": ["x": 10.0, "y": 20.0, "sx": 1.0, "sy": 1.0]]]
                }
                return [:]
            }, active: { true }, deliver: { delivered.append($0) }, invalidatePointer: {})
        defer { tracker.stop() }
        tracker.receive("Page.frameNavigated", params: ["frame": ["id": "main"]], session: "root")
        tracker.receive("Page.frameAttached", params: ["frameId": "child", "parentFrameId": "main"], session: "root")
        tracker.receive(
            "Runtime.executionContextCreated",
            params: [
                "context": ["id": 1, "name": "herm", "auxData": ["frameId": "main"]]
            ], session: "root")
        tracker.receive(
            "Runtime.executionContextCreated",
            params: [
                "context": ["id": 7, "name": "herm", "auxData": ["frameId": "child"]]
            ], session: "root")
        tracker.receive(
            "Runtime.bindingCalled",
            params: [
                "name": "hermPointer", "executionContextId": 7, "payload": #"{"type":"down","x":1,"y":2}"#,
            ], session: "root")
        for _ in 0..<100 where waiting == nil { try await Task.sleep(for: .milliseconds(5)) }
        let continuation = try #require(waiting)
        tracker.receive("Page.frameDetached", params: ["frameId": "child", "reason": "remove"], session: "root")
        continuation.resume(returning: ["backendNodeId": 1])
        try await Task.sleep(for: .milliseconds(30))
        #expect(delivered.isEmpty)
    }

    @Test func browserActivityRemainsOwnedWithoutAPane() {
        let model = DockModel(initialSessionID: "browser-activity", rpcClient: PointerTestRPC())
        let browser = AgentBrowser(profileID: nil)
        browser.model = model
        func call(_ id: String) -> ActiveToolCall {
            ActiveToolCall(
                id: id, name: "browser_exec", input: "secret", context: "", startedAt: Date(), isComplete: false)
        }
        model.activeToolCalls = [call("one")]
        #expect(browser.inputLocked)
        browser.takeOver()
        #expect(!browser.inputLocked)
        #expect(browser.userHasControl)
        model.activeToolCalls = [call("one"), call("two")]
        #expect(browser.userHasControl == (model.interruptState == .requesting))
        model.interruptState = .idle
        #expect(!browser.userHasControl)
        #expect(browser.inputLocked)
        model.activeToolCalls = []
        #expect(!browser.inputLocked)
    }
}

@MainActor
private final class PointerTestRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
}
