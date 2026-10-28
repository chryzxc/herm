import SwiftUI

struct SimulatorSettings: View {
    @AppStorage(HermesSimulatorPreference.key) private var enabled = true

    var body: some View {
        SettingsPreferenceRow(
            title: "Open simulators in Herm",
            detail:
                "Ask the agent to launch iOS and Android devices through Herm and open their tabs automatically. Requires the Herm simulator tool. Changes apply to your next message; running devices stay open. This guides the agent and does not block terminal commands."
        ) {
            Toggle("Open simulators in Herm", isOn: $enabled)
                .labelsHidden().toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
        }
    }
}
