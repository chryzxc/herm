import Foundation

/// Herm-owned preference, applied at the RPC boundary so chat, voice, and redirects agree.
enum HermesSimulatorPreference {
    static let key = "herm.simulators.openInHerm"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    static func applying(to params: [String: Any], method: String, defaults: UserDefaults = .standard) -> [String: Any]
    {
        guard
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
