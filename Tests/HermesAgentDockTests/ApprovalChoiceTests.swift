import Testing
@testable import HermesAgentDock

@Suite struct ApprovalChoiceTests {
    @Test func choiceConstantsMatchEngineContract() {
        #expect(ApprovalChoice.deny == "deny")
        #expect(ApprovalChoice.once == "once")
        #expect(ApprovalChoice.always == "always")
    }

    @Test func alwaysAllowCaptionNamesTheCommand() {
        let presentation = ApprovalPresentation(title: "Run command", detail: "swift test", detailIsCommand: true)

        #expect(ApprovalPresentation.alwaysAllowCaption(for: presentation)
            == "Always allow persists this command in Hermes' allowlist. Never ask again for: swift test")
    }

    @Test func alwaysAllowCaptionFallsBackForContentFindings() {
        let presentation = ApprovalPresentation(title: "Review requested action", detail: "recursive delete", detailIsCommand: false)

        #expect(ApprovalPresentation.alwaysAllowCaption(for: presentation)
            == "Hermes may limit this to the current session for content findings.")
    }

    @Test func parseCommandAllowlistReadsJSONAndYAML() {
        #expect(ControlCenterModel.parseCommandAllowlist("[]") == [])
        #expect(ControlCenterModel.parseCommandAllowlist("null") == [])
        #expect(ControlCenterModel.parseCommandAllowlist("[\"swift test *\",\"podman *\"]") == ["swift test *", "podman *"])
        #expect(ControlCenterModel.parseCommandAllowlist("- 'swift test *'\n- podman *\n") == ["swift test *", "podman *"])
        #expect(ControlCenterModel.parseCommandAllowlist("") == [])
    }
}
