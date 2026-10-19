import AppKit
import SwiftUI
import Testing
@testable import Herm

@MainActor
struct DockThemeStoreTests {
    @Test func existingNotchAndPreviewFollowSkinChanges() async throws {
        _ = NSApplication.shared
        let store = DockThemeStore.shared
        let savedTheme = store.selectedThemeID
        let savedAppearance = NSApp.appearance
        defer { store.selectedThemeID = savedTheme; NSApp.appearance = savedAppearance }
        for expanded in [false, true] {
            store.selectedThemeID = .retro
            let state = EdgeNotchState()
            state.side = .right
            state.expanded = expanded
            let host = NSHostingView(rootView: EdgeNotchView(state: state, controlCenter: ControlCenterModel(), openDock: {}))
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
                let actual = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 8, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
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

    @Test func topIslandSwapsToIslandSkinAndRestoresOnSide() {
        let suiteName = "DockThemeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = DockThemeStore(defaults: defaults)
        store.selectedThemeID = .retro
        EdgeIslandTheme.apply(side: .top, store: store, defaults: defaults)
        #expect(store.selectedThemeID == .island)
        EdgeIslandTheme.apply(side: .top, store: store, defaults: defaults)
        EdgeIslandTheme.apply(side: .right, store: store, defaults: defaults)
        #expect(store.selectedThemeID == .retro)
        #expect(defaults.string(forKey: EdgeIslandTheme.previousThemeKey) == nil)
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
        let savedTheme = DockThemeRuntime.current, savedRevision = DockThemeRuntime.revision
        defer { DockThemeRuntime.current = savedTheme; DockThemeRuntime.revision = savedRevision }
        func textColor(_ view: NativeMarkdownTextSectionView) -> NSColor? {
            (view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
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
        #expect(DockThemeID.hermOnly == [.glass, .clean, .cartoon, .terminal, .brutalist, .origami, .dusk, .retro, .eInk, .swiss, .clay, .pixel, .notebook, .hud, .island])
        #expect(DockThemeID.hermesClassic.style.fontDesign == .serif && DockThemeID.ares.style.controlRadius < DockThemeID.slate.style.controlRadius)
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
        #expect(DockThemeID.glass.appearance == .system && DockThemeID.brutalist.style.outlineWidth > DockThemeID.cartoon.style.outlineWidth)
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
        for theme in DockThemeID.allCases where ![.retro, .eInk, .swiss, .clay, .pixel, .notebook, .hud].contains(theme) {
            #expect(theme.presentation == DockSkinPresentation())
        }
    }

    @Test func switchingSkinRestylesUnchangedNativeTextAndRestoresDefaults() {
        let savedTheme = DockThemeRuntime.current, savedRevision = DockThemeRuntime.revision
        defer { DockThemeRuntime.current = savedTheme; DockThemeRuntime.revision = savedRevision }
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
        var darkBackground: NSColor?
        var darkAccent: NSColor?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            darkBackground = NSColor(palette.background).usingColorSpace(.sRGB)
            darkAccent = NSColor(palette.accent).usingColorSpace(.sRGB)
        }

        #expect(darkBackground != nil)
        #expect(abs((darkBackground?.alphaComponent ?? 0) - 0.16) < 0.01)
        #expect((darkBackground?.brightnessComponent ?? 1) < 0.15)
        #expect(abs((darkAccent?.blueComponent ?? 0) - (darkAccent?.redComponent ?? 1)) < 0.02)
    }

    @Test func runtimeChangesBeforePublishedThemeValueIsObserved() {
        let suiteName = "DockThemeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let savedTheme = DockThemeRuntime.current, savedRevision = DockThemeRuntime.revision
        defer { DockThemeRuntime.current = savedTheme; DockThemeRuntime.revision = savedRevision }
        let store = DockThemeStore(defaults: defaults, appliesToApplication: true)
        var runtimeSeenBySubscriber: DockThemeID?
        let observation = store.$selectedThemeID.dropFirst().sink { _ in
            runtimeSeenBySubscriber = DockThemeRuntime.current
        }

        store.selectedThemeID = .warmLight

        #expect(runtimeSeenBySubscriber == .warmLight)
        _ = observation
    }

    @Test func appearanceCatalogJoinsMappedSkinsAndDeduplicatesUnknowns() {
        let skins = [
            AppearanceSkin(id: "slate", name: "Cool Blue", isActive: true),
            AppearanceSkin(id: "custom", name: "Custom local skin", isActive: false),
            AppearanceSkin(id: "custom", name: "Duplicate custom skin", isActive: false)
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
            #expect(luma <= 0.86, "\(id) primary text too bright")
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
            if DockThemeID.allCases.filter({ $0.title == t.title }).count > 1 { problems.append("\(t): duplicate title") }
            if t.usesNativeMaterial && t.appearance != .system { problems.append("\(t): native material must follow the system appearance") }
            if s.material == .glass && !t.usesNativeMaterial { problems.append("\(t): glass material requires native material") }
            if !(0.85...1).contains(s.pressScale) { problems.append("\(t): pressScale out of range") }
            if s.controlRadius < 0 || s.paneRadius < 0 || s.outlineWidth < 0 { problems.append("\(t): negative geometry") }
        }
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }

    @Test func explicitSpecimenGeometryDoesNotFollowTheActiveSkin() {
        let savedTheme = DockThemeRuntime.current
        defer { DockThemeRuntime.current = savedTheme }
        let rect = CGRect(x: 0, y: 0, width: 120, height: 60)
        for theme in DockThemeID.allCases {
            let shape = DockThemeShape(cornerRadius: theme.style.paneRadius, role: .pane, geometry: theme.style.geometry)
            DockThemeRuntime.current = .notebook
            let lightPath = shape.path(in: rect)
            DockThemeRuntime.current = .terminal
            #expect(lightPath == shape.path(in: rect), "\(theme) specimen changed with the active skin")
            #expect(!lightPath.isEmpty)
            #expect(lightPath.contains(CGPoint(x: 60, y: 30)))
        }
    }
}
