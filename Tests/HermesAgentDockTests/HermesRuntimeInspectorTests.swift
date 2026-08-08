import Testing
@testable import HermesAgentDock

struct HermesRuntimeInspectorTests {
    @Test func stripsANSIControlSequences() {
        let decorated = "\u{001B}[32menabled\u{001B}[0m"

        #expect(HermesRuntimeInspector.stripANSI(decorated) == "enabled")
    }

    @Test func leavesPlainTextUnchanged() {
        #expect(HermesRuntimeInspector.stripANSI("plain output") == "plain output")
    }
}
