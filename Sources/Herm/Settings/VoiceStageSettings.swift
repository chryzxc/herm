import SwiftUI

struct VoiceStageSettings: View {
    static let activityPillsKey = "herm.voice.activityPills"
    @AppStorage(activityPillsKey) private var showsActivityPills = true

    var body: some View {
        SettingsPreferenceRow(
            title: "Activity cards",
            detail: "Show short-lived cards around the voice orb for tool steps, results, and errors."
        ) {
            Toggle("Activity cards", isOn: $showsActivityPills)
                .labelsHidden().toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
        }
    }
}
