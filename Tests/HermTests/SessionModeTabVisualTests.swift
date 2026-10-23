import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SessionModeTabVisualTests {
    @Test func renderHeaderTabs() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SESSION_TAB_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let savedTheme = DockThemeRuntime.current
        defer { DockThemeRuntime.current = savedTheme }
        let appearances: [(DockThemeID, Bool)] = [(.glass, false), (.glass, true), (.mono, true), (.eInk, false)]
        for (theme, dark) in appearances {
            DockThemeRuntime.current = theme
            let style = DockThemePalette(theme: theme)
            let root = VStack(alignment: .leading, spacing: 12) {
                Text("\(theme.title) — \(dark ? "dark" : "light")").font(DockTypography.pageTitle)
                DockPageHeader(title: "Calendar", subtitle: "Your Mac calendar, reminders, and scheduled work")
                    .environment(\.dockTitleRow, DockTitleRow(height: 52, leadingClearance: 28))
                ForEach([false, true], id: \.self) { collapsed in
                    DockPageHeader(
                        title: "Pull requests", subtitle: "Review your GitHub work",
                        sidebarCollapsed: .constant(collapsed)
                    )
                    .environment(\.dockTitleRow, DockTitleRow(height: 52, leadingClearance: 28))
                }
                ForEach([DockPopover.SessionWorkspaceMode.chat, .voice, .pullRequests]) { mode in
                    header(style: style, selected: mode).frame(width: 520)
                }
                header(style: style, selected: .chat).frame(width: 360)
                SessionModeTabStrip(modes: [.chat, .voice], selectedMode: .chat, style: style, onSelect: { _ in })
                SessionModeTabStrip(
                    modes: [.chat, .voice, .pullRequests], selectedMode: .voice, style: style, onSelect: { _ in }
                ).disabled(true)
            }
            .padding(16)
            .foregroundStyle(style.primaryText)
            .background(style.background)
            .dockThemedRoot()
            .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent(
                    "\(theme.rawValue)-\(dark ? "dark" : "light").png"))
            window.orderOut(nil)
        }
    }

    private func header(style: DockThemePalette, selected: DockPopover.SessionWorkspaceMode) -> some View {
        HStack(spacing: 8) {
            DockSidebarToggle(isCollapsed: true, edge: .leading, action: {})
            Text("Parallel compliance repo work")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 12)
            SessionModeTabStrip(
                modes: [.chat, .voice, .pullRequests], selectedMode: selected, style: style, onSelect: { _ in })
            DockIcon(.dotsThree, size: 14, color: style.secondaryText).frame(width: 28, height: 28)
            DockSidebarToggle(isCollapsed: true, edge: .trailing, action: {})
        }
        .padding(.leading, DockWindowChrome.sidebarToggleLeading)
        .padding(.trailing, 12)
        .frame(height: DockWindowChrome.titleRowHeight)
        .background(Color.dockSidebar)
        .overlay(alignment: .bottom) { DockWindowChrome.titleRowSeparator }
    }
}
