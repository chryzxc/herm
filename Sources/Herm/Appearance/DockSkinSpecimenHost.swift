import AppKit
import SwiftUI

/// Keeps notch-specific appearance from leaking into gallery specimens.
struct DockSkinSpecimenHost<Content: View>: NSViewRepresentable {
    let theme: DockThemeID
    let colorScheme: ColorScheme
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        NSHostingView(rootView: content())
    }

    func updateNSView(_ view: NSHostingView<Content>, context: Context) {
        view.appearance =
            DockThemeStore.nsAppearance(for: theme)
            ?? NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        view.rootView = content()
    }
}
