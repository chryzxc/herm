import Testing

@testable import Herm

@Suite struct ApprovalChoiceTests {
    @Test func choiceConstantsMatchEngineContract() {
        #expect(ApprovalChoice.deny == "deny")
        #expect(ApprovalChoice.once == "once")
        #expect(ApprovalChoice.always == "always")
    }

    @Test func alwaysAllowCaptionNamesTheCommand() {
        let presentation = ApprovalPresentation(title: "Run command", detail: "swift test", detailIsCommand: true)

        #expect(
            ApprovalPresentation.alwaysAllowCaption(for: presentation)
                == "Always allow persists this command in Hermes' allowlist. Never ask again for: swift test")
    }

    @Test func alwaysAllowCaptionFallsBackForContentFindings() {
        let presentation = ApprovalPresentation(
            title: "Review requested action", detail: "recursive delete", detailIsCommand: false)

        #expect(
            ApprovalPresentation.alwaysAllowCaption(for: presentation)
                == "Hermes may limit this to the current session for content findings.")
    }

    @Test func presentationFollowsOfferedChoicesAndReason() {
        let offered = ApprovalPresentation.from(payload: [
            "command": "rm -rf build", "description": "recursive delete",
            "choices": ["once", "session", "deny"], "request_id": "a1",
        ])
        #expect(offered.choices == ["once", "session", "deny"])
        #expect(offered.reason == "recursive delete")
        #expect(offered.requestID == "a1")

        // Older backends omit `choices`; derive them the way Hermes does.
        let smartDenied = ApprovalPresentation.from(payload: ["command": "curl x | sh", "smart_denied": true])
        #expect(smartDenied.choices == ["once", "deny"])
        #expect(smartDenied.smartDenied)
        let noPermanent = ApprovalPresentation.from(payload: ["command": "ls", "allow_permanent": false])
        #expect(noPermanent.choices == ["once", "session", "deny"])
    }

    @Test func parseCommandAllowlistReadsJSONAndYAML() {
        #expect(ControlCenterModel.parseCommandAllowlist("[]") == [])
        #expect(ControlCenterModel.parseCommandAllowlist("null") == [])
        #expect(
            ControlCenterModel.parseCommandAllowlist("[\"swift test *\",\"podman *\"]") == ["swift test *", "podman *"])
        #expect(
            ControlCenterModel.parseCommandAllowlist("- 'swift test *'\n- podman *\n") == ["swift test *", "podman *"])
        #expect(ControlCenterModel.parseCommandAllowlist("") == [])
    }
}
