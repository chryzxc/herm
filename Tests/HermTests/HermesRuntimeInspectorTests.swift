import Testing
@testable import Herm

struct HermesRuntimeInspectorTests {
    @Test func ignoresTruncatedRowsButKeepsCompleteHumanTableSkillNames() {
        let output = "│ my-dev-team-orchest… │ enabled │"

        #expect(HermesRuntimeInspector.parseEnabledSkills(output) == .unavailable(.unsupportedOutput))
    }

    @Test func rejectsUnrecognizedNonemptySkillOutputAsUnavailable() {
        #expect(HermesRuntimeInspector.parseEnabledSkills("skills loaded successfully") == .unavailable(.unsupportedOutput))
    }

    @Test func acceptsCompleteHumanTableSkillNames() {
        let output = """
        ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━┓
        ┃ Name                                 ┃ Status    ┃
        ┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╋━━━━━━━━━━━┫
        ┃ my-dev-team-orchestrator             ┃ enabled   ┃
        ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┻━━━━━━━━━━━┛
        """

        #expect(HermesRuntimeInspector.parseEnabledSkills(output) == .supported(["my-dev-team-orchestrator"]))
    }

    @Test func acceptsOnlyCompleteStableJSONSkillRecords() {
        let output = #"[{"name":"my-dev-team-orchestrator","status":"enabled"}]"#

        #expect(HermesRuntimeInspector.parseEnabledSkills(output) == .supported(["my-dev-team-orchestrator"]))
    }

    @Test func reasoningVariantsMatchHermesSupportedLevels() {
        #expect(HermesReasoningVariant.allCases.map(\.rawValue) == [
            "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"
        ])
    }

    @Test func stripsANSIControlSequences() {
        let decorated = "\u{001B}[32menabled\u{001B}[0m"

        #expect(HermesRuntimeInspector.stripANSI(decorated) == "enabled")
    }

    @Test func leavesPlainTextUnchanged() {
        #expect(HermesRuntimeInspector.stripANSI("plain output") == "plain output")
    }

    @Test func readsAgentNameFromSoulHeading() {
        let soul = "# Nexus\n\nYou are the primary coordinator."

        #expect(HermesRuntimeInspector.parseAgentName(soul) == "Nexus")
    }

    @Test func ignoresSoulWithoutPrimaryIdentityHeading() {
        #expect(HermesRuntimeInspector.parseAgentName("You are an assistant.\n## Details") == nil)
    }

    @Test func providerSelectionUpdatesOnlyGlobalDefault() {
        let option = HermesModelOption(provider: "opencode-zen", model: "gpt-5.6")

        let request = DockModel.globalRuntimeModelSwitchRequest(option: option, sessionID: "draft")

        #expect(request == HermesRuntimeModelSwitchRequest(
            sessionID: "draft",
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
