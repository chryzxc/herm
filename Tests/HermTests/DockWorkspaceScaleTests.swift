import AppKit
import SwiftUI
import Testing
@testable import Herm

@MainActor
struct DockWorkspaceScaleTests {
    @Test func typographyRolesShareCompactAndWindowSizes() {
        let sizes: [(DockTypography.Role, CGFloat, CGFloat)] = [
            (.body, 12, 12), (.navigation, 13, 13), (.conversation, 14, 14),
            (.metadata, 11, 11), (.code, 12.5, 12.5), (.pageTitle, 16, 16)
        ]
        for (role, compact, window) in sizes {
            #expect(DockTypography.size(role) == compact)
            #expect(DockTypography.size(role, scale: DockWorkspaceScale.window) == window)
        }
        #expect(NativeMarkdownAttributedTextBuilder.bodySize == DockTypography.size(.conversation))
        #expect(NativeMarkdownAttributedTextBuilder.codeSize == DockTypography.size(.code))
    }

    @Test func nativeSizesUseWholePointsAndLeaveCompactModeUnchanged() {
        #expect(DockWorkspaceScale.points(12, scale: 1) == 12)
        #expect(DockWorkspaceScale.points(11.5, scale: 1) == 11.5)
        #expect(DockWorkspaceScale.points(12, scale: DockWorkspaceScale.window) == 12)
        #expect(DockWorkspaceScale.points(14, scale: DockWorkspaceScale.window) == 14)
        #expect(DockWorkspaceScale.points(28, scale: DockWorkspaceScale.window) == 28)
    }

    @Test func visibleSwiftUIButtonsReceiveClicksAcrossDisplaysAndResizes() async throws {
        let recorder = ClickRecorder()
        let workspace = NSHostingView(rootView: DockWindowWorkspace {
            FullscreenPanelSplitView(
                leading: VStack {
                    action("Top left", recorder: recorder)
                    Spacer()
                    action("Bottom left", recorder: recorder)
                }.padding(24),
                trailing: VStack {
                    action("Top right", recorder: recorder)
                    Spacer()
                    action("Bottom right", recorder: recorder)
                }.padding(24),
                minimumLeadingWidth: 220, minimumTrailingWidth: 220
            )
        })
        workspace.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = workspace
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for screen in NSScreen.screens {
            for size in [NSSize(width: 900, height: 600), NSSize(width: 760, height: 480)] {
                window.setContentSize(size)
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                                              y: screen.visibleFrame.midY - size.height / 2))
                for _ in 0..<5 {
                    workspace.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(40))
                }
                #expect(window.backingScaleFactor == screen.backingScaleFactor)
                // Native coordinates must be identical, with no workspace magnification.
                #expect(abs(workspace.bounds.width - workspace.frame.width) < 1)
                #expect(abs(workspace.convertToBacking(workspace.bounds).width - size.width * screen.backingScaleFactor) < 1)
                if let directory = ProcessInfo.processInfo.environment["DOCK_SCALE_SNAPSHOT_DIR"] {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    let bitmap = try #require(workspace.bitmapImageRepForCachingDisplay(in: workspace.bounds))
                    workspace.cacheDisplay(in: workspace.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(screen.localizedName)-\(Int(size.width)).png"))
                }
                for label in ["Top left", "Top right", "Bottom left", "Bottom right"] {
                    let marker = try #require(descendants(workspace).compactMap { $0 as? MarkerView }.first { $0.label == label })
                    #expect(marker.workspaceScale == DockWorkspaceScale.window)
                    let rect = marker.convert(marker.bounds, to: nil)
                    let point = NSPoint(x: rect.midX, y: rect.midY)
                    let before = recorder.labels.count
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                        window.sendEvent(event)
                    }
                    try await Task.sleep(for: .milliseconds(30))
                    #expect(recorder.labels.count == before + 1)
                    #expect(recorder.labels.last == label)
                }
            }
        }
    }

    private func action(_ label: String, recorder: ClickRecorder) -> some View {
        Button { recorder.labels.append(label) } label: {
            Text(label).dockFont(.control).frame(width: 150, height: 44)
        }
        .buttonStyle(.dockSecondary)
        .overlay { Marker(label: label).allowsHitTesting(false) }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private final class ClickRecorder { var labels: [String] = [] }

    private final class MarkerView: NSView {
        var label = ""
        var workspaceScale: CGFloat = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private struct Marker: NSViewRepresentable {
        let label: String
        func makeNSView(context: Context) -> MarkerView { let view = MarkerView(); view.label = label; return view }
        func updateNSView(_ view: MarkerView, context: Context) { view.workspaceScale = context.environment.dockWorkspaceScale }
    }
}
