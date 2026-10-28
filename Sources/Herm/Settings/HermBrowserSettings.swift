import SwiftUI

struct HermBrowserSettings: View {
    @AppStorage(AgentBrowser.openInHermKey) private var enabled = true

    var body: some View {
        SettingsPreferenceRow(
            title: "Use Herm's browser",
            detail:
                "Pages the agent opens show in the chat's Browser tab, and the panel opens to it while the agent browses. Off, the agent opens pages in your default browser."
        ) {
            Toggle("Use Herm's browser", isOn: $enabled)
                .labelsHidden().toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
        }
    }
}
