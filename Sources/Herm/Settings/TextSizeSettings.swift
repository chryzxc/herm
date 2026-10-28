import SwiftUI

struct TextSizeSettings: View {
    @AppStorage(DockWorkspaceScale.preferenceKey) private var textSize = DockWorkspaceScale.defaultTextSize

    var body: some View {
        SettingsPreferenceRow(
            title: "Text size",
            detail: "Scales text, icons, and controls across Herm, including floating panels."
        ) {
            Picker(
                "Text size",
                selection: Binding(
                    get: { DockWorkspaceScale.supportedTextSize(textSize) },
                    set: { textSize = $0 }
                )
            ) {
                Text("Small").tag(1.0)
                Text("Default").tag(1.1)
                Text("Large").tag(1.2)
                Text("Larger").tag(1.3)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 300)
        }
    }
}
