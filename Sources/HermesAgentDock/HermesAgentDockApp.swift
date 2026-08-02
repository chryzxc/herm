import SwiftUI

@main
struct HermesAgentDockApp: App {
    @StateObject private var model = DockModel()

    var body: some Scene {
        MenuBarExtra {
            DockPopover(model: model)
        } label: {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 14))
                .overlay(alignment: .topTrailing) {
                    if model.hasUnreadResponse {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .overlay {
                                Circle()
                                    .stroke(Color.black.opacity(0.35), lineWidth: 0.5)
                            }
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .menuBarExtraStyle(.window)
    }
}
