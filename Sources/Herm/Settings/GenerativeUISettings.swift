import SwiftUI

struct GenerativeUISettings: View {
    @AppStorage(GenerativeUIIntegration.preferenceKey) private var enabled = true
    var body: some View {
        SettingsPreferenceRow(
            title: "Generative UI", detail: "Show visual replies when useful. Turn off to show readable text."
        ) {
            Toggle("Generative UI", isOn: $enabled)
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Color.dockAccent)
        }
        .onChange(of: enabled) { _, value in
            if !value { GeneratedHTMLCoordinator.shared.close() }
        }
    }
}
