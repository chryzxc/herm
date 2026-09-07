import Testing
@testable import HermesAgentDock

@MainActor
struct BotMessageAttributionTests {
    @Test func parsesDocumentedHermesBotDeliveryEnvelope() {
        let attribution = DockModel.botAttribution(
            from: "Message from 🤖 Atlas (@atlas): I found three relevant papers."
        )

        #expect(attribution?.displayName == "Atlas")
        #expect(attribution?.profileID == "atlas")
        #expect(attribution?.body == "I found three relevant papers.")
    }

    @Test func leavesOrdinaryAssistantTextUntouched() {
        #expect(DockModel.botAttribution(from: "Message from Hermes: hello") == nil)
        #expect(DockModel.botAttribution(from: "Atlas (@atlas): hello") == nil)
        #expect(DockModel.botAttribution(from: "Message from 🤖 Atlas (@atlas):") == nil)
    }
}
