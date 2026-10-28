import SwiftUI

enum DesktopCaptureShortcut {
    static let key = "herm.shortcut.window-capture"
    static var stored: QuickCaptureChord {
        UserDefaults.standard.string(forKey: key).flatMap(QuickCaptureChord.init(rawValue:)) ?? .off
    }
}

struct DesktopCaptureSettings: View {
    @AppStorage("herm.capture.includeAppText") private var includeText = false
    var body: some View {
        SettingsPreferenceRow(
            title: "Include app text",
            detail: "Include accessible text with window captures. Requires Accessibility access."
        ) {
            Toggle("Include app text with window captures", isOn: $includeText)
                .labelsHidden().toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
        }
        .onChange(of: includeText) { _, enabled in
            if enabled { _ = DesktopCaptureService.requestAppTextPermission() }
        }
    }
}
