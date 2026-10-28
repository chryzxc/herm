import SwiftUI

@main
struct HermApp: App {
    @NSApplicationDelegateAdaptor(HermDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
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
