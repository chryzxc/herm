import Testing
@testable import HermesAgentDock

@MainActor
struct DebugLogTests {
    @Test func persistentDiagnosticsDiscardRuntimePayloads() {
        let prompt = "deploy with token=do-not-persist to /Users/example/private"
        let event = DebugLog.persistentEventName(for: "event message.delta: \(prompt)")

        #expect(event == "event")
        #expect(!event.contains("do-not-persist"))
        #expect(!event.contains("/Users/"))
    }

    @Test func unknownDiagnosticContentUsesGenericCategory() {
        let event = DebugLog.persistentEventName(for: "api_key=do-not-persist")

        #expect(event == "diagnostic")
        #expect(!event.contains("do-not-persist"))
    }
}
