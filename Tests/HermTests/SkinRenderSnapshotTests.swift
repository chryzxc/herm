import AppKit
import SwiftUI
import Testing
@testable import Herm

/// Opt-in visual proof for every skin, plus simultaneous gallery specimens.
@MainActor
struct SkinRenderSnapshotTests {
    @Test func renderSkins() async throws {
        guard let dir = ProcessInfo.processInfo.environment["SKIN_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let savedTheme = DockThemeRuntime.current, savedRevision = DockThemeRuntime.revision
        defer { DockThemeRuntime.current = savedTheme; DockThemeRuntime.revision = savedRevision }
        for theme in DockThemeID.allCases {
            let modes: [Bool] = theme.appearance == .system ? [false, true] : [theme.appearance == .dark]
            for dark in modes {
                DockThemeRuntime.current = theme
                DockThemeRuntime.revision &+= 1
                let palette = DockThemePalette(theme: theme)
                let content = VStack(alignment: .leading, spacing: 16) {
                    Text(theme.title).font(DockTypography.pageTitle)
                    Text(theme.signature).font(DockTypography.body).foregroundStyle(Color.dockSecondaryText)
                    DockSkinSpecimen(theme: theme)
                    DockNavRow(title: "Appearance", icon: .sparkle, isSelected: true, style: palette, action: {})
                    HStack {
                        DockTabButton(title: "Selected", isSelected: true, action: {})
                        DockTabButton(title: "Other", isSelected: false, action: {})
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Surface & typography").font(DockTypography.rowTitle)
                        Text("The quick brown fox jumps over the lazy dog.").font(DockTypography.body).fixedSize(horizontal: false, vertical: true)
                        Text("0123456789 · Aa Bb Cc").font(DockTypography.machineMetadata).foregroundStyle(Color.dockMetadataText)
                    }.frame(maxWidth: .infinity, alignment: .leading).dockCard()
                    HStack {
                        Button("Primary") {}.buttonStyle(.dockPrimary)
                        Button("Secondary") {}.buttonStyle(.dockSecondary)
                    }
                    DockTextField("Message", text: .constant("")).textFieldStyle(.dockGlass)
                }
                .padding(20)
                .frame(width: 320, height: 540, alignment: .topLeading)
                .background(palette.background.overlay(DockBackdrop()))
                .background(dark ? Color.black : Color.white)
                .dockThemedRoot()
                .environment(\.colorScheme, dark ? .dark : .light)
                try await render(content, dark: dark, to: URL(fileURLWithPath: dir).appendingPathComponent("\(theme.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
        for dark in [false, true] {
            DockThemeRuntime.current = dark ? .terminal : .notebook
            let gallery = LazyVGrid(columns: Array(repeating: GridItem(.fixed(190)), count: 4), spacing: 16) {
                ForEach(DockThemeID.allCases) { theme in
                    VStack(alignment: .leading, spacing: 6) {
                        DockSkinSpecimen(theme: theme)
                        Text(theme.title).font(.system(size: 12, weight: .semibold))
                        Text(theme.signature).font(.system(size: 12))
                    }
                }
            }
            .padding(20)
            .frame(width: 828)
            .foregroundStyle(dark ? Color.white : Color.black)
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
            try await render(gallery, dark: dark, to: URL(fileURLWithPath: dir).appendingPathComponent("gallery-\(dark ? "dark" : "light").png"))
        }
    }

    @Test func renderResponsiveGallery() async throws {
        guard let dir = ProcessInfo.processInfo.environment["SKIN_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for width: CGFloat in [320, 680, 1100] {
            for dark in [false, true] {
                let gallery = LazyVGrid(columns: [GridItem(.adaptive(minimum: 224), spacing: 8)], spacing: 8) {
                    ForEach(DockThemeID.allCases) { theme in
                        VStack(alignment: .leading, spacing: 8) {
                            DockSkinSpecimen(theme: theme)
                            Text(theme.title).dockFont(size: 12, weight: .semibold)
                            Text(theme.signature).dockFont(size: 12)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(Rectangle().stroke(.gray, lineWidth: 1))
                    }
                }
                .padding(14)
                .frame(width: width)
                .foregroundStyle(dark ? Color.white : Color.black)
                .background(dark ? Color.black : Color.white)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.dockWorkspaceScale, DockWorkspaceScale.window)
                try await render(gallery, dark: dark, to: URL(fileURLWithPath: dir)
                    .appendingPathComponent("responsive-\(Int(width))-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func render<V: View>(_ view: V, dark: Bool, to url: URL) async throws {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
    }
}
