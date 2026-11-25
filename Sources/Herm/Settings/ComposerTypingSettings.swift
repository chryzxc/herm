import SwiftUI

struct ComposerTypingSettings: View {
    static let autocorrectKey = "herm.composer.autocorrect"
    static let followUpSuggestionsKey = "herm.composer.followUpSuggestions"
    @AppStorage(autocorrectKey) private var autocorrectEnabled = true
    @AppStorage(followUpSuggestionsKey) private var followUpSuggestionsEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPreferenceRow(
                title: "Autocorrect in chat",
                detail:
                    "Use macOS spelling correction while typing in chat composers. Supports the languages available on this Mac."
            ) {
                Toggle("Autocorrect in chat", isOn: $autocorrectEnabled)
                    .labelsHidden().toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
            }
            Divider().overlay(Color.dockBorderLight)
            SettingsPreferenceRow(
                title: "Suggest follow-ups with Apple Intelligence",
                detail: OnDeviceAssist.isAvailable
                    ? "Use recent messages to suggest a follow-up on this Mac. Press Tab to insert it without sending."
                    : OnDeviceAssist.unavailableMessage
            ) {
                Toggle("Suggest follow-ups with Apple Intelligence", isOn: $followUpSuggestionsEnabled)
                    .labelsHidden().toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
            }
        }
    }
}
