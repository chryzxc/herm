import AppKit
import SwiftUI

@MainActor
enum DockAppBrand {
    static let icon: NSImage = {
        let resources = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("HermesAgentDock_HermesAgentDock.bundle"))
        } ?? Bundle.module
        guard let url = resources.url(forResource: "DockAppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(size: NSSize(width: 32, height: 32))
        }
        return image
    }()
}

struct DockAppIcon: View {
    var body: some View {
        Image(nsImage: DockAppBrand.icon)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .accessibilityHidden(true)
    }
}
