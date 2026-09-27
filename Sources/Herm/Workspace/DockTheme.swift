import AppKit
import SwiftUI

enum DockThemeID: String, CaseIterable, Identifiable, Codable {
    case nativeMacOS, hermesClassic, ares, mono, slate, daylight, warmLight, poseidon, sisyphus, charizard
    var id: String { rawValue }
    var hermesSkinID: String? {
        switch self { case .nativeMacOS: nil; case .hermesClassic: "default"; case .ares: "ares"; case .mono: "mono"; case .slate: "slate"; case .daylight: "daylight"; case .warmLight: "warm-lightmode"; case .poseidon: "poseidon"; case .sisyphus: "sisyphus"; case .charizard: "charizard" }
    }
    var title: String {
        switch self { case .nativeMacOS: "Native macOS"; case .hermesClassic: "Classic Hermes"; case .ares: "Ares"; case .mono: "Monochrome"; case .slate: "Cool Blue"; case .daylight: "Daylight"; case .warmLight: "Warm Light"; case .poseidon: "Poseidon"; case .sisyphus: "Sisyphus"; case .charizard: "Volcanic" }
    }
    var detail: String {
        switch self { case .nativeMacOS: "System menu blur with neutral surfaces and macOS accent colors."; case .hermesClassic: "Gold identity accents with calm midnight surfaces."; case .ares: "Crimson actions, bronze labels, and a warm operational tone."; case .mono: "A focused grayscale palette with minimal distraction."; case .slate: "Developer-focused blue surfaces with crisp cool contrast."; case .daylight: "Bright surfaces with dark text and clear blue actions."; case .warmLight: "Warm paper surfaces with brown and gold hierarchy."; case .poseidon: "Deep ocean blue with seafoam highlights."; case .sisyphus: "Austere grayscale built for persistent work."; case .charizard: "Burnt orange controls with ember-colored emphasis." }
    }
    var appearance: DockThemeAppearance { self == .nativeMacOS ? .system : (self == .daylight || self == .warmLight ? .light : .dark) }
    var usesNativeMaterial: Bool { self == .nativeMacOS }
}

enum DockThemeAppearance: Equatable { case system, light, dark }

struct DockAppearanceOption: Identifiable, Equatable {
    let themeID: DockThemeID
    let hermesSkin: AppearanceSkin?

    var id: DockThemeID { themeID }
    var isHermesActive: Bool { hermesSkin?.isActive == true }
    var isHermesInstalled: Bool { hermesSkin != nil }
}

enum DockAppearanceCatalog {
    static func installedOptions(
        installedSkins: [AppearanceSkin]
    ) -> [DockAppearanceOption] {
        var seen = Set<String>()
        return installedSkins.compactMap { skin in
            guard seen.insert(skin.id).inserted,
                  let theme = DockThemeID.allCases.first(where: { $0.hermesSkinID == skin.id }) else {
                return nil
            }
            return DockAppearanceOption(themeID: theme, hermesSkin: skin)
        }
    }

    static func options(
        themes: [DockThemeID] = DockThemeID.allCases,
        installedSkins: [AppearanceSkin]
    ) -> [DockAppearanceOption] {
        let byID = Dictionary(installedSkins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return themes.map { theme in
            DockAppearanceOption(
                themeID: theme,
                hermesSkin: theme.hermesSkinID.flatMap { byID[$0] }
            )
        }
    }

    static func unknownSkins(_ skins: [AppearanceSkin]) -> [AppearanceSkin] {
        let known = Set(DockThemeID.allCases.compactMap(\.hermesSkinID))
        var seen = Set<String>()
        return skins.filter { !known.contains($0.id) && seen.insert($0.id).inserted }
    }
}

struct DockThemePalette {
    let theme: DockThemeID
    var labelFont: Font { .system(size: 13, weight: .regular) }
    var profileFont: Font { .system(size: 13, weight: .medium) }
    var sectionFont: Font { .system(size: 12, weight: .medium) }
    var rowHeight: CGFloat { 44 }
    var cornerRadius: CGFloat { 7 }
    var sectionSpacing: CGFloat { 12 }
    var usesStructuredDividers: Bool { true }
    var showsDestinationIcons: Bool { true }
    /// Semantic hex roles for one appearance of a theme.
    fileprivate typealias Roles = (bg: String, surface: String, surface2: String, surface4: String, primary: String, secondary: String, metadata: String, accent: String, selected: String, divider: String, success: String, warning: String, destructive: String)
    fileprivate static func roles(_ theme: DockThemeID, dark isDark: Bool) -> Roles {
        switch theme {
        case .nativeMacOS: return isDark ? ("#000615", "#2A3247", "#171C2B", "#3A4359", "#F2F4F8", "#A9B0C0", "#7F879A", "#0A84FF", "#1F3D6B", "#3C4459", "#30D158", "#FF9F0A", "#FF453A") : ("#F2F2F7", "#FFFFFF", "#E5E5EA", "#D1D1D6", "#1C1C1E", "#636366", "#8E8E93", "#007AFF", "#D9E9FF", "#8E8E93", "#248A3D", "#C93400", "#D70015")
        case .hermesClassic: return isDark ? ("#1A1A2E", "#211F35", "#171728", "#333355", "#E6DFC7", "#B0AFA8", "#978862", "#E5B23E", "#3A3A55", "#544F67", "#8FBC8F", "#E3C04F", "#FF6B6B") : ("#F7F3E8", "#F1E8D3", "#FBF9F2", "#E9DFC6", "#3E321F", "#76664A", "#948261", "#B8860B", "#E8DCC2", "#D7C9A9", "#2E7D32", "#B45309", "#B4232F")
        case .ares: return isDark ? ("#2A1212", "#321719", "#241010", "#5C221D", "#DDD2BE", "#C2A59B", "#A87370", "#DD4A3A", "#692620", "#6E584B", "#7BC96F", "#C7A96B", "#EF5350") : ("#F8EEE8", "#F1DDD3", "#FCF7F4", "#E8C6B8", "#3B201B", "#795A52", "#966C63", "#DD4A3A", "#F0D1C7", "#DAB2A2", "#4CAF50", "#C7A96B", "#EF5350")
        case .mono, .sisyphus: return isDark ? ("#1F1F1F", "#282828", "#181818", "#464646", "#D6D6D6", "#ADADAD", "#858585", "#AAAAAA", "#505050", "#5E5E5E", "#B5B5B5", "#AAAAAA", "#D0D0D0") : ("#F5F5F5", "#EDEDED", "#FAFAFA", "#E2E2E2", "#202020", "#606060", "#888888", "#555555", "#E0E0E0", "#C7C7C7", "#5F5F5F", "#777777", "#8A8A8A")
        case .slate: return isDark ? ("#151C2F", "#1C2740", "#111827", "#324867", "#C9D1D9", "#AEBBCA", "#7A8494", "#7EB8F6", "#3A5375", "#545E6B", "#63D0A6", "#E6A855", "#F7A072") : ("#EFF4FA", "#E4ECF6", "#F7FAFD", "#D4E1F0", "#17243A", "#536579", "#718095", "#2563C7", "#D3E0F4", "#B7C8DD", "#238B67", "#A86916", "#C94C4C")
        case .daylight: return ("#F8FAFC", "#EEF3FA", "#FBFCFE", "#DBEAFE", "#1E2533", "#475569", "#64748B", "#2563EB", "#D3E0FB", "#CBD5E1", "#15803D", "#B45309", "#B91C1C")
        case .warmLight: return ("#F5F0E8", "#EEE5D5", "#FBF7EF", "#E8DCC8", "#2C1810", "#6E5743", "#8A735A", "#8B4513", "#E8DAD0", "#D2BE9D", "#2E7D32", "#E65100", "#C62828")
        case .poseidon: return isDark ? ("#0F2440", "#162E4E", "#0B1C33", "#254D73", "#D2E2EC", "#A4BDCD", "#6F8CA5", "#5DB8F5", "#2A587F", "#496884", "#6ED7B0", "#5DB8F5", "#D94F4F") : ("#EDF7FC", "#E0F0F8", "#F7FCFF", "#CDE5F2", "#123047", "#476A80", "#66869B", "#267FB9", "#CBE7F5", "#B8D3E1", "#2E8B69", "#B4771D", "#C74747")
        case .charizard: return isDark ? ("#2B160E", "#351B11", "#1E0F09", "#4A1B07", "#E6D9C1", "#C6A47E", "#9A7A5E", "#F29C38", "#5A260D", "#7B593A", "#6BCB77", "#F29C38", "#EF5350") : ("#FFF5E9", "#F8E8D0", "#FFFAF3", "#F5D2A8", "#3A2114", "#765741", "#96704F", "#C75B1D", "#F5D2A8", "#D8B487", "#2E7D32", "#F29C38", "#C62828")
        }
    }
    /// Colors are resolved once per theme. Native macOS colors are dynamic and
    /// resolve against the appearance they draw in, so AppKit text, nested
    /// hosting views, and Office materials never pick up a stale Light/Dark
    /// variant from whatever appearance happened to be current when read.
    private static let tokens: [DockThemeID: Tokens] = Dictionary(uniqueKeysWithValues: DockThemeID.allCases.map { ($0, Tokens(theme: $0)) })
    private var resolvedTokens: Tokens { Self.tokens[theme]! }
    var windowBackground: Color { resolvedTokens.windowBackground }
    var background: Color { resolvedTokens.background }; var surface: Color { resolvedTokens.surface }; var surface2: Color { resolvedTokens.surface2 }; var surface4: Color { resolvedTokens.surface4 }
    var surface6: Color { surface4.opacity(0.86) }; var surface8: Color { surface4.opacity(0.72) }
    var primaryText: Color { resolvedTokens.primaryText }; var secondaryText: Color { resolvedTokens.secondaryText }; var metadataText: Color { resolvedTokens.metadataText }; var accent: Color { resolvedTokens.accent }; var selectedFill: Color { resolvedTokens.selectedFill }; var divider: Color { resolvedTokens.divider }; var success: Color { resolvedTokens.success }; var warning: Color { resolvedTokens.warning }; var destructive: Color { resolvedTokens.destructive }
    var swatches: [Color] { [background, selectedFill, primaryText, accent, success] }
}

private struct Tokens {
    let windowBackground, background, surface, surface2, surface4, primaryText, secondaryText, metadataText, accent, selectedFill, divider, success, warning, destructive: Color

    init(theme: DockThemeID) {
        let light = DockThemePalette.roles(theme, dark: false)
        let dark = DockThemePalette.roles(theme, dark: true)
        func color(_ pick: (DockThemePalette.Roles) -> String, nativeAlpha: CGFloat = 1) -> Color {
            func resolved(_ roles: DockThemePalette.Roles) -> NSColor {
                let value = NSColor(hex: pick(roles))
                return theme.usesNativeMaterial ? value.withAlphaComponent(nativeAlpha) : value
            }
            switch theme.appearance {
            case .light: return Color(nsColor: resolved(light))
            case .dark: return Color(nsColor: resolved(dark))
            case .system:
                let lightColor = resolved(light), darkColor = resolved(dark)
                return Color(nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
                })
            }
        }
        // Native macOS is composited over AppKit's menu material. The navy
        // tint matches dark menu-bar popovers (Battery, Wi-Fi) and is dense
        // enough to neutralize colorful wallpapers while the blur shows through. Branded themes stay
        // opaque so their authored colors render exactly as specified.
        windowBackground = color({ $0.bg }, nativeAlpha: 0.60)
        background = color({ $0.bg }, nativeAlpha: 0.16)
        surface = color({ $0.surface }, nativeAlpha: 0.40)
        surface2 = color({ $0.surface2 }, nativeAlpha: 0.32)
        surface4 = color({ $0.surface4 }, nativeAlpha: 0.60)
        primaryText = color { $0.primary }; secondaryText = color { $0.secondary }; metadataText = color { $0.metadata }; accent = color { $0.accent }
        selectedFill = color { $0.selected }; divider = color { $0.divider }; success = color { $0.success }; warning = color { $0.warning }; destructive = color { $0.destructive }
    }
}

private extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0; Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

@MainActor
final class DockThemeStore: ObservableObject {
    static let storageKey = "hermes.dock.theme.v1"
    static let legacyStorageKey = "hermes.sidebar.brand-concept.v1"
    /// The one theme store every Dock window observes. Separate stores would
    /// each hold their own selection, so a surface observing a different
    /// instance kept rendering the previous theme.
    static let shared = DockThemeStore(appliesToApplication: true)
    @Published var selectedThemeID: DockThemeID {
        willSet {
            guard selectedThemeID != newValue else { return }
            // @Published announces from its setter. Publish the runtime first
            // so every observing subtree resolves canvas and text from the same
            // theme during that render pass.
            applyToApplication(themeID: newValue)
        }
        didSet {
            guard oldValue != selectedThemeID else { return }
            defaults.set(selectedThemeID.rawValue, forKey: Self.storageKey)
        }
    }
    private let defaults: UserDefaults
    private let appliesToApplication: Bool
    private var systemAppearanceObservation: NSKeyValueObservation?

    init(defaults: UserDefaults = .standard, appliesToApplication: Bool = false) {
        self.defaults = defaults
        self.appliesToApplication = appliesToApplication
        defaults.removeObject(forKey: Self.legacyStorageKey)
        selectedThemeID = defaults.string(forKey: Self.storageKey).flatMap(DockThemeID.init(rawValue:)) ?? .nativeMacOS
        applyToApplication(themeID: selectedThemeID)
        observeSystemAppearance()
    }
    var palette: DockThemePalette { DockThemePalette(theme: selectedThemeID) }

    /// Publishes the theme to token readers and forces the matching
    /// appearance on every window, so AppKit views, nested hosting views,
    /// menus, and sheets resolve system and theme colors consistently.
    private func applyToApplication(themeID: DockThemeID) {
        guard appliesToApplication else { return }
        DockThemeRuntime.current = themeID
        DockThemeRuntime.revision &+= 1
        guard let app = NSApp else { return }
        let appearance: NSAppearance? = switch themeID.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        if app.appearance?.name != appearance?.name { app.appearance = appearance }
    }

    /// Native macOS follows the system Light/Dark setting. Content that bakes
    /// colors into attributed text is keyed by the theme revision, so bump it
    /// and republish when the effective appearance flips.
    private func observeSystemAppearance() {
        guard appliesToApplication, let app = NSApp else { return }
        var lastIsDark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        systemAppearanceObservation = app.observe(\.effectiveAppearance) { [weak self] app, _ in
            let isDark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            MainActor.assumeIsolated {
                guard let self, isDark != lastIsDark else { return }
                lastIsDark = isDark
                guard self.selectedThemeID.appearance == .system else { return }
                DockThemeRuntime.revision &+= 1
                self.objectWillChange.send()
            }
        }
    }
}

enum DockThemeRuntime {
    nonisolated(unsafe) static var current: DockThemeID = .nativeMacOS
    nonisolated(unsafe) static var revision: Int = 0
}
