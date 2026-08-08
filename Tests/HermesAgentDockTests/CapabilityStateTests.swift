import Testing
@testable import HermesAgentDock

struct CapabilityStateTests {
    @Test func recoveryCommandIsOptionalMetadata() {
        let state = CapabilityState(id: "gateway", title: "Gateway", detail: "Offline", isAvailable: false, recovery: "Start Hermes", recoveryCommand: "hermes gateway start")

        #expect(state.recoveryCommand == "hermes gateway start")
    }
}
