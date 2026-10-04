import AppKit
import SwiftUI

enum DockThemeID: String, CaseIterable, Identifiable, Codable {
    case nativeMacOS, hermesClassic, ares, mono, slate, daylight, warmLight, poseidon, sisyphus, charizard, cartoon, terminal, flat, brutalist, origami
    var id: String { rawValue }
    var hermesSkinID: String? {
        switch self { case .nativeMacOS: nil; case .hermesClassic: "default"; case .ares: "ares"; case .mono: "mono"; case .slate: "slate"; case .daylight: "daylight"; case .warmLight: "warm-lightmode"; case .poseidon: "poseidon"; case .sisyphus: "sisyphus"; case .charizard: "charizard"; case .cartoon, .terminal, .flat, .brutalist, .origami: nil }
    }
    var title: String {
        switch self { case .nativeMacOS: "Native macOS"; case .hermesClassic: "Classic Hermes"; case .ares: "Ares"; case .mono: "Monochrome"; case .slate: "Cool Blue"; case .daylight: "Daylight"; case .warmLight: "Warm Light"; case .poseidon: "Poseidon"; case .sisyphus: "Sisyphus"; case .charizard: "Volcanic"; case .cartoon: "Cartoon"; case .terminal: "Terminal"; case .flat: "Flat"; case .brutalist: "Brutalist"; case .origami: "Origami" }
    }
    var detail: String {
        switch self { case .nativeMacOS: "System menu blur with neutral surfaces and macOS accent colors."; case .hermesClassic: "Gold identity accents with calm midnight surfaces."; case .ares: "Crimson actions, bronze labels, and a warm operational tone."; case .mono: "A focused grayscale palette with minimal distraction."; case .slate: "Developer-focused blue surfaces with crisp cool contrast."; case .daylight: "Bright surfaces with dark text and clear blue actions."; case .warmLight: "Warm paper surfaces with brown and gold hierarchy."; case .poseidon: "Deep ocean blue with seafoam highlights."; case .sisyphus: "Austere grayscale built for persistent work."; case .charizard: "Burnt orange controls with ember-colored emphasis."; case .cartoon: "Chunky ink outlines, sticker shadows, rounded type, and bright comic colors."; case .terminal: "Phosphor green on black, monospaced type, and square corners."; case .flat: "Borderless, quiet surfaces with small corners and no depth."; case .brutalist: "Square corners, heavy black borders, hard offset shadows, and loud color."; case .origami: "Folded corners, crisp paper layers, angular controls, and indigo ink accents." }
    }
    var appearance: DockThemeAppearance {
        switch self {
        case .nativeMacOS, .flat: .system
        case .daylight, .warmLight, .cartoon, .brutalist, .origami: .light
        default: .dark
        }
    }
    var usesNativeMaterial: Bool { self == .nativeMacOS }
    /// Themes Herm ships without a matching Hermes skin; always selectable.
    static var hermOnly: [DockThemeID] { allCases.filter { $0.hermesSkinID == nil } }
    var style: DockThemeStyle {
        switch self {
        case .cartoon: DockThemeStyle(controlRadius: 12, paneRadius: 16, outlineWidth: 2, stickerShadow: 3, fontDesign: .rounded, pressScale: 0.92)
        case .terminal: DockThemeStyle(controlRadius: 2, paneRadius: 2, outlineWidth: 1, fontDesign: .monospaced, pressScale: 1)
        case .flat: DockThemeStyle(controlRadius: 6, paneRadius: 8, outlineWidth: 0.5, pressScale: 0.98)
        case .brutalist: DockThemeStyle(controlRadius: 2, paneRadius: 2, outlineWidth: 3, stickerShadow: 5, pressScale: 1)
        case .origami: DockThemeStyle(controlRadius: 3, paneRadius: 4, outlineWidth: 1, geometry: .folded, pressScale: 0.98)
        default: DockThemeStyle()
        }
    }
}

enum DockThemeGeometry: Equatable {
    case rounded
    case folded
}

/// Component geometry a theme controls beyond color. Shared controls, cards,
/// and `DockLayout` read it, so a theme can reshape the UI from one place.
struct DockThemeStyle: Equatable {
    var controlRadius: CGFloat = 8
    var paneRadius: CGFloat = 10
    /// Outline weight for controls and cards; 0.5 is the hairline default.
    var outlineWidth: CGFloat = 0.5
    /// Offset of a hard, blur-free ink shadow under controls and cards; 0 = none.
    var stickerShadow: CGFloat = 0
    var geometry: DockThemeGeometry = .rounded
    var fontDesign: Font.Design = .default
    var pressScale: CGFloat = 0.96

    static var current: DockThemeStyle { DockThemeRuntime.current.style }
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
        case .nativeMacOS: return isDark ? ("#000615", "#2A3247", "#171C2B", "#3A4359", "#D2D7E0", "#A9B0C0", "#7F879A", "#0A84FF", "#1F3D6B", "#3C4459", "#30D158", "#FF9F0A", "#FF453A") : ("#F2F2F7", "#FFFFFF", "#E5E5EA", "#D1D1D6", "#1C1C1E", "#636366", "#8E8E93", "#007AFF", "#D9E9FF", "#8E8E93", "#248A3D", "#C93400", "#D70015")
        case .hermesClassic: return isDark ? ("#1A1A2E", "#211F35", "#171728", "#333355", "#D3CCB4", "#B0AFA8", "#978862", "#E5B23E", "#3A3A55", "#544F67", "#8FBC8F", "#E3C04F", "#FF6B6B") : ("#F7F3E8", "#F1E8D3", "#FBF9F2", "#E9DFC6", "#3E321F", "#76664A", "#948261", "#B8860B", "#E8DCC2", "#D7C9A9", "#2E7D32", "#B45309", "#B4232F")
        case .ares: return isDark ? ("#2A1212", "#321719", "#241010", "#5C221D", "#CCC2AF", "#C2A59B", "#A87370", "#DD4A3A", "#692620", "#6E584B", "#7BC96F", "#C7A96B", "#EF5350") : ("#F8EEE8", "#F1DDD3", "#FCF7F4", "#E8C6B8", "#3B201B", "#795A52", "#966C63", "#DD4A3A", "#F0D1C7", "#DAB2A2", "#4CAF50", "#C7A96B", "#EF5350")
        case .mono, .sisyphus: return isDark ? ("#1F1F1F", "#282828", "#181818", "#464646", "#C8C8C8", "#ADADAD", "#858585", "#AAAAAA", "#505050", "#5E5E5E", "#B5B5B5", "#AAAAAA", "#D0D0D0") : ("#F5F5F5", "#EDEDED", "#FAFAFA", "#E2E2E2", "#202020", "#606060", "#888888", "#555555", "#E0E0E0", "#C7C7C7", "#5F5F5F", "#777777", "#8A8A8A")
        case .slate: return isDark ? ("#151C2F", "#1C2740", "#111827", "#324867", "#BEC6CE", "#AEBBCA", "#7A8494", "#7EB8F6", "#3A5375", "#545E6B", "#63D0A6", "#E6A855", "#F7A072") : ("#EFF4FA", "#E4ECF6", "#F7FAFD", "#D4E1F0", "#17243A", "#536579", "#718095", "#2563C7", "#D3E0F4", "#B7C8DD", "#238B67", "#A86916", "#C94C4C")
        case .daylight: return ("#F8FAFC", "#EEF3FA", "#FBFCFE", "#DBEAFE", "#1E2533", "#475569", "#64748B", "#2563EB", "#D3E0FB", "#CBD5E1", "#15803D", "#B45309", "#B91C1C")
        case .warmLight: return ("#F5F0E8", "#EEE5D5", "#FBF7EF", "#E8DCC8", "#2C1810", "#6E5743", "#8A735A", "#8B4513", "#E8DAD0", "#D2BE9D", "#2E7D32", "#E65100", "#C62828")
        case .poseidon: return isDark ? ("#0F2440", "#162E4E", "#0B1C33", "#254D73", "#C3D2DC", "#A4BDCD", "#6F8CA5", "#5DB8F5", "#2A587F", "#496884", "#6ED7B0", "#5DB8F5", "#D94F4F") : ("#EDF7FC", "#E0F0F8", "#F7FCFF", "#CDE5F2", "#123047", "#476A80", "#66869B", "#267FB9", "#CBE7F5", "#B8D3E1", "#2E8B69", "#B4771D", "#C74747")
        case .cartoon: return ("#FFF6DC", "#FFFFFF", "#FFEFC4", "#FFE7A3", "#1E1A16", "#4A4038", "#7A6A5A", "#FF5A36", "#BFE4FF", "#1E1A16", "#1FA463", "#F29D12", "#E5383B")
        case .terminal: return ("#0F1511", "#18211B", "#131A15", "#253329", "#C9DBCD", "#B4CCBB", "#8AA894", "#4ADE80", "#1F4A2B", "#3D5C46", "#4ADE80", "#F2C94C", "#FF6B6B")
        case .flat: return isDark ? ("#16181D", "#1D2026", "#16181D", "#262A31", "#CFD2D9", "#A3A9B5", "#7A808C", "#4C9AFF", "#1E3A5F", "#23262D", "#57D9A3", "#FFAB00", "#FF5630") : ("#FFFFFF", "#F4F5F7", "#FFFFFF", "#EBECF0", "#172B4D", "#505F79", "#7A869A", "#0065FF", "#DEEBFF", "#EBECF0", "#00875A", "#FF8B00", "#DE350B")
        case .brutalist: return ("#FFFFFF", "#FFFFFF", "#F2F2F2", "#FFE500", "#000000", "#222222", "#555555", "#0047FF", "#FFE500", "#000000", "#00A152", "#FF9900", "#FF1F1F")
        case .origami: return ("#F2EEE6", "#FFFDF8", "#E9E2D7", "#DED4C5", "#29251F", "#625A50", "#867B6E", "#6252B5", "#DED8F5", "#A89D8E", "#2F7D62", "#A95F1E", "#B63E42")
        case .charizard: return isDark ? ("#2B160E", "#351B11", "#1E0F09", "#4A1B07", "#D3C6AF", "#C6A47E", "#9A7A5E", "#F29C38", "#5A260D", "#7B593A", "#6BCB77", "#F29C38", "#EF5350") : ("#FFF5E9", "#F8E8D0", "#FFFAF3", "#F5D2A8", "#3A2114", "#765741", "#96704F", "#C75B1D", "#F5D2A8", "#D8B487", "#2E7D32", "#F29C38", "#C62828")
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
