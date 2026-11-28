import Foundation
import Testing

@testable import Herm

struct InspectorRevealTests {
    @MainActor
    @Test(arguments: [false, true])
    func onlyThePresentableOwnerCanSelectTheExactBrowserTab(extra: Bool) throws {
        let owner = DockModel(initialSessionID: "same-chat", loadArchives: false)
        let other = DockModel(initialSessionID: "same-chat", loadArchives: false)
        owner.profileScopeID = "owner"
        other.profileScopeID = "other"
        let key = try #require(owner.browserSessionKey)
        let expected: AgentPreviewReveal.Selection = extra ? .extra(UUID()) : .primary
        let messagesBefore = owner.messages.count
        owner.presentAgentPreview("https://example.com/preview", inHerm: true, external: { _ in
            Issue.record("Unexpected external open")
        }) { request in
            request.present(in: other, canPresent: true) { _ in
                Issue.record("A competing chat claimed the request")
                return .primary
            }
            request.present(in: owner, canPresent: false) { _ in
                Issue.record("A hidden host claimed the request")
                return .primary
            }
            request.present(in: owner, canPresent: true) { selectedOwner in
                #expect(selectedOwner == key)
                return expected
            }
            #expect(request.selection == expected)
        }
        #expect(owner.messages.count == messagesBefore)
    }

    @MainActor
    @Test func missingInspectorAndInvalidURLReportFailureWithoutExternalFallback() {
        let owner = DockModel(initialSessionID: "preview-chat", loadArchives: false)
        let address = "https://example.com/preview"
        let rejectExternal: (URL) -> Void = { _ in Issue.record("Unexpected external open") }
        owner.presentAgentPreview(address, inHerm: true, external: rejectExternal, reveal: { _ in })
        #expect(owner.messages.last?.text == "Herm couldn’t show this page in this chat’s Browser tab.")
        owner.presentAgentPreview("file:///example", inHerm: true, external: rejectExternal) { _ in
            Issue.record("Invalid URL offered to an inspector")
        }
        let messageCount = owner.messages.count
        var openedURL: URL?
        owner.presentAgentPreview(address, inHerm: false, external: { openedURL = $0 }) { _ in
            Issue.record("Explicit external preference offered to an inspector")
        }
        #expect(openedURL?.absoluteString == address)
        #expect(owner.messages.count == messageCount)
    }

    @MainActor
    @Test(arguments: ["preview.read", "preview.act"])
    func previewCallbacksStillHaveNoRenderer(method: String) {
        #expect(HermesGateway.event(forServerRequest: ["id": "preview-request", "method": method]) == nil)
    }

    @Test func agentTabsMapOnlyToRealInspectorTabs() {
        #expect(SessionInspector.Section(agentTab: "review") == .changes)
        #expect(SessionInspector.Section(agentTab: "files") == .files)
        #expect(SessionInspector.Section(agentTab: "chat") == nil)
        #expect(SessionInspector.Section(agentTab: "Browser") == nil)
        #expect(SessionInspector.Section.receipt(#"{"schema":"herm.inspector.v1","tab":"terminal"}"#) == .terminal)
        #expect(SessionInspector.Section.receipt(#"{"schema":"herm.simulator.v1","tab":"terminal"}"#) == nil)
        #expect(SessionInspector.Section.receipt(#"{"error":"Tab must be one of: files."}"#) == nil)
    }
}
