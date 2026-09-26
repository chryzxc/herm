import SwiftUI

@main
struct HermApp: App {
    @NSApplicationDelegateAdaptor(HermDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
