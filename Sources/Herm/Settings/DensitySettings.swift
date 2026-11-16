import SwiftUI

struct DensitySettings: View {
    @AppStorage(DockWorkspaceScale.preferenceKey) private var textSize = DockWorkspaceScale.defaultTextSize

    var body: some View {
        SettingsPreferenceRow(
            title: "Density",
            detail:
                "Compact reduces spacing and margins across Herm, including floating panels, without changing text size."
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
