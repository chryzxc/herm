import SwiftUI

struct ComposerTypingSettings: View {
    static let autocorrectKey = "herm.composer.autocorrect"
    @AppStorage(autocorrectKey) private var autocorrectEnabled = true

    var body: some View {
        SettingsPreferenceRow(
            title: "Autocorrect in chat",
            detail:
                "Use macOS spelling correction while typing in chat composers. Supports the languages available on this Mac."
        ) {
            Toggle("Autocorrect in chat", isOn: $autocorrectEnabled)
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Color.dockAccent)
        }
    }
}
