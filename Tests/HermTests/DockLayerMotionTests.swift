import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct DockLayerMotionTests {
    @Test func capsuleHighlightFollowsThePerimeterAndResizesWithoutDuplicatingLayers() throws {
        let view = DockLayerMotionView(frame: NSRect(x: 0, y: 0, width: 150, height: 34))
        view.spec = .init(
            kind: .capsuleRim(period: 2.4, lineWidth: 1), color: NSColor.white.cgColor, paused: false)
        let highlight = try #require(view.layer?.sublayers?.last as? CAShapeLayer)
        let animation = try #require(highlight.animation(forKey: "lineDashPhase") as? CABasicAnimation)
        let perimeter = 2 * (149.0 - 33.0) + Double.pi * 33
        #expect(abs((animation.toValue as? Double ?? 0) + perimeter) < 0.001)
        #expect(animation.duration == 2.4)
        #expect(highlight.path?.boundingBoxOfPath == view.bounds.insetBy(dx: 0.5, dy: 0.5))
        #expect(view.hitTest(.zero) == nil)

        view.setFrameSize(NSSize(width: 34, height: 34))
        view.layout()
        #expect(view.layer?.sublayers?.count == 2)
        let resized = try #require(view.layer?.sublayers?.last as? CAShapeLayer)
        #expect(resized.path?.boundingBoxOfPath == view.bounds.insetBy(dx: 0.5, dy: 0.5))
    }

    @Test func pausingEveryLoopKeepsItsArtworkAndRemovesAnimations() throws {
        let kinds: [DockLayerMotion.Kind] = [
            .spin(period: 1.6, lineWidth: 1.5), .capsuleRim(period: 2.4, lineWidth: 1),
            .breathe(period: 2), .sweep(period: 1.6, fraction: 0.4, clamp: 0...80),
            .tide(period: 2, depth: 4),
        ]
        for kind in kinds {
            let view = DockLayerMotionView(frame: NSRect(x: 0, y: 0, width: 100, height: 34))
            view.spec = .init(kind: kind, color: NSColor.white.cgColor, paused: false)
            let layer = try #require(view.layer)
            #expect(animationCount(layer) > 0)
            view.spec?.paused = true
            #expect(animationCount(layer) == 0)
            #expect(layer.sublayers?.isEmpty == false)
            view.spec?.paused = false
            #expect(animationCount(layer) > 0)
            DockLayerMotion.dismantleNSView(view, coordinator: ())
            #expect(animationCount(layer) == 0)
        }
    }

    @Test func layerLoopsRespectThemeAndHostVisibility() async throws {
        let previous = DockThemeRuntime.current
        defer { DockThemeRuntime.current = previous }
        for (theme, visible) in [
            (DockThemeID.glass, true), (.glass, false), (.eInk, true),
        ] {
            DockThemeRuntime.current = theme
            let host = NSHostingView(
                rootView: DockLayerMotion(kind: .spin(period: 1.6, lineWidth: 1.5), color: .dockAccent)
                    .environment(\.dockHostVisible, visible)
                    .frame(width: 24, height: 24))
            host.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            let view = try #require(motionView(in: host))
            #expect(
                view.spec?.paused
                    == (!visible
                        || !DockMotion.isEnabled(
                            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, theme: theme))
            )
        }
    }

    @Test func pendingActionRetainsItsFootprint() {
        let sizes = [false, true].map { pending in
            NSHostingView(
                rootView: DockActionLabel(title: "Refresh", pendingTitle: "Refreshing…", isPending: pending)
                    .fixedSize()
            ).fittingSize
        }
        #expect(sizes[0] == sizes[1])
    }

    @Test func renderLatestControlsAcrossAppearances() async throws {
        let previous = DockThemeRuntime.current
        defer { DockThemeRuntime.current = previous }
        let directory = URL(fileURLWithPath: "/tmp/herm-motion-preview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (theme, dark) in [
            (DockThemeID.glass, false), (.glass, true), (.mono, true), (.eInk, false),
        ] {
            DockThemeRuntime.current = theme
            let unread = ConversationScrollPresentationState()
            unread.isAtBottom = false
            unread.unseenMessageCount = 1
            let scrolled = ConversationScrollPresentationState()
            scrolled.isAtBottom = false
            let root = VStack(spacing: 16) {
                ConversationLatestMessageControl(presentation: unread, isWorking: true) {}
                ConversationLatestMessageControl(presentation: scrolled, isWorking: true) {}
                ConversationLatestMessageControl(presentation: unread) {}
                DockProgressBar(fraction: 0.6).frame(width: 180)
                DockActionLabel(title: "Refresh", pendingTitle: "Refreshing…", isPending: true)
            }
            .frame(width: 320, height: 260)
            .background(Color.dockOpaqueCanvas)
            .environment(\.colorScheme, dark ? .dark : .light)
            .dockThemedRoot()
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 260)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("\(theme.rawValue)-\(dark).png"))
        }
    }

    private func animationCount(_ layer: CALayer) -> Int {
        (layer.animationKeys()?.count ?? 0) + (layer.sublayers ?? []).reduce(0) { $0 + animationCount($1) }
    }

    private func motionView(in view: NSView) -> DockLayerMotionView? {
        if let motion = view as? DockLayerMotionView { return motion }
        return view.subviews.lazy.compactMap { motionView(in: $0) }.first
    }
}
