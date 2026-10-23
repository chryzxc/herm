import Foundation
import Testing

@testable import Herm

struct MoAConfigTests {
    private func sample() throws -> HermesMoAConfig {
        try HermesMoAConfig([
            "ok": true,
            "default_preset": "default",
            "presets": [
                "default": [
                    "reference_models": [
                        ["provider": "openai-codex", "model": "gpt-5.5", "enabled": true, "reasoning_effort": "high"],
                        ["provider": "", "model": "dropped"],
                    ],
                    "aggregator": ["provider": "openrouter", "model": "anthropic/claude-opus-4.8"],
                    "fanout": "every_n:3",
                    "enabled": true,
                ]
            ],
        ])
    }

    @Test func parsesPresetSlotsAndDropsIncompleteOnes() throws {
        let config = try sample()
        #expect(config.defaultPreset == "default")
        #expect(config.presetNames == ["default"])
        #expect(config.references("default").map(\.model) == ["gpt-5.5"])
        #expect(config.references("default").first?.reasoningEffort == "high")
        #expect(config.aggregator("default")?.provider == "openrouter")
        #expect(config.raw["ok"] == nil)
    }

    @Test func editsKeepFieldsTheEditorDoesNotShow() throws {
        var config = try sample()
        var refs = config.references("default")
        refs.append(HermesMoASlot(provider: "openrouter", model: "deepseek/deepseek-v4-pro"))
        config.update("default", references: refs, enabled: false)

        let preset = (config.raw["presets"] as? [String: [String: Any]])?["default"]
        #expect(preset?["fanout"] as? String == "every_n:3")
        #expect(preset?["enabled"] as? Bool == false)
        #expect(config.references("default").count == 2)
        #expect((preset?["reference_models"] as? [[String: Any]])?.first?["reasoning_effort"] as? String == "high")
    }

    @Test func rejectsResponsesWithoutPresets() {
        #expect(throws: (any Error).self) { try HermesMoAConfig(["ok": true]) }
    }

    @Test func moaEventsRenderAsReasoningLines() {
        #expect(
            DockModel.moaReasoningLine(type: "moa.progress", payload: ["refs_done": 1, "refs_total": 2])
                == "◇ MoA refs 1/2\n")
        #expect(
            DockModel.moaReasoningLine(type: "moa.phase", payload: ["phase": "aggregator"]) == "◇ MoA aggregating…\n")
        #expect(
            DockModel.moaReasoningLine(type: "moa.reference", payload: ["label": "gpt-5.5", "text": "Use a map."])
                == "◇ gpt-5.5\nUse a map.\n")
        #expect(DockModel.moaReasoningLine(type: "moa.progress", payload: [:]) == nil)
    }
}
