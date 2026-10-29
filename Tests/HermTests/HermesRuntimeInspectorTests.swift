import Testing

@testable import Herm

struct HermesRuntimeInspectorTests {
    @Test func inspectionReadsPathOnceAndPublishesIdentityBeforeSettings() {
        var calls: [[String]] = []
        var identityPublished = false
        var metadataCaptured = false
        let outcome = HermesRuntimeInspector.inspect(
            runner: { arguments in
                calls.append(arguments)
                if arguments == ["config", "path"] { return "/fixture/config.yaml" }
                #expect(identityPublished)
                if arguments == ["skills", "list", "--enabled-only"] { return "[]" }
                if arguments == ["mcp", "list"] { return "No MCP servers configured" }
                if arguments == ["plugins", "list", "--enabled", "--json"] { return "[]" }
                return "value"
            },
            identityReader: { _ in
                #expect(metadataCaptured)
                return "Fixture"
            },
            signatureReader: { path in
                #expect(calls == [["config", "path"]])
                #expect(path == "/fixture/config.yaml")
                metadataCaptured = true
                return "before"
            },
            onIdentity: { name in
                #expect(name == "Fixture")
                identityPublished = true
            }
        )
        #expect(calls.filter { $0 == ["config", "path"] }.count == 1)
        #expect(calls.count == 8)
        #expect(
            calls == [
                ["config", "path"], ["config", "get", "model.default"],
                ["config", "get", "model.provider"], ["config", "get", "agent.max_turns"],
                ["config", "get", "terminal.timeout"], ["skills", "list", "--enabled-only"],
                ["mcp", "list"], ["plugins", "list", "--enabled", "--json"],
            ])
        #expect(outcome.isComplete)
        #expect(outcome.configuration.agentName == "Fixture")
        #expect(outcome.initialSignature == "before")
    }

    @Test func partialAndMalformedInspectionCannotCertifyFreshness() {
        for failure in ["missing", "malformed"] {
            let outcome = HermesRuntimeInspector.inspect(
                runner: { arguments in
                    if arguments == ["config", "path"] { return "/fixture/config.yaml" }
                    if arguments == ["skills", "list", "--enabled-only"] { return "[]" }
                    if arguments == ["mcp", "list"] { return "No MCP servers configured" }
                    if arguments == ["plugins", "list", "--enabled", "--json"] {
                        return failure == "missing" ? nil : "not json"
                    }
                    return "value"
                }, identityReader: { _ in "Fixture" })
            #expect(!outcome.isComplete)
            #expect(outcome.configuration.agentName == "Fixture")
        }
    }

    @Test func everyMissingCommandOutputIsIncomplete() {
        for missing in 0..<8 {
            var index = 0
            let outcome = HermesRuntimeInspector.inspect(
                runner: { arguments in
                    defer { index += 1 }
                    if index == missing { return nil }
                    if arguments == ["config", "path"] { return "/fixture/config.yaml" }
                    if arguments == ["skills", "list", "--enabled-only"] { return "[]" }
                    if arguments == ["mcp", "list"] { return "No MCP servers configured" }
                    if arguments == ["plugins", "list", "--enabled", "--json"] { return "[]" }
                    return "value"
                }, identityReader: { _ in "Fixture" })
            #expect(!outcome.isComplete)
        }
    }

    @Test func preservesInventoryParsingWithInjectedCommands() {
        let outcome = HermesRuntimeInspector.inspect(
            runner: { arguments in
                if arguments == ["config", "path"] { return "/fixture/config.yaml" }
                if arguments == ["skills", "list", "--enabled-only"] { return "│ fixture-skill │ enabled │" }
                if arguments == ["mcp", "list"] { return "fixture-server stdio all connected" }
                if arguments == ["plugins", "list", "--enabled", "--json"] {
                    return #"[{"name":"fixture-plugin","status":"enabled"}]"#
                }
                return "value"
            }, identityReader: { _ in nil })
        #expect(outcome.isComplete)
        #expect(outcome.configuration.skills == ["fixture-skill"])
        #expect(outcome.configuration.mcpServers == ["fixture-server"])
        #expect(outcome.configuration.plugins == ["fixture-plugin"])
    }

    @Test func ignoresTruncatedRowsButKeepsCompleteHumanTableSkillNames() {
        let output = "│ my-dev-team-orchest… │ enabled │"

        #expect(HermesRuntimeInspector.parseEnabledSkills(output) == .unavailable(.unsupportedOutput))
    }

    @Test func rejectsUnrecognizedNonemptySkillOutputAsUnavailable() {
        #expect(
            HermesRuntimeInspector.parseEnabledSkills("skills loaded successfully") == .unavailable(.unsupportedOutput))
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
        #expect(
            HermesReasoningVariant.allCases.map(\.rawValue) == [
                "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
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

        #expect(
            request
                == HermesRuntimeModelSwitchRequest(
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

        #expect(
            request
                == HermesRuntimeModelSwitchRequest(
                    sessionID: "session-42",
                    value: "claude-sonnet-4-6 --provider anthropic --session"
                ))
        #expect(request.parameters["confirm_expensive_model"] as? Bool == true)
    }

    @Test func sessionModelSwitchKeepsThinkingDepth() {
        let request = DockModel.sessionRuntimeModelSwitchRequest(
            option: HermesModelOption(provider: "anthropic", model: "claude-sonnet-4-6"),
            sessionID: "session-42",
            reasoning: .high
        )

        #expect(request.value == "claude-sonnet-4-6 --provider anthropic --session --reasoning high")
    }

    @MainActor @Test func remoteInspectionProjectsBackendRESTAndFlagsMissingRoutes() async {
        let routes: [String: [String: Any]] = [
            "/api/model/info": ["model": "gpt-5", "provider": "openai-codex"],
            "/api/config": ["agent": ["max_turns": 90], "terminal": ["timeout": 180]],
            "/api/skills": ["items": [["name": "git", "enabled": true], ["name": "off", "enabled": false]]],
            "/api/mcp/servers": ["servers": [["name": "github", "enabled": true]]],
            "/api/dashboard/plugins/hub": [
                "plugins": [
                    ["name": "memory", "runtime_status": "enabled"], ["name": "x", "runtime_status": "inactive"],
                ]
            ],
        ]
        let full = await HermesRuntimeInspector.inspectRemote { path in
            guard let value = routes[path] else { throw HermesGateway.GatewayError.malformedResponse }
            return value
        }
        #expect(full.isComplete)
        #expect(full.configuration.model == "gpt-5")
        #expect(full.configuration.provider == "openai-codex")
        #expect(full.configuration.maxTurns == "90")
        #expect(full.configuration.terminalTimeout == "180")
        #expect(full.configuration.skillsInventory == .supported(["git"]))
        #expect(full.configuration.mcpServers == ["github"])
        #expect(full.configuration.plugins == ["memory"])
        #expect(full.configuration.agentName == nil && full.configuration.configPath == nil)

        let partial = await HermesRuntimeInspector.inspectRemote { path in
            guard path != "/api/skills", let value = routes[path] else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            return value
        }
        #expect(!partial.isComplete)
        #expect(partial.configuration.skillsInventory == .unavailable(.unsupportedOutput))
    }
}
