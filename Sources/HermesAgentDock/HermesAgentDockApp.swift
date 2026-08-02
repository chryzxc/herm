import SwiftUI

@main
struct HermesAgentDockApp: App {
    @StateObject private var model = DockModel()

    var body: some Scene {
        MenuBarExtra {
            DockPopover(model: model)
        } label: {
            Text("H")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .menuBarExtraStyle(.window)
    }
}
