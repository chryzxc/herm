import Testing

@testable import Herm

struct WorkflowAccessibilityIdentifierTests {
    @Test func criticalWorkflowIdentifiersRemainStableAndUnique() {
        let identifiers = [
            WorkflowAccessibilityIdentifier.terminalCommandInput,
            WorkflowAccessibilityIdentifier.terminalOutput,
            WorkflowAccessibilityIdentifier.terminalRunVerification,
            WorkflowAccessibilityIdentifier.terminalInterrupt,
            WorkflowAccessibilityIdentifier.terminalClearOutput,
            WorkflowAccessibilityIdentifier.changesRefreshGitHub,
        ]
        #expect(Set(identifiers).count == identifiers.count)
        #expect(identifiers.allSatisfy { $0.contains(".") })
    }
}
