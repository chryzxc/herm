import Testing

@testable import Herm

struct InspectorRevealTests {
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
