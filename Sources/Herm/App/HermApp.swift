import SwiftUI

@main
struct HermApp: App {
    @NSApplicationDelegateAdaptor(HermDelegate.self) private var appDelegate

    var body: some Scene {
        // DockPanelController owns the status item; keep SwiftUI's scene windowless.
        MenuBarExtra(isInserted: .constant(false)) {
            EmptyView()
        } label: {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettings() }
                    .keyboardShortcut(",")
            }
        }
    }
}
