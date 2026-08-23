import SwiftUI

@main
struct HermesAgentDockApp: App {
    @NSApplicationDelegateAdaptor(HermesAgentDockDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
