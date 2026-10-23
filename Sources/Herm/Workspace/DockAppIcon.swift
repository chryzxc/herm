import AppKit
import SwiftUI

@MainActor
enum DockAppBrand {
    static let icon = image("DockAppIcon", "png") ?? NSImage(size: NSSize(width: 32, height: 32))
    /// The Hermes desktop's etched filler art (MIT, Nous Research), drawn by the Hermes skin backdrop.
    static let backdrop = image("HermesBackdrop", "jpg")

    private static func image(_ name: String, _ ext: String) -> NSImage? {
        let resources = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("Herm_Herm.bundle"))
        } ?? Bundle.module
        return resources.url(forResource: name, withExtension: ext).flatMap(NSImage.init(contentsOf:))
    }
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
