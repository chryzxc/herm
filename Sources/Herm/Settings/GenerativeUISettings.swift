import SwiftUI

struct GenerativeUISettings: View {
    @AppStorage(GenerativeUIIntegration.preferenceKey) private var enabled = true
    var body: some View {
        SettingsPreferenceRow(
            title: "Generative UI",
            detail: "Show generated visual previews in Voice mode and Talk. Written chats use Markdown."
        ) {
            Toggle("Generative UI", isOn: $enabled)
                .labelsHidden().toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
        }
        .onChange(of: enabled) { _, value in
            if !value { GeneratedHTMLCoordinator.shared.close() }
        }
    }
}
