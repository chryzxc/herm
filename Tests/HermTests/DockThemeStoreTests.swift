import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct DockThemeStoreTests {
    @Test func themeRootKeepsSettingsSelectionWhileUpdatingColorScheme() async throws {
        _ = NSApplication.shared
        let store = DockThemeStore.shared
        let savedTheme = store.selectedThemeID
        let savedAppearance = NSApp.appearance
        defer {
            store.selectedThemeID = savedTheme
            NSApp.appearance = savedAppearance
        }

        for systemScheme in [ColorScheme.light, .dark] {
            store.selectedThemeID = .clean
            var selection: Binding<SettingsCategory>?
            var renderedCategory: SettingsCategory?
            var renderedScheme: ColorScheme?
            let host = NSHostingView(
                rootView: ThemeRootSelectionProbe { category, scheme in
                    selection = category
                    renderedCategory = category.wrappedValue
                    renderedScheme = scheme
                }.dockThemedRoot().environment(\.colorScheme, systemScheme))
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            #expect(renderedCategory == .general)
            let category = try #require(selection)
            category.wrappedValue = .appearance
            try await Task.sleep(for: .milliseconds(100))
            #expect(renderedCategory == .appearance)

            for theme in [DockThemeID.warmLight, .slate, .glass, .cartoon, .terminal, .clean] {
                store.selectedThemeID = theme
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                #expect(renderedCategory == .appearance, "Settings selection reset for \(theme)")
                let expectedScheme: ColorScheme =
                    switch theme.appearance {
                    case .light: .light
                    case .dark: .dark
                    case .system: systemScheme
                    }
                #expect(renderedScheme == expectedScheme, "Wrong color scheme for \(theme)")
            }
        }
    }

    @Test func existingHermFacesFollowSkinChanges() async throws {
        _ = NSApplication.shared
        let store = DockThemeStore.shared
        let savedTheme = store.selectedThemeID
        let savedAppearance = NSApp.appearance
        defer {
            store.selectedThemeID = savedTheme
            NSApp.appearance = savedAppearance
        }
        store.selectedThemeID = .clean
        let bot = BotSummary(
            id: "nexus", name: "Nexus", title: nil, description: nil, model: nil,
            isActive: false, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
            isHidden: false, hasAvatar: true, isDefault: true)
        let tiff = try #require(
            BotFaceMark.still(id: bot.id, theme: .glass, originalColors: true).nsImage?.tiffRepresentation)
        let savedFace = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let faces = [
            AnyView(BotFaceMark(id: "nexus", size: 80)),
            AnyView(DockBotOrbitCanvas(id: "nexus", image: nil, size: 80, mood: .idle, pose: .rest)),
            AnyView(BotAvatarView(bot: bot, imageData: savedFace, size: 80, animated: false)),
            AnyView(
                BotAvatarView(bot: bot, imageData: savedFace, size: 80, animated: false)
                    .environment(\.dockBotIndicatorFrame, DockBotIndicatorFrame(date: .distantPast, moves: false))),
            AnyView(BotFaceMark(id: "nexus", size: 80, theme: .cartoon)),
        ]
        let hosts = faces.map { NSHostingView(rootView: $0.frame(width: 120, height: 120)) }
        let windows = hosts.map { host in
            host.frame = NSRect(x: 0, y: 0, width: 120, height: 120)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            return window
        }
        defer { for window in windows { window.close() } }
        var baseline: [Data] = []
        for theme in [DockThemeID.clean, .mono, .terminal, .cartoon, .clean] {
            store.selectedThemeID = theme
            for window in windows { window.appearance = NSAppearance(named: .aqua) }
            try await Task.sleep(for: .milliseconds(150))
            let images = try hosts.map { host in
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                return try #require(bitmap.representation(using: .png, properties: [:]))
            }
            if baseline.isEmpty { baseline = images }
            for index in 0..<4 {
                #expect((images[index] == baseline[index]) == (theme == .clean), "Face \(index), skin \(theme)")
            }
            #expect(images[4] == baseline[4], "Explicit gallery skin must stay fixed")
        }
    }

    @Test func existingNotchAndPreviewFollowSkinChanges() async throws {
        _ = NSApplication.shared
        let store = DockThemeStore.shared
        let savedTheme = store.selectedThemeID
        let savedAppearance = NSApp.appearance
        defer {
            store.selectedThemeID = savedTheme
            NSApp.appearance = savedAppearance
        }
        for expanded in [false, true] {
            store.selectedThemeID = .retro
            let state = EdgeNotchState()
            state.side = .right
            state.expanded = expanded
            let host = NSHostingView(
                rootView: EdgeNotchView(state: state, controlCenter: ControlCenterModel(), openDock: {}))
            host.frame = NSRect(origin: .zero, size: expanded ? state.openSize : state.collapsedSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.close() }
            for theme in [DockThemeID.retro, .terminal, .retro, .clean] {
                store.selectedThemeID = theme
                if theme == .clean {
                    #expect(window.appearance == nil)
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                }
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let actual = try #require(
                    bitmap.colorAt(x: bitmap.pixelsWide - 8, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
                var expectedColor: NSColor?
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    expectedColor = NSColor(DockThemePalette(theme: theme).background).usingColorSpace(.sRGB)
                }
                let expected = try #require(expectedColor)
                // The narrow rail also carries the skin's accent glow.
                #expect(abs(actual.redComponent - expected.redComponent) < 0.08, "\(theme), expanded: \(expanded)")
                #expect(abs(actual.greenComponent - expected.greenComponent) < 0.08)
                #expect(abs(actual.blueComponent - expected.blueComponent) < 0.08)
                if theme == .clean { NSApp.appearance = nil }
            }
        }
    }

    @Test func defaultsToGlassAndPersistsSelection() {
        let suiteName = "DockThemeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = DockThemeStore(defaults: defaults)
        #expect(first.selectedThemeID == .glass)
        first.selectedThemeID = .retro
        #expect(DockThemeStore(defaults: defaults).selectedThemeID == .retro)
    }

    @Test func notchAppearanceResolvesBlackWhateverTheSkin() {
        for theme in [DockThemeID.clean, .glass, .island, .retro] {
            var resolved: NSColor?
            DockThemeStore.notchAppearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(DockThemePalette(theme: theme).background).usingColorSpace(.sRGB)
            }
            #expect((resolved?.redComponent ?? 1) < 0.01 && (resolved?.blueComponent ?? 1) < 0.01, "\(theme)")
        }
    }

    @Test func invalidAndLegacyValuesFallBackSafely() {
        let suiteName = "DockThemeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("hermesEditorial", forKey: DockThemeStore.legacyStorageKey)
        defaults.set("unknown", forKey: DockThemeStore.storageKey)
        let store = DockThemeStore(defaults: defaults)
        #expect(store.selectedThemeID == .glass)
        #expect(defaults.string(forKey: DockThemeStore.legacyStorageKey) == nil)
    }

    @Test func nativeMarkdownRecolorsUnchangedTextWhenThemeChanges() {
        let savedTheme = DockThemeRuntime.current
        let savedRevision = DockThemeRuntime.revision
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision = savedRevision
        }
        func textColor(_ view: NativeMarkdownTextSectionView) -> NSColor? {
            (view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(
                .sRGB)
        }
        let view = NativeMarkdownTextSectionView()
        DockThemeRuntime.current = .warmLight
        DockThemeRuntime.revision &+= 1
        view.update(markdown: "Plain **bold** reply", kind: .prose)
        let light = textColor(view)

        DockThemeRuntime.current = .slate
        DockThemeRuntime.revision &+= 1
        view.update(markdown: "Plain **bold** reply", kind: .prose)
        let dark = textColor(view)

        #expect(light != nil && dark != nil)
        #expect(light != dark)
        #expect((dark?.brightnessComponent ?? 0) > 0.8)
    }

    @Test func isolatedStoresDoNotChangeTheApplicationTheme() {
        let suiteName = "DockThemeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let revision = DockThemeRuntime.revision
        DockThemeStore(defaults: defaults).selectedThemeID = .ares
        #expect(DockThemeRuntime.revision == revision)
    }

    @Test func registryMapsHermesSkinIDsAndAppearance() {
        #expect(DockThemeID.hermesClassic.hermesSkinID == "default")
        #expect(DockThemeID.warmLight.hermesSkinID == "warm-lightmode")
        #expect(DockThemeID(rawValue: "nativeMacOS") == nil)
        #expect(!DockThemeID.slate.usesNativeMaterial)
        #expect(DockThemeID.warmLight.appearance == .light)
        #expect(DockThemeID.slate.appearance == .dark)
        #expect(DockThemeID.allCases.allSatisfy { !$0.detail.isEmpty })
        #expect(
            DockThemeID.hermOnly == [
                .glass, .clean, .cartoon, .terminal, .brutalist, .origami, .dusk, .retro, .eInk, .swiss, .clay, .pixel,
                .notebook, .hud, .storm, .island,
            ])
        #expect(
            DockThemeID.hermesClassic.style.motion == .snap && DockThemeID.cartoon.style.motion == .bouncy
                && DockThemeID.glass.style.motion == .float && DockThemeID.hud.style.motion == .mechanical)
        #expect(DockThemeID.notebook.style.motion == .glide)
        #expect(
            DockThemeID.storm.appearance == .dark && DockThemeID.storm.style.backdrop == .rain
                && DockThemeID.storm.style.glow == 0)
        #expect(
            DockThemeID.storm.style.selection == .bar && DockThemePalette(theme: .storm).neonHues.isEmpty
                && DockThemePalette(theme: .dusk).neonHues.isEmpty)
        #expect(
            DockThemeID.hermesClassic.appearance == .system && DockThemeID.hermesClassic.style.backdrop == .etching
                && DockThemeID.ares.style.controlRadius < DockThemeID.slate.style.controlRadius)
        #expect(DockThemeID.terminal.style.glow > 0 && DockThemeID.terminal.style.selection == .invert)
        #expect(DockThemeID.dusk.style.accentGradient && DockThemeID.warmLight.style.cardShadow > 0)
        #expect(DockThemeID.pixel.style.geometry == .pixel && !DockThemeID.pixel.style.animates)
        #expect(DockThemeID.notebook.style.geometry == .sketch && DockThemeID.notebook.style.backdrop == .ruled)
        #expect(DockThemeID.hud.style.geometry == .chamfered && DockThemeID.hud.style.selection == .bar)
        #expect(DockThemeID.clay.style.emboss > 0 && DockThemeID.clay.style.outlineWidth == 0)
        #expect(["sisyphus", "charizard", "daylight", "poseidon"].allSatisfy { DockThemeID(rawValue: $0) == nil })
        #expect(DockThemeID.glass.style.material == .glass && DockThemeID.glass.usesNativeMaterial)
        #expect(DockThemeID.eInk.style.selection == .invert && !DockThemeID.eInk.style.animates)
        #expect(DockThemeID.swiss.style.chrome == .open && DockThemeID.swiss.presentation.composer == .line)
        #expect(DockThemeID.terminal.appearance == .dark && DockThemeID.terminal.style.fontDesign == .monospaced)
        #expect(
            DockThemeID.glass.appearance == .system
                && DockThemeID.brutalist.style.outlineWidth > DockThemeID.cartoon.style.outlineWidth)
        #expect(DockThemeID.cartoon.appearance == .light)
        #expect(DockThemeID.cartoon.style.stickerShadow > 0 && DockThemeID.cartoon.style.fontDesign == .rounded)
        #expect(DockThemeID.origami.appearance == .light && DockThemeID.origami.style.geometry == .folded)
        #expect(DockThemeID.origami.style.outlineWidth == 1 && DockThemeID.origami.style.pressScale == 0.98)
        #expect(DockThemeID.slate.style.backdrop == .grid)
    }

    @Test func retroIsAvailableWithoutHermesSkins() {
        let option = DockAppearanceCatalog.options(installedSkins: []).first { $0.themeID == .retro }
        #expect(option != nil && option?.isHermesInstalled == false)
        #expect(DockThemeID.retro.appearance == .light && DockThemeID.retro.style.bevel)
        for theme in DockThemeID.allCases
        where ![.retro, .eInk, .swiss, .clay, .pixel, .notebook, .hud, .storm].contains(theme) {
            #expect(theme.presentation == DockSkinPresentation())
        }
    }

    @Test func switchingSkinRestylesUnchangedNativeTextAndRestoresDefaults() {
        let savedTheme = DockThemeRuntime.current
        let savedRevision = DockThemeRuntime.revision
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision = savedRevision
        }
        let view = NativeMarkdownTextSectionView()
        func apply(_ theme: DockThemeID) -> NSFont? {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            view.update(markdown: "Unchanged **response**", kind: .prose)
            return view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        }
        let originalFont = apply(.clean)
        #expect(apply(.terminal)?.isFixedPitch == true)
        let desktopFont = apply(.eInk)
        #expect(desktopFont == originalFont)
        #expect(desktopFont?.isFixedPitch == false)
        #expect(DockSkinPresentation.current.composerShadow == 0)
        #expect(DockSkinPresentation.current.composerRadius == 0)
        #expect(apply(.clean) == originalFont)
        #expect(DockSkinPresentation.current == DockSkinPresentation())
    }

    @Test func glassPaletteIsNeutralAndTranslucent() {
        let palette = DockThemePalette(theme: .glass)
        var darkWindow: NSColor?
        var darkBackground: NSColor?
        var darkAccent: NSColor?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            darkWindow = NSColor(palette.windowBackground).usingColorSpace(.sRGB)
            darkBackground = NSColor(palette.background).usingColorSpace(.sRGB)
            darkAccent = NSColor(palette.accent).usingColorSpace(.sRGB)
        }

        // The window tint is the only layer; page canvases and the sidebar stay clear.
        #expect(abs((darkWindow?.alphaComponent ?? 0) - 0.12) < 0.01)
        #expect((darkWindow?.brightnessComponent ?? 1) < 0.15)
        #expect(darkBackground?.alphaComponent == 0)
        #expect(palette.sidebarBackground == palette.background)
        #expect(abs((darkAccent?.blueComponent ?? 0) - (darkAccent?.redComponent ?? 1)) < 0.02)
    }

    @Test func runtimeChangesBeforePublishedThemeValueIsObserved() {
        let suiteName = "DockThemeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let savedTheme = DockThemeRuntime.current
        let savedRevision = DockThemeRuntime.revision
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision = savedRevision
        }
        let store = DockThemeStore(defaults: defaults, appliesToApplication: true)
        var runtimeSeenBySubscriber: DockThemeID?
        let observation = store.$selectedThemeID.dropFirst().sink { _ in
            runtimeSeenBySubscriber = DockThemeRuntime.current
        }

        store.selectedThemeID = .warmLight

        #expect(runtimeSeenBySubscriber == .warmLight)
        _ = observation
    }

    @Test func readingThemeTokenTracksSkinSwitch() {
        let suiteName = "DockThemeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let savedTheme = DockThemeRuntime.current
        let savedRevision = DockThemeRuntime.revision
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision = savedRevision
        }
        let store = DockThemeStore(defaults: defaults, appliesToApplication: true)
        store.selectedThemeID = .clean
        final class Flag: @unchecked Sendable { var isSet = false }
        let invalidated = Flag()
        // SwiftUI tracks view bodies the same way, so a view that only reads a
        // token (and whose inputs are unchanged) still re-renders.
        withObservationTracking {
            _ = Color.dockSurface
        } onChange: {
            invalidated.isSet = true
        }

        store.selectedThemeID = .terminal

        #expect(invalidated.isSet)
    }

    @Test func appearanceCatalogJoinsMappedSkinsAndDeduplicatesUnknowns() {
        let skins = [
            AppearanceSkin(id: "slate", name: "Cool Blue", isActive: true),
            AppearanceSkin(id: "custom", name: "Custom local skin", isActive: false),
            AppearanceSkin(id: "custom", name: "Duplicate custom skin", isActive: false),
        ]
        let options = DockAppearanceCatalog.options(installedSkins: skins)
        #expect(options.count == DockThemeID.allCases.count)
        #expect(options.first(where: { $0.themeID == .slate })?.isHermesActive == true)
        #expect(options.first(where: { $0.themeID == .glass })?.isHermesInstalled == false)
        #expect(DockAppearanceCatalog.installedOptions(installedSkins: skins).map(\.themeID) == [.slate])
        #expect(DockAppearanceCatalog.unknownSkins(skins).map(\.id) == ["custom"])
    }

    /// Eye-strain guard: no theme's dark-appearance primary text may approach pure white.
    @Test func darkPrimaryTextStaysSoft() {
        for id in DockThemeID.allCases where id.appearance != .light {
            var rgb: NSColor?
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                rgb = NSColor(DockThemePalette(theme: id).primaryText).usingColorSpace(.sRGB)
            }
            let c = rgb!
            let luma = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            // Clean follows the approved reference's #E4E4E4 soft white; other skins retain their ceiling.
            #expect(luma <= (id == .clean ? 0.90 : 0.86), "\(id) primary text too bright")
        }
    }

    /// Rules every theme must satisfy. Adding a `DockThemeID` case is covered
    /// automatically; a failure here names the theme and the broken rule.
    @Test func everyThemeSatisfiesTheThemeStandard() {
        var problems: [String] = []
        for t in DockThemeID.allCases {
            let s = t.style
            if t.title.isEmpty || t.detail.isEmpty { problems.append("\(t): missing title/detail") }
            if t.signature.isEmpty { problems.append("\(t): missing material signature") }
            if DockThemeID.allCases.filter({ $0.title == t.title }).count > 1 {
                problems.append("\(t): duplicate title")
            }
            if t.usesNativeMaterial && t.appearance != .system {
                problems.append("\(t): native material must follow the system appearance")
            }
            if s.material == .glass && !t.usesNativeMaterial {
                problems.append("\(t): glass material requires native material")
            }
            if !(0.85...1).contains(s.pressScale) { problems.append("\(t): pressScale out of range") }
            if s.controlRadius < 0 || s.paneRadius < 0 || s.outlineWidth < 0 {
                problems.append("\(t): negative geometry")
            }
        }
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test func explicitSpecimenGeometryDoesNotFollowTheActiveSkin() {
        let savedTheme = DockThemeRuntime.current
        defer { DockThemeRuntime.current = savedTheme }
        let rect = CGRect(x: 0, y: 0, width: 120, height: 60)
        for theme in DockThemeID.allCases {
            let shape = DockThemeShape(
                cornerRadius: theme.style.paneRadius, role: .pane, geometry: theme.style.geometry)
            DockThemeRuntime.current = .notebook
            let lightPath = shape.path(in: rect)
            DockThemeRuntime.current = .terminal
            #expect(lightPath == shape.path(in: rect), "\(theme) specimen changed with the active skin")
            #expect(!lightPath.isEmpty)
            #expect(lightPath.contains(CGPoint(x: 60, y: 30)))
        }
    }
}

private struct ThemeRootSelectionProbe: View {
    @State private var category = SettingsCategory.general
    let observe: (Binding<SettingsCategory>, ColorScheme) -> Void

    var body: some View {
        ThemeRootSelectionBridge(category: $category, observe: observe)
    }
}

private struct ThemeRootSelectionBridge: NSViewRepresentable {
    @Binding var category: SettingsCategory
    @Environment(\.colorScheme) private var colorScheme
    let observe: (Binding<SettingsCategory>, ColorScheme) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        observe($category, colorScheme)
    }
}
