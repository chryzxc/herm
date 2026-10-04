import AppKit
import Testing
@testable import Herm

@MainActor
struct DockThemeStoreTests {
    @Test func defaultsToNativeMacOSAndPersistsSelection() {
        let suiteName = "DockThemeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = DockThemeStore(defaults: defaults)
        #expect(first.selectedThemeID == .nativeMacOS)
        first.selectedThemeID = .poseidon
        #expect(DockThemeStore(defaults: defaults).selectedThemeID == .poseidon)
    }

    @Test func invalidAndLegacyValuesFallBackSafely() {
        let suiteName = "DockThemeStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("hermesEditorial", forKey: DockThemeStore.legacyStorageKey)
        defaults.set("unknown", forKey: DockThemeStore.storageKey)
        let store = DockThemeStore(defaults: defaults)
        #expect(store.selectedThemeID == .nativeMacOS)
        #expect(defaults.string(forKey: DockThemeStore.legacyStorageKey) == nil)
    }

    @Test func nativeMarkdownRecolorsUnchangedTextWhenThemeChanges() {
        let savedTheme = DockThemeRuntime.current, savedRevision = DockThemeRuntime.revision
        defer { DockThemeRuntime.current = savedTheme; DockThemeRuntime.revision = savedRevision }
        func textColor(_ view: NativeMarkdownTextSectionView) -> NSColor? {
            (view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        }
        let view = NativeMarkdownTextSectionView()
        DockThemeRuntime.current = .daylight
        DockThemeRuntime.revision &+= 1
        view.update(markdown: "Plain **bold** reply", kind: .prose)
        let light = textColor(view)

        DockThemeRuntime.current = .poseidon
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
        DockThemeStore(defaults: defaults).selectedThemeID = .charizard
        #expect(DockThemeRuntime.revision == revision)
    }

    @Test func registryMapsHermesSkinIDsAndAppearance() {
        #expect(DockThemeID.hermesClassic.hermesSkinID == "default")
        #expect(DockThemeID.warmLight.hermesSkinID == "warm-lightmode")
        #expect(DockThemeID.nativeMacOS.appearance == .system)
        #expect(DockThemeID.nativeMacOS.usesNativeMaterial)
        #expect(!DockThemeID.poseidon.usesNativeMaterial)
        #expect(DockThemeID.daylight.appearance == .light)
        #expect(DockThemeID.poseidon.appearance == .dark)
        #expect(DockThemeID.allCases.allSatisfy { !$0.detail.isEmpty })
        #expect(DockThemeID.hermOnly == [.nativeMacOS, .cartoon, .terminal, .flat, .brutalist, .origami])
        #expect(DockThemeID.terminal.appearance == .dark && DockThemeID.terminal.style.fontDesign == .monospaced)
        #expect(DockThemeID.flat.appearance == .system && DockThemeID.brutalist.style.outlineWidth > DockThemeID.cartoon.style.outlineWidth)
        #expect(DockThemeID.cartoon.appearance == .light)
        #expect(DockThemeID.cartoon.style.stickerShadow > 0 && DockThemeID.cartoon.style.fontDesign == .rounded)
        #expect(DockThemeID.origami.appearance == .light && DockThemeID.origami.style.geometry == .folded)
        #expect(DockThemeID.origami.style.outlineWidth == 1 && DockThemeID.origami.style.pressScale == 0.98)
        #expect(DockThemeID.poseidon.style == DockThemeStyle())
    }

    @Test func nativePaletteUsesMacOSSemanticHuesAndTranslucentSurfaces() {
        let palette = DockThemePalette(theme: .nativeMacOS)
        var darkBackground: NSColor?
        var darkAccent: NSColor?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            darkBackground = NSColor(palette.background).usingColorSpace(.sRGB)
            darkAccent = NSColor(palette.accent).usingColorSpace(.sRGB)
        }

        #expect(darkBackground != nil)
        #expect(abs((darkBackground?.alphaComponent ?? 0) - 0.16) < 0.01)
        #expect((darkBackground?.brightnessComponent ?? 1) < 0.15)
        #expect((darkAccent?.blueComponent ?? 0) > 0.9)
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
            AppearanceSkin(id: "poseidon", name: "Poseidon", isActive: true),
            AppearanceSkin(id: "custom", name: "Custom local skin", isActive: false),
            AppearanceSkin(id: "custom", name: "Duplicate custom skin", isActive: false)
        ]
        let options = DockAppearanceCatalog.options(installedSkins: skins)
        #expect(options.count == DockThemeID.allCases.count)
        #expect(options.first(where: { $0.themeID == .poseidon })?.isHermesActive == true)
        #expect(options.first(where: { $0.themeID == .nativeMacOS })?.isHermesInstalled == false)
        #expect(DockAppearanceCatalog.installedOptions(installedSkins: skins).map(\.themeID) == [.poseidon])
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
}
