import Foundation

/// Herm-owned preference, served to the agent through `HermAgentSurfaces`.
enum HermesSimulatorPreference {
    static let key = "herm.simulators.openInHerm"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    /// Off removes the rules and guards; the plugin tells running sessions the rules changed.
    static func agentSurface(defaults: UserDefaults = .standard) -> HermAgentSurface? {
        guard isEnabled(defaults: defaults) else { return nil }
        let message =
            "Blocked by Herm: Open simulators in Herm is on. Launch the device with the herm_simulator tool so it opens in this chat's tab, then use the returned device ID. The user can turn this off in Herm Settings → Chat → Simulators."
        return HermAgentSurface(
            id: "herm.simulator",
            rules: """
                Mobile devices: to launch or open an iOS simulator or Android emulator, use the herm_simulator tool; Herm opens the device in this chat's tab. Infer the platform and device from the project and conversation; list devices or ask when ambiguous. Do not open Simulator.app or Android Studio, or boot a device directly. Build, install and run the app with normal project tools against the returned device ID. If herm_simulator is unavailable, report the missing Herm plugin instead of launching an external window. Never claim the display is connected merely because boot succeeded. To inspect and navigate that device, use herm_simulator_interact with its exact device_id: capture first, then tap/swipe/button/key, and verify the returned screenshot or hierarchy. If unavailable, report the missing plugin update. Desktop computer_use is not the direct device bridge.
                """,
            guards: [
                #"\bopen\b[^;&|\n]*\bSimulator(\.app)?\b"#,
                #"\bopen\b[^;&|\n]*\bAndroid Studio\b"#,
                #"\bxcrun\s+simctl\s+boot\b"#,
                #"\bemulator\b[^;&|\n]*\s-avd\b"#,
            ].map { .init(tool: "terminal", argument: "command", pattern: $0, message: message) })
    }
    /// Fallback for a Hermes without the `herm` plugin, whose rules and live guards replace this note.
    static func applying(
        to params: [String: Any], method: String, defaults: UserDefaults = .standard,
        servedByPlugin: Bool = HermPlugin.isLoaded
    ) -> [String: Any] {
        guard !servedByPlugin,
            [
                HermesFeatureIDs.ID.promptSubmit.rawValue,
                HermesFeatureIDs.ID.sessionRedirect.rawValue,
                HermesFeatureIDs.ID.sessionSteer.rawValue,
            ].contains(method), let text = params["text"] as? String, !text.isEmpty
        else { return params }
        let instruction: String
        if isEnabled(defaults: defaults) {
            instruction = """
                Herm setting — Open simulators in Herm: ON.
                For requests to launch or open an iOS simulator or Android emulator, use the herm_simulator tool.
                Infer the platform/device from the user's project and conversation; list devices or ask when ambiguous.
                Do not bypass it with open -a Simulator, Android Studio, or a direct emulator launch command.
                The tool boots the device and returns a receipt so Herm opens the matching session tab and connects directly.
                If the tool is unavailable, report the missing Herm simulator plugin and ask for setup; do not launch an external window instead.
                Build, install, and run the user's app using normal project tools against the returned device ID.
                Use herm_simulator_interact to capture and navigate that exact device. Capture first; use normalized coordinates from the screenshot or hierarchy for tap/swipe, then verify the returned capture. If unavailable, report the missing plugin update. Desktop computer_use is not the direct device bridge.
                This preference applies to launches requested from this Herm session; never claim a display is connected merely because boot succeeded.
                """
        } else {
            instruction = """
                Herm setting — Open simulators in Herm: OFF.
                This supersedes earlier ON instructions in this conversation. Herm no longer requires the herm_simulator launch tool or automatically opens simulator tabs.
                Follow the user's requested simulator workflow using available tools. Do not change or stop already-running devices merely because this setting is off.
                """
        }
        var result = params
        result["text"] = text + "\n\n<herm-simulator-preference>\n" + instruction + "\n</herm-simulator-preference>"
        return result
    }
}
