import AppKit
import SwiftUI

enum DockThemeID: String, CaseIterable, Identifiable, Codable {
    case glass, clean, nativeMacOS, hermesClassic, ares, mono, slate, warmLight, cartoon, terminal, brutalist, origami, dusk, retro, eInk, swiss, clay, pixel, notebook, hud
    var id: String { rawValue }
    var hermesSkinID: String? {
        switch self { case .nativeMacOS: nil; case .hermesClassic: "default"; case .ares: "ares"; case .mono: "mono"; case .slate: "slate"; case .warmLight: "warm-lightmode"; case .cartoon, .terminal, .brutalist, .origami, .dusk, .retro, .glass, .clean, .eInk, .swiss, .clay, .pixel, .notebook, .hud: nil }
    }
    var title: String {
        switch self { case .nativeMacOS: "System"; case .hermesClassic: "Classic Hermes"; case .ares: "Ares"; case .mono: "Monochrome"; case .slate: "Cool Blue"; case .warmLight: "Warm Light"; case .cartoon: "Cartoon"; case .terminal: "Terminal"; case .brutalist: "Brutalist"; case .origami: "Origami"; case .retro: "Retro"; case .dusk: "Dusk"; case .glass: "Glass"; case .clean: "Clean"; case .eInk: "E-Ink"; case .swiss: "Swiss"; case .clay: "Clay"; case .pixel: "Pixel"; case .notebook: "Notebook"; case .hud: "HUD" }
    }
    var detail: String {
        switch self { case .nativeMacOS: "System menu blur with neutral surfaces and macOS accent colors."; case .hermesClassic: "Serif type, gold accent bars, and a soft gold glow on calm midnight surfaces."; case .ares: "Sharp command-center panels with crimson gradient actions, bronze hard shadows, and bar selection."; case .mono: "Grayscale ledger lines with inverted selection and no color distraction."; case .slate: "Blueprint grid, tight corners, and cool blue bar selection."; case .warmLight: "Embossed warm paper cards with serif type and soft raised shadows."; case .cartoon: "Chunky ink outlines, sticker shadows, rounded type, and bright comic colors."; case .terminal: "Phosphor green on black with scanline rules, glow, monospaced type, and square corners."; case .brutalist: "Graph-paper grid, heavy black borders, hard offset shadows, and loud color."; case .origami: "Folded corners, layered paper shadows, bar selection, and indigo ink accents."; case .retro: "Raised and sunken bevels on square gray panels, navy selection, and a classic desktop feel."; case .dusk: "Near-black surfaces with glowing pastel accents, deep shadows, and generous corners."; case .glass: "Liquid Glass panels, buttons, and tabs that refract soft colored light behind them."; case .clean: "Borderless soft-gray cards on white, gray selection, and color saved for avatars and links."; case .eInk: "Pure black and white with inverted selection, and no motion."; case .swiss: "Boxless typographic layout on a modular grid with a single red accent and underline selection."; case .clay: "Soft inflated controls with molded light and shadow, rounded type, and warm pastels."; case .pixel: "Stepped pixel corners, a pixel grid, chunky outlines, hard shadows, and arcade neon on deep indigo."; case .notebook: "Hand-drawn pencil outlines, ruled paper, tape-corner cards, and highlighter selection."; case .hud: "Chamfered panels with glowing corner brackets, a faint grid, and cyan telemetry accents." }
    }
    var appearance: DockThemeAppearance {
        switch self {
        case .nativeMacOS, .glass, .clean, .swiss: .system
        case .warmLight, .cartoon, .brutalist, .origami, .eInk, .clay, .notebook, .retro: .light
        case .hermesClassic, .ares, .mono, .slate, .terminal, .dusk, .pixel, .hud: .dark
        }
    }
    var usesNativeMaterial: Bool { self == .nativeMacOS || style.material == .glass }
    /// Themes Herm ships without a matching Hermes skin; always selectable.
    static var hermOnly: [DockThemeID] { allCases.filter { $0.hermesSkinID == nil } }
    var style: DockThemeStyle {
        switch self {
        case .hermesClassic: DockThemeStyle(controlRadius: 6, paneRadius: 8, outlineWidth: 1, fontDesign: .serif, selection: .bar, glow: 5, pressScale: 0.98)
        case .warmLight: DockThemeStyle(controlRadius: 12, paneRadius: 16, outlineWidth: 0.5, fontDesign: .serif, selection: .fill, cardShadow: 12, emboss: 4, pressScale: 0.98)
        case .ares: DockThemeStyle(controlRadius: 2, paneRadius: 4, outlineWidth: 1.5, stickerShadow: 3, selection: .bar, accentGradient: true, pressScale: 0.97)
        case .mono: DockThemeStyle(controlRadius: 4, paneRadius: 6, outlineWidth: 1, selection: .invert, backdrop: .ruled, pressScale: 1)
        case .clay: DockThemeStyle(controlRadius: 16, paneRadius: 22, outlineWidth: 0, fontDesign: .rounded, cardShadow: 18, accentGradient: true, emboss: 10, pressScale: 0.94)
        case .pixel: DockThemeStyle(controlRadius: 0, paneRadius: 0, outlineWidth: 3, stickerShadow: 4, geometry: .pixel, fontDesign: .monospaced, selection: .invert, animates: false, backdrop: .grid, pressScale: 1)
        case .notebook: DockThemeStyle(controlRadius: 6, paneRadius: 8, outlineWidth: 1.5, geometry: .sketch, fontDesign: .serif, selection: .highlight, backdrop: .ruled, pressScale: 0.97)
        case .hud: DockThemeStyle(controlRadius: 2, paneRadius: 4, outlineWidth: 1, geometry: .chamfered, fontDesign: .monospaced, selection: .bar, glow: 12, backdrop: .grid, pressScale: 0.98)
        case .cartoon: DockThemeStyle(controlRadius: 14, paneRadius: 18, outlineWidth: 2.5, stickerShadow: 4, fontDesign: .rounded, pressScale: 0.92)
        case .retro: DockThemeStyle(controlRadius: 0, paneRadius: 0, outlineWidth: 0, selection: .invert, animates: false, bevel: true, pressScale: 1)
        case .terminal: DockThemeStyle(controlRadius: 2, paneRadius: 2, outlineWidth: 1, fontDesign: .monospaced, selection: .invert, glow: 10, backdrop: .ruled, pressScale: 1)
        case .brutalist: DockThemeStyle(controlRadius: 2, paneRadius: 2, outlineWidth: 3, stickerShadow: 5, selection: .invert, backdrop: .grid, pressScale: 1)
        case .dusk: DockThemeStyle(controlRadius: 12, paneRadius: 20, outlineWidth: 0.5, glow: 14, cardShadow: 16, accentGradient: true, pressScale: 0.98)
        case .origami: DockThemeStyle(controlRadius: 3, paneRadius: 4, outlineWidth: 1, geometry: .folded, selection: .bar, cardShadow: 10, pressScale: 0.98)
        case .glass: DockThemeStyle(controlRadius: 14, paneRadius: 20, outlineWidth: 0.5, material: .glass, cardShadow: 14, accentGradient: true, pressScale: 0.97, neutralUserBubble: true)
        case .eInk: DockThemeStyle(controlRadius: 0, paneRadius: 0, outlineWidth: 1, selection: .invert, animates: false, pressScale: 1)
        case .swiss: DockThemeStyle(controlRadius: 0, paneRadius: 0, outlineWidth: 0, selection: .underline, chrome: .open, backdrop: .grid, pressScale: 1)
        case .clean: DockThemeStyle(controlRadius: 10, paneRadius: 18, outlineWidth: 0, pressScale: 0.98, cardFill: 1, neutralUserBubble: true, tintedSidebar: true)
        case .slate: DockThemeStyle(controlRadius: 4, paneRadius: 6, outlineWidth: 1, selection: .bar, backdrop: .grid, pressScale: 0.98)
        case .nativeMacOS: DockThemeStyle()
        }
    }
}

enum DockThemeGeometry: Equatable {
    case rounded
    case folded
    /// Stepped, pixel-art corners.
    case pixel
    /// Slightly uneven, hand-drawn outline.
    case sketch
    /// Two opposing corners cut at an angle.
    case chamfered
}

enum DockThemeMaterial: Equatable { case solid, glass }
/// How a selected or hovered tab/row is marked.
enum DockThemeSelection: Equatable { case fill, invert, underline, highlight, bar }
/// Faint pattern drawn on the window canvas.
enum DockThemeBackdrop: Equatable { case none, ruled, grid }
/// `.open` drops card fills and strokes so structure comes from type and spacing.
enum DockThemeChrome: Equatable { case boxed, open }

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
    var material: DockThemeMaterial = .solid
    var selection: DockThemeSelection = .fill
    var chrome: DockThemeChrome = .boxed
    /// False turns off every transition and animation, like an e-ink refresh.
    var animates: Bool = true
    /// Soft accent-colored halo around primary controls and cards; 0 = none.
    var glow: CGFloat = 0
    /// Blur radius of a soft drop shadow under cards; 0 = none.
    var cardShadow: CGFloat = 0
    /// Adds a light top-down sheen to filled primary controls.
    var accentGradient: Bool = false
    /// Blur of a paired light/dark molded shadow (clay look); 0 = none.
    var emboss: CGFloat = 0
    /// Win95-style 3D edges: light top-left and dark bottom-right on raised parts, reversed when pressed or inset.
    var bevel: Bool = false
    var backdrop: DockThemeBackdrop = .none
    var pressScale: CGFloat = 0.96
    /// Opacity of the surface fill behind cards; solid skins raise it so cards read by tone alone.
    var cardFill: CGFloat = 0.26
    /// User bubbles take a neutral surface instead of the accent tint.
    var neutralUserBubble: Bool = false
    /// Rail and session list sit on a tinted surface so the chat reads as the page.
    var tintedSidebar: Bool = false

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
    private static func luminance(_ hex: String) -> Double {
        let c = NSColor(hex: hex).usingColorSpace(.sRGB) ?? .black
        func lin(_ v: CGFloat) -> Double { let d = Double(v); return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
    fileprivate static func onAccentHex(forAccent accent: String) -> String {
        let l = luminance(accent)
        return (1.05 / (l + 0.05)) >= ((l + 0.05) / (luminance("#111111") + 0.05)) ? "#FFFFFF" : "#111111"
    }
    fileprivate typealias Roles = (bg: String, surface: String, surface2: String, surface4: String, primary: String, secondary: String, metadata: String, accent: String, selected: String, divider: String, success: String, warning: String, destructive: String)
    fileprivate static func roles(_ theme: DockThemeID, dark isDark: Bool) -> Roles {
        switch theme {
        case .nativeMacOS: return isDark ? ("#000615", "#2A3247", "#171C2B", "#3A4359", "#D2D7E0", "#BCC2CF", "#959CAC", "#0A84FF", "#1F3D6B", "#3C4459", "#30D158", "#FF9F0A", "#FF453A") : ("#F2F2F7", "#FFFFFF", "#E5E5EA", "#D1D1D6", "#1C1C1E", "#4D4D52", "#646469", "#007AFF", "#D9E9FF", "#8E8E93", "#248A3D", "#C93400", "#D70015")
        case .hermesClassic: return isDark ? ("#1A1A2E", "#211F35", "#171728", "#333355", "#D3CCB4", "#BBB8AC", "#988964", "#E5B23E", "#3A3A55", "#544F67", "#8FBC8F", "#E3C04F", "#FF6B6B") : ("#F7F3E8", "#F1E8D3", "#FBF9F2", "#E9DFC6", "#3E321F", "#61523A", "#756549", "#B8860B", "#E8DCC2", "#D7C9A9", "#2E7D32", "#B45309", "#B4232F")
        case .ares: return isDark ? ("#2A1212", "#321719", "#241010", "#5C221D", "#CCC2AF", "#C7B4A5", "#AC7C78", "#DD4A3A", "#692620", "#6E584B", "#7BC96F", "#C7A96B", "#EF5350") : ("#F8EEE8", "#F1DDD3", "#FCF7F4", "#E8C6B8", "#3B201B", "#60433C", "#7E5850", "#DD4A3A", "#F0D1C7", "#DAB2A2", "#4CAF50", "#C7A96B", "#EF5350")
        case .mono: return isDark ? ("#1F1F1F", "#282828", "#181818", "#464646", "#C8C8C8", "#C8C8C8", "#909090", "#AAAAAA", "#505050", "#5E5E5E", "#B5B5B5", "#AAAAAA", "#D0D0D0") : ("#F5F5F5", "#EDEDED", "#FAFAFA", "#E2E2E2", "#202020", "#565656", "#696969", "#555555", "#E0E0E0", "#C7C7C7", "#5F5F5F", "#777777", "#8A8A8A")
        case .slate: return isDark ? ("#151C2F", "#1C2740", "#111827", "#324867", "#BEC6CE", "#BEC6CE", "#8891A0", "#7EB8F6", "#3A5375", "#545E6B", "#63D0A6", "#E6A855", "#F7A072") : ("#EFF4FA", "#E4ECF6", "#F7FAFD", "#D4E1F0", "#17243A", "#46576B", "#5B6A7F", "#2563C7", "#D3E0F4", "#B7C8DD", "#238B67", "#A86916", "#C94C4C")
        case .warmLight: return ("#F5F0E8", "#EEE5D5", "#FBF7EF", "#E8DCC8", "#2C1810", "#664F3D", "#745D45", "#8B4513", "#E8DAD0", "#D2BE9D", "#2E7D32", "#E65100", "#C62828")
        case .cartoon: return ("#FFF6DC", "#FFFFFF", "#FFEFC4", "#FFE7A3", "#1E1A16", "#4A4038", "#786859", "#F0481F", "#BFE4FF", "#1E1A16", "#168F55", "#B86E00", "#E5383B")
        case .retro: return ("#C0C0C0", "#D4D0C8", "#CBC7BF", "#DEDBD3", "#000000", "#2B2B2B", "#454545", "#000080", "#B4B8D8", "#7F7F7F", "#005A00", "#7A4A00", "#A00000")
        case .terminal: return ("#0F1511", "#18211B", "#131A15", "#253329", "#C9DBCD", "#B4CCBB", "#8AA894", "#4ADE80", "#1F4A2B", "#3D5C46", "#4ADE80", "#F2C94C", "#FF6B6B")
        case .brutalist: return ("#FFFFFF", "#FFFFFF", "#F2F2F2", "#FFE500", "#000000", "#222222", "#555555", "#0047FF", "#FFE500", "#000000", "#00A152", "#B86A00", "#FF1F1F")
        case .origami: return ("#F2EEE6", "#FFFDF8", "#E9E2D7", "#DED4C5", "#29251F", "#554E45", "#6B6156", "#6252B5", "#DED8F5", "#A89D8E", "#2F7D62", "#A95F1E", "#B63E42")
        case .clay: return ("#F6EFE9", "#FFF8F2", "#FBF1E8", "#EBDDD3", "#3B2F2F", "#635251", "#7B6865", "#E4584A", "#FFD9D0", "#D6C0B2", "#2F8A66", "#A86A10", "#D9443D")
        case .pixel: return ("#1A1033", "#261A4A", "#20143F", "#3A2A6B", "#D6D0EE", "#C2BBE2", "#8F85B9", "#FF4FA3", "#4B2F8A", "#5A46A0", "#3DDC97", "#FFD23F", "#FF5C6C")
        case .notebook: return ("#FBF6E9", "#FFFDF5", "#F5EFDC", "#E9E0C6", "#2B2A33", "#55525E", "#6C6879", "#2F4FA8", "#FFF0A8", "#77747F", "#3F8F5B", "#A86F00", "#C8362E")
        case .hud: return ("#060B14", "#0C1626", "#09111E", "#12263D", "#A9DCEB", "#83B8CA", "#5C8796", "#19D3F3", "#0F3A52", "#1F5C75", "#3DEB9A", "#FFB020", "#FF4D5E")
        case .dusk: return ("#0B0B0E", "#131318", "#0F0F13", "#1E1E26", "#D2D2D8", "#A5A7B3", "#8A8C9A", "#9B8CF0", "#2A2740", "#2E2E38", "#6EDDB0", "#F5B965", "#FF6B6B")
        case .glass: return isDark ? ("#121214", "#1D1D20", "#161618", "#2B2B2F", "#D8D8DC", "#B4B4BA", "#88888F", "#0A84FF", "#303035", "#3A3A3F", "#30D158", "#FF9F0A", "#FF453A") : ("#F4F4F5", "#FFFFFF", "#F8F8F9", "#E6E6E9", "#18181B", "#52525B", "#6B6B73", "#007AFF", "#E2E2E6", "#D4D4D8", "#248A3D", "#C93400", "#D70015")
        case .clean: return isDark ? ("#141414", "#1E1E1E", "#191919", "#2A2A2A", "#D6D6D6", "#B0B0B0", "#8C8C8C", "#5A9BFF", "#2C2C2C", "#303030", "#4CC27A", "#E5A640", "#FF6B6B") : ("#FFFFFF", "#F5F5F5", "#F7F7F7", "#ECECEC", "#111111", "#5C5C5C", "#6B6B6B", "#2672E8", "#EBEBEB", "#DEDEDE", "#2F8F4E", "#B26A00", "#D93A3A")
        case .eInk: return ("#FFFFFF", "#FFFFFF", "#FFFFFF", "#EDEDED", "#000000", "#2B2B2B", "#555555", "#000000", "#D9D9D9", "#000000", "#1A1A1A", "#333333", "#000000")
        case .swiss: return isDark ? ("#0A0A0A", "#0A0A0A", "#0A0A0A", "#1C1C1C", "#D4D4D4", "#B0B0B0", "#7A7A7A", "#FF3B30", "#2A1412", "#2E2E2E", "#9A9A9A", "#B0B0B0", "#FF3B30") : ("#FFFFFF", "#FFFFFF", "#FFFFFF", "#F0F0F0", "#0A0A0A", "#4A4A4A", "#747474", "#E30613", "#FBE4E5", "#D9D9D9", "#555555", "#777777", "#E30613")
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
    var onAccent: Color { resolvedTokens.onAccent }
    var primaryText: Color { resolvedTokens.primaryText }; var secondaryText: Color { resolvedTokens.secondaryText }; var metadataText: Color { resolvedTokens.metadataText }; var accent: Color { resolvedTokens.accent }; var selectedFill: Color { resolvedTokens.selectedFill }; var divider: Color { resolvedTokens.divider }; var success: Color { resolvedTokens.success }; var warning: Color { resolvedTokens.warning }; var destructive: Color { resolvedTokens.destructive }
    /// Rail and session list; tinted skins set them apart from the chat page.
    var sidebarBackground: Color { theme.style.tintedSidebar ? surface2 : background }
    var swatches: [Color] { [background, selectedFill, primaryText, accent, success] }
}

private struct Tokens {
    let windowBackground, background, surface, surface2, surface4, primaryText, secondaryText, metadataText, accent, onAccent, selectedFill, divider, success, warning, destructive: Color

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
        windowBackground = color({ $0.bg }, nativeAlpha: theme == .glass ? 0.62 : 0.60)
        background = color({ $0.bg }, nativeAlpha: 0.16)
        surface = color({ $0.surface }, nativeAlpha: 0.40)
        surface2 = color({ $0.surface2 }, nativeAlpha: 0.32)
        surface4 = color({ $0.surface4 }, nativeAlpha: 0.60)
        primaryText = color { $0.primary }; secondaryText = color { $0.secondary }; metadataText = color { $0.metadata }; accent = color { $0.accent }
        // Label color for filled accent controls: whichever of white/near-black
        // reads better on this theme's accent (a pale accent needs dark text).
        onAccent = color { DockThemePalette.onAccentHex(forAccent: $0.accent) }
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
        selectedThemeID = defaults.string(forKey: Self.storageKey).flatMap(DockThemeID.init(rawValue:)) ?? .glass
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
        // A window keeps a forced appearance (e.g. .aqua from a light skin) after
        // the app-level one is cleared, which left System/Glass stuck on a plain
        // light material until relaunch. Re-assert it per window.
        for window in app.windows where window.appearance?.name != appearance?.name { window.appearance = appearance }
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
    nonisolated(unsafe) static var current: DockThemeID = .glass
    nonisolated(unsafe) static var revision: Int = 0
}
