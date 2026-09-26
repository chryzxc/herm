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
        #expect(DockThemeID.daylight.appearance == .light)
        #expect(DockThemeID.poseidon.appearance == .dark)
        #expect(DockThemeID.allCases.allSatisfy { !$0.detail.isEmpty })
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
}
