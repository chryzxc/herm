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

    @Test func providerSelectionUpdatesOnlyGlobalDefault() {
        let option = HermesModelOption(provider: "opencode-zen", model: "gpt-5.6")

        let request = DockModel.globalRuntimeModelSwitchRequest(option: option)

        #expect(request == HermesRuntimeModelSwitchRequest(
            sessionID: nil,
            value: "gpt-5.6 --provider opencode-zen --global"
        ))
        #expect(request.parameters["confirm_expensive_model"] as? Bool == true)
    }

    @Test func providerSelectionUpdatesOnlyActiveSession() {
        let request = DockModel.sessionRuntimeModelSwitchRequest(
            option: HermesModelOption(provider: "anthropic", model: "claude-sonnet-4-6"),
            sessionID: "session-42"
        )

        #expect(request == HermesRuntimeModelSwitchRequest(
            sessionID: "session-42",
            value: "claude-sonnet-4-6 --provider anthropic --session"
        ))
        #expect(request.parameters["confirm_expensive_model"] as? Bool == true)
    }
}
