import CoreGraphics
import Darwin
import Foundation
import Testing

@testable import Herm

struct SessionSimulatorTests {
    @Test func letterboxingAndDragCoordinatesStayInsideDevice() throws {
        let rect = SessionSimulatorGeometry.fittedRect(
            source: CGSize(width: 400, height: 800), bounds: CGRect(x: 0, y: 0, width: 600, height: 600))
        #expect(rect == CGRect(x: 150, y: 0, width: 300, height: 600))
        #expect(SessionSimulatorGeometry.normalizedPoint(CGPoint(x: 20, y: 300), imageRect: rect) == nil)
        #expect(
            SessionSimulatorGeometry.normalizedPoint(CGPoint(x: 300, y: 300), imageRect: rect)
                == CGPoint(x: 0.5, y: 0.5))
        #expect(SessionSimulatorGeometry.normalizedPoint(CGPoint(x: 150, y: 0), imageRect: rect) == .zero)
        #expect(
            SessionSimulatorGeometry.normalizedPoint(CGPoint(x: 900, y: -20), imageRect: rect, clamp: true)
                == CGPoint(x: 1, y: 0))
        #expect(SessionSimulatorGeometry.normalizedPoint(.zero, imageRect: .zero) == nil)
        #expect(SessionSimulatorGeometry.fittedRect(source: .zero, bounds: rect) == .zero)
    }

    @Test @MainActor func simulatorTabsRestoreOnlyInTheirSessionAndLegacyLayoutsDecode() throws {
        let legacy = Data(#"{"selected":"Timeline","closed":"Browser","recentClosed":[]}"#.utf8)
        #expect(try JSONDecoder().decode(InspectorPresentation.self, from: legacy).simulatorSections == nil)
        let suite = "HermSimulatorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspacePresentationStore(defaults: defaults)
        store.save(
            InspectorPresentation(selected: "iOS Simulator", simulatorSections: ["iOS Simulator"]),
            identity: "session-a")
        #expect(store.load("session-a")?.simulatorSections == ["iOS Simulator"])
        #expect(store.load("session-b") == nil)
        #expect(SessionInspector.Section.iosSimulator.navigationTitle == "iOS Simulator")
        #expect(SessionInspector.Section.androidEmulator.navigationTitle == "Android Emulator")
    }

    @Test @MainActor func stoppingAnUnusedCaptureIsIdempotent() {
        let capture = SessionSimulatorCapture()
        capture.stop()
        capture.stop()
        #expect(capture.image == nil)
        #expect(!capture.isLoading)
        #expect(capture.devices.isEmpty)
    }
    @Test func launchReceiptsRejectErrorsForeignHostsAndUnrelatedTools() throws {
        let json =
            #"{"schema":"herm.simulator.v1","status":"ready","platform":"ios","device_id":"uuid","device_name":"Phone","host":"local"}"#
        let receipt = try #require(
            SessionSimulatorLaunch.receipt(tool: "herm_simulator", result: json, isError: false, localHost: "local"))
        #expect(receipt.target == .ios)
        #expect(
            SessionSimulatorLaunch.receipt(tool: "terminal", result: json, isError: false, localHost: "local") == nil)
        #expect(
            SessionSimulatorLaunch.receipt(tool: "herm_simulator", result: json, isError: true, localHost: "local")
                == nil)
        #expect(
            SessionSimulatorLaunch.receipt(tool: "herm_simulator", result: json, isError: false, localHost: "remote")
                == nil)
        #expect(
            SessionSimulatorLaunch.receipt(
                tool: "herm_simulator", result: "not JSON", isError: false, localHost: "local") == nil)
        #expect(
            SessionSimulatorLaunch.receipt(
                tool: "herm_simulator", result: json.replacingOccurrences(of: "ready", with: "selection_required"),
                isError: false, localHost: "local") == nil)
    }

    @Test @MainActor func launchRequestsAreSessionScopedAndDeduplicated() throws {
        let json =
            #"{"schema":"herm.simulator.v1","status":"ready","platform":"android","device_id":"emulator-5554","device_name":"Pixel_9","host":"local"}"#
        let receipt = try #require(
            SessionSimulatorLaunch.receipt(tool: "herm_simulator", result: json, isError: false, localHost: "local"))
        let store = SessionSimulatorLaunchStore()
        store.present(receipt, session: "a", callID: "call")
        #expect(store.request(for: "a", platform: .android)?.callID == "call")
        #expect(store.request(for: "b", platform: .android) == nil)
        #expect(store.request(for: "a", platform: .ios) == nil)
        store.present(receipt, session: "a", callID: "call")
        #expect(store.latest?.callID == "call")
    }

    @Test @MainActor func exitedBridgeTurnsBrokenPipeIntoAnErrorInsteadOfTerminatingHerm() throws {
        let pipe = try HermesSimulatorBridge.protectedInputPipe()
        defer { try? pipe.fileHandleForWriting.close() }
        #expect(fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE) == 1)
        try pipe.fileHandleForReading.close()
        #expect(throws: (any Error).self) {
            try pipe.fileHandleForWriting.write(contentsOf: Data("release\n".utf8))
        }
    }

    @Test func directBridgeRejectsOversizedAndUnknownPackets() throws {
        var decoder = HermesSimulatorPacketDecoder()
        #expect(throws: (any Error).self) { try decoder.append(Data([73, 127, 255, 255, 255])) }
        var unknown = HermesSimulatorPacketDecoder()
        #expect(throws: (any Error).self) { try unknown.append(Data([0, 0, 0, 0, 0])) }
        var partial = HermesSimulatorPacketDecoder()
        #expect(try partial.append(Data([74, 0, 0])).isEmpty)
        let packets = try partial.append(Data([0, 2, 123, 125, 73, 0, 0, 0, 1, 42]))
        #expect(packets.count == 2)
        #expect(packets[0].1 == Data("{}".utf8))
        #expect(packets[1].1 == Data([42]))
    }

    @Test @MainActor func directInventoryNeverGuessesBetweenDevicesAndReportsDisconnect() {
        let capture = SessionSimulatorCapture()
        capture.receive(
            kind: 74, data: Data(#"{"devices":[{"id":"a","name":"Phone"},{"id":"b","name":"Tablet"}]}"#.utf8))
        #expect(capture.selectedID.isEmpty)
        capture.receive(kind: 74, data: Data(#"{"devices":[{"id":"a","name":"Phone"}]}"#.utf8))
        #expect(capture.selectedID == "a")
        capture.receive(kind: 74, data: Data(#"{"devices":[]}"#.utf8))
        #expect(capture.message.contains("no longer running"))
        #expect(!capture.inputAllowed)
        #expect(capture.image == nil)
        capture.receive(kind: 74, data: Data(#"{"error":"Bridge unavailable"}"#.utf8))
        #expect(capture.message == "Bridge unavailable")
    }

    @Test @MainActor func liveDirectBridgeWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let device = environment["HERM_SIMULATOR_TEST_DEVICE"],
            let platform = SessionSimulatorPlatform(rawValue: environment["HERM_SIMULATOR_TEST_PLATFORM"] ?? "")
        else { return }
        let capture = SessionSimulatorCapture()
        defer { capture.stop() }
        capture.refresh(platform, preferredID: device)
        for _ in 0..<300 {
            if capture.image != nil || !capture.isLoading { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(capture.image != nil, "\(capture.message)")
        #expect(capture.inputAllowed)
        capture.stop()
        #expect(capture.image == nil)
        #expect(!capture.inputAllowed)
    }

    @Test @MainActor func onlyLiveOwnedToolCompletionOpensSimulator() throws {
        let session = "simulator-" + UUID().uuidString
        let model = DockModel(initialSessionID: session, rpcClient: SimulatorTestRPC())
        let key = WorkspaceIdentity.session(model)
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": "herm.simulator.v1", "status": "ready", "platform": "ios",
            "device_id": "uuid", "device_name": "Phone", "host": ProcessInfo.processInfo.hostName,
        ])
        let result = try #require(String(data: data, encoding: .utf8))
        let payload: [String: Any] = [
            "tool_id": "launch", "name": "herm_simulator", "args": ["action": "launch"], "result": result,
        ]
        model.handleEvent("tool.start", params: ["session_id": session, "payload": payload])
        model.handleEvent("tool.complete", params: ["session_id": "other", "payload": payload])
        #expect(SessionSimulatorLaunchStore.shared.request(for: key, platform: .ios) == nil)
        model.handleEvent(
            "tool.complete", params: ["session_id": session, "payload": payload, "herm_trace_replayed": true])
        #expect(SessionSimulatorLaunchStore.shared.request(for: key, platform: .ios) == nil)
        var live = payload
        live["tool_id"] = "live-launch"
        model.handleEvent("tool.start", params: ["session_id": session, "payload": live])
        model.handleEvent("tool.complete", params: ["session_id": session, "payload": live])
        #expect(SessionSimulatorLaunchStore.shared.request(for: key, platform: .ios)?.callID == "live-launch")
    }

}

@MainActor
private final class SimulatorTestRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    func connect() async throws {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    func close() {}
}
