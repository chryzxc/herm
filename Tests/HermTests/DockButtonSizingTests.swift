import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct DockButtonSizingTests {
    @Test func prioritiesPendingAndDisabledStatesShareRenderedHeight() {
        for size in DockButtonSize.allCases {
            for scale: CGFloat in [1, 1.25] {
                for disabled in [false, true] {
                    for pending in [false, true] {
                        let heights = (0..<4).map { style in
                            let host = NSHostingView(
                                rootView: action(style, pending: pending)
                                    .dockButtonSize(size)
                                    .environment(\.dockWorkspaceScale, scale)
                                    .disabled(disabled)
                                    .fixedSize())
                            return host.fittingSize.height
                        }
                        let expected = DockWorkspaceScale.points(size.height, scale: scale)
                        for height in heights { #expect(abs(height - expected) <= 1) }
                        #expect((heights.max() ?? 0) - (heights.min() ?? 0) <= 1)
                    }
                }
            }
        }
    }

    @Test func nativeControlSizeCannotChangeOnlyOneActionsHeight() {
        for native in [ControlSize.mini, .small, .regular, .large] {
            let host = NSHostingView(rootView: action(0).controlSize(native).fixedSize())
            #expect(abs(host.fittingSize.height - DockControlMetrics.compactHeight) <= 1)
        }
    }

    @Test func modalFooterAndApprovalContainerSupplySizeToEveryStyle() {
        let host = NSHostingView(
            rootView:
                HStack {
                    action(0)
                    action(1)
                    action(2)
                    action(3)
                }.dockButtonSize(.standard).fixedSize())
        #expect(abs(host.fittingSize.height - DockControlMetrics.standardHeight) <= 1)
        let approvals = NSHostingView(
            rootView:
                HStack {
                    action(0)
                    action(1)
                }.dockButtonSize(.accessible).fixedSize())
        #expect(abs(approvals.fittingSize.height - DockControlMetrics.hitTarget) <= 1)
    }

    @Test func renderButtonSizeReference() throws {
        let previous = DockThemeRuntime.current
        defer { DockThemeRuntime.current = previous }
        let directory = URL(fileURLWithPath: "/tmp/herm-button-sizing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (theme, dark): (DockThemeID, Bool) in [
            (.clean, false), (.clean, true), (.glass, false), (.glass, true), (.mono, true),
        ] {
            DockThemeRuntime.current = theme
            let root = VStack(alignment: .leading, spacing: 20) {
                Text("Shared action sizes").dockFont(.pageTitle)
                ForEach(Array(DockButtonSize.allCases.enumerated()), id: \.offset) { _, size in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(Int(size.height)) pt").dockFont(.body)
                        HStack(spacing: 8) {
                            action(0)
                            action(1)
                            action(2)
                            action(3)
                        }.dockButtonSize(size)
                        HStack(spacing: 8) {
                            action(0, pending: true)
                            action(1).disabled(true)
                        }.dockButtonSize(size)
                    }
                }
            }
            .padding(20)
            .frame(width: 660, height: 480, alignment: .topLeading)
            .foregroundStyle(Color.dockPrimaryText)
            .background(Color.dockCanvas)
            .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(x: 0, y: 0, width: 660, height: 480)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(theme.rawValue)-\(dark ? "dark" : "light").png"))
        }
    }

    @ViewBuilder private func action(_ style: Int, pending: Bool = false) -> some View {
        let button = Button {
        } label: {
            DockActionLabel(title: "Continue", pendingTitle: "Working…", isPending: pending, tint: .dockPrimaryText)
        }
        switch style {
        case 0: button.buttonStyle(.dockPrimary)
        case 1: button.buttonStyle(.dockSecondary)
        case 2: button.buttonStyle(.dockCompact)
        default: button.buttonStyle(DockModalButtonStyle(isPrimary: false))
        }
    }
}
