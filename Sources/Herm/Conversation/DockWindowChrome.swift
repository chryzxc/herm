import AppKit
import Combine
import SwiftUI
import Foundation
import UniformTypeIdentifiers

/// Geometry of the window's unified title row (see DockWindowController).
enum DockWindowChrome {
    static let titleRowHeight: CGFloat = 52
    /// Space the session list keeps clear of the traffic lights, measured from its leading edge beside the 52pt rail.
    static let trafficLightClearance: CGFloat = 28
    /// Full-width overlays start before the 52pt navigation rail.
    static let fullWidthTrafficLightClearance: CGFloat = 52 + trafficLightClearance
    /// Leading inset of the sidebar toggle in every title row, so it never moves as panes collapse.
    static let sidebarToggleLeading: CGFloat = trafficLightClearance + 4
    /// Hairline under the title row, drawn by each column so it runs the full window width.
    static var titleRowSeparator: some View { Color.dockBorderLight.frame(height: DockLayout.hairline) }
}

extension View {
    /// Clears the titlebar strip; the strip itself drags and zooms the window.
    /// The sidebar passes `separator: false` so its strip flows into the list like a native sidebar.
    func underTitlebar(_ inset: CGFloat, separator: Bool = true) -> some View {
        padding(.top, inset)
            .overlay(alignment: .top) {
                if inset > 0 {
                    TitlebarDoubleClickArea().frame(height: inset)
                        .background(Color.dockSidebar)
                        .overlay(alignment: .bottom) { if separator { DockWindowChrome.titleRowSeparator } }
                }
            }
    }
}

/// Transparent titlebar strip: double-click follows the system title-bar preference (zoom by default), single-click drags it.
struct TitlebarDoubleClickArea: NSViewRepresentable {
    final class Strip: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                // Honor System Settings > Desktop & Dock > "Double-click a window's title bar to".
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window?.miniaturize(nil)
                case "None": break
                default: window?.zoom(nil)
                }
            } else { super.mouseDown(with: event) }
        }
    }

    func makeNSView(context: Context) -> Strip { Strip() }
    func updateNSView(_ view: Strip, context: Context) {}
}

/// The 3-second "bot is running / finished" pill stack, shared by the rail and the notch.
struct BotActivityBanner: View {
    let events: [BotActivityEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(events) { event in
                HStack(spacing: 6) {
                    DockActivityIndicator(state: event.finished ? .done : .running, size: 12)
                    Text(event.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .dockFloatingSurface(Capsule(), tint: .dockSurface2, stroke: .dockBorderLight)
                .shadow(color: .black.opacity(DockThemeStyle.current.material == .glass ? 0 : 0.12), radius: 6, y: 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(events.map(\.text).joined(separator: ", "))
    }
}
