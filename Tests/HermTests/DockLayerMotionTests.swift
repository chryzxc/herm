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

    @Test func thinkingRelayStaysInsideItsOriginalFootprint() throws {
        let view = DockLayerMotionView(frame: NSRect(x: 0, y: 0, width: 26, height: 6))
        view.spec = .init(kind: .thinkingRelay, color: NSColor.white.cgColor, paused: false)
        let bead = try #require(view.layer?.sublayers?.last)
        let pass = try #require(bead.animation(forKey: "relay") as? CAKeyframeAnimation)
        let paths = try #require(pass.values as? [CGPath])
        try #require(paths.count == 6)
        #expect(pass.keyTimes?.count == paths.count)
        #expect(paths.allSatisfy { view.bounds.contains($0.boundingBoxOfPath) })
        #expect(paths[1].boundingBoxOfPath.width > paths[0].boundingBoxOfPath.width)
    }

    @Test func pausingEveryLoopKeepsItsArtworkAndRemovesAnimations() throws {
        let kinds: [DockLayerMotion.Kind] = [
            .thinkingRelay, .compactLines, .loading, .startupLogo,
            .capsuleRim(period: 2.4, lineWidth: 1),
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

    @Test func loadingMosaicLiftsFourTilesInSequenceWithinTheCompactSlot() throws {
        let view = DockLayerMotionView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let color = NSColor.systemPurple.cgColor
        view.spec = .init(kind: .loading, color: color, paused: false)
        let tiles = try #require(view.layer?.sublayers)
        try #require(tiles.count == 4)
        var phases: [Double] = []
        for tile in tiles {
            #expect(tile.backgroundColor == color)
            let lift = try #require(tile.animation(forKey: "position.y") as? CAKeyframeAnimation)
            let highlight = try #require(tile.animation(forKey: "opacity"))
            #expect(highlight.timeOffset == lift.timeOffset)
            phases.append(lift.timeOffset / lift.duration)
            let heights = try #require(lift.values as? [CGFloat])
            for height in heights {
                #expect(view.bounds.contains(tile.frame.offsetBy(dx: 0, dy: height - tile.position.y)))
            }
        }
        for (phase, expected) in zip(phases, [0, 0.75, 0.5, 0.25]) {
            #expect(abs(phase - expected) < 0.0001)
        }
    }

    @Test func layerLoopsRespectThemeAndHostVisibility() async throws {
        let previous = DockThemeRuntime.current
        defer { DockThemeRuntime.current = previous }
        for (theme, visible, resizing) in [
            (DockThemeID.glass, true, false), (.glass, false, false), (.glass, true, true), (.eInk, true, false),
        ] {
            DockThemeRuntime.current = theme
            let host = NSHostingView(
                rootView: DockLoadingIndicator(size: 24)
                    .environment(\.dockHostVisible, visible)
                    .environment(\.dockHostResizing, resizing)
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
                    == (!visible || resizing
                        || !DockMotion.isEnabled(
                            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, theme: theme))
            )
        }
    }

    @Test func chatsRailMosaicRespondsToHostVisibility() async throws {
        let previous = DockThemeRuntime.current
        DockThemeRuntime.current = .glass
        defer { DockThemeRuntime.current = previous }
        let model = DockModel(defaults: UserDefaults(suiteName: "ChatRailMotion.\(UUID())")!)
        model.isHermesConnected = true
        model.status = .working
        let button = ChatRailButton(
            model: model, control: ControlCenterModel(),
            store: WorkspaceStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            isSelected: false, style: DockThemePalette(theme: .glass), action: {})
        func root(visible: Bool) -> some View {
            button.environment(\.dockHostVisible, visible)
                .environment(\.dockChromeThemeOverride, .glass)
                .frame(width: 52, height: 52)
        }
        let host = NSHostingView(rootView: root(visible: true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 52, height: 52), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for visible in [true, false, true] {
            host.rootView = root(visible: visible)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            let mark = try #require(motionView(in: host))
            let tiles = try #require(mark.layer?.sublayers)
            #expect(tiles.count == 4)
            let shouldAnimate = visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            #expect(tiles.allSatisfy { ($0.animation(forKey: "position.y") != nil) == shouldAnimate })
        }
    }

    @Test func loadingIndicatorUsesTheSurfaceThemeOverride() async throws {
        let previous = DockThemeRuntime.current
        DockThemeRuntime.current = .glass
        defer { DockThemeRuntime.current = previous }
        let host = NSHostingView(
            rootView: DockLoadingIndicator(size: 16)
                .environment(\.dockChromeThemeOverride, .eInk)
                .environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))

        let spec = try #require(motionView(in: host)?.spec)
        let ink = try #require(NSColor(cgColor: spec.color)?.usingColorSpace(.sRGB))
        #expect(spec.paused)
        #expect(ink.redComponent == 0 && ink.greenComponent == 0 && ink.blueComponent == 0)
    }

    @Test func liveActivitySweepKeepsAnimatingAcrossScrollChanges() async throws {
        let previous = DockThemeRuntime.current
        DockThemeRuntime.current = .glass
        defer { DockThemeRuntime.current = previous }
        let host = NSHostingView(
            rootView: ScrollView {
                DockLiveActivityDecoration {
                    Color.clear.frame(width: 180, height: 150)
                }
                Color.clear.frame(height: 160)
            }
            .environment(\.dockHostVisible, true))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 180)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(motionView(in: host) == nil)
            return
        }
        let motion = try #require(motionView(in: host))
        let scroll = try #require(motion.enclosingScrollView)
        let band = try #require(motion.layer?.sublayers?.first)
        #expect(motion.bounds.height == 1)
        #expect(band.animation(forKey: "position.x") != nil)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 28))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.minY == 28)
        #expect(motion.layer?.sublayers?.first === band)
        #expect(band.animation(forKey: "position.x") != nil)
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
