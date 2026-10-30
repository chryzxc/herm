import SwiftUI

struct DensitySettings: View {
    @AppStorage(DockWorkspaceScale.preferenceKey) private var textSize = DockWorkspaceScale.defaultTextSize

    var body: some View {
        SettingsPreferenceRow(
            title: "Density",
            detail:
                "Compact shrinks text, icons, avatars, controls, and margins across Herm, including floating panels."
        ) {
            DockSegmentedPicker(
                selection: Binding(
                    get: { DockWorkspaceScale.supportedTextSize(textSize) },
                    set: { textSize = $0 }
                ),
                options: [
                    (DockWorkspaceScale.defaultTextSize, "Default"),
                    (DockWorkspaceScale.compactTextSize, "Compact"),
                ]
            )
        }
    }
}
