import Foundation
import Testing

@testable import Herm

struct HermesLocalProcessTests {
    @Test func bootedSimulatorIsParsedFromSimctl() {
        let json = #"{"devices":{"iOS-18":[{"name":"iPhone 16","state":"Booted"}],"iOS-17":[]}}"#
        #expect(HermesLocalSimulator.parseBootedName(Data(json.utf8)) == "iPhone 16")
        #expect(HermesLocalSimulator.parseBootedName(Data(#"{"devices":{}}"#.utf8)) == nil)
    }

    @Test func captureTimesOut() async {
        await #expect(throws: HermesLocalProcessError.limit) {
            try await HermesLocalProcess.capture("/bin/sleep", arguments: ["5"], timeout: 0.1)
        }
    }

    @Test func capturePropagatesCancellation() async throws {
        let probe = Task {
            try await HermesLocalProcess.capture("/bin/sleep", arguments: ["5"], timeout: 2)
        }
        try await Task.sleep(for: .milliseconds(100))
        probe.cancel()
        await #expect(throws: CancellationError.self) { try await probe.value }
    }
}
