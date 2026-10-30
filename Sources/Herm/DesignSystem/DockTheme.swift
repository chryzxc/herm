import AppKit
import SwiftUI

enum DockThemeID: String, CaseIterable, Identifiable, Codable {
    case glass, clean, hermesClassic, ares, mono, slate, warmLight, cartoon, terminal, brutalist, origami, dusk, retro,
        eInk, swiss, clay, pixel, notebook, hud, storm, island
    var id: String { rawValue }
    var hermesSkinID: String? {
        switch self {
        case .hermesClassic: "default"
        case .ares: "ares"
        case .mono: "mono"
        case .slate: "slate"
        case .warmLight: "warm-lightmode"
        case .cartoon, .terminal, .brutalist, .origami, .dusk, .retro, .glass, .clean, .eInk, .swiss, .clay, .pixel,
            .notebook, .hud, .storm, .island:
            nil
        }
    }
    var title: String {
        switch self {
        case .hermesClassic: "Hermes"
        case .ares: "Ares"
        case .mono: "Monochrome"
        case .slate: "Cool Blue"
        case .warmLight: "Warm Light"
        case .cartoon: "Cartoon"
        case .terminal: "Terminal"
        case .brutalist: "Brutalist"
        case .origami: "Origami"
        case .retro: "Retro"
        case .dusk: "Dusk"
        case .glass: "Glass"
        case .clean: "Clean"
        case .eInk: "E-Ink"
        case .swiss: "Swiss"
        case .clay: "Clay"
        case .pixel: "Pixel"
        case .notebook: "Notebook"
        case .hud: "HUD"
        case .storm: "Storm"
        case .island: "Island"
        }
    }
    var signature: String {
        switch self {
        case .glass: "Liquid glass"
        case .clean: "Quiet porcelain"
        case .hermesClassic: "Nous etching"
        case .ares: "Oxblood & bronze"
        case .mono: "Graphite ledger"
        case .slate: "Steel blueprint"
        case .warmLight: "Cream stationery"
        case .cartoon: "Ink & stickers"
        case .terminal: "Phosphor canvas"
        case .brutalist: "Bold print studio"
        case .origami: "Folded ivory"
        case .dusk: "Plum & lavender"
        case .retro: "Silver desktop"
        case .eInk: "Paper & ink"
        case .swiss: "Open editorial"
        case .clay: "Soft terracotta"
        case .pixel: "Indigo arcade"
        case .notebook: "Pencil & paper"
        case .hud: "Night instruments"
        case .storm: "Neon rain"
        case .island: "Pure black"
        }
    }
    var detail: String {
        switch self {
        case .glass: "Native macOS Liquid Glass with neutral graphite tint. Follows macOS appearance."
        case .clean: "Porcelain surfaces, neutral gray selection, and borderless cards. Follows macOS appearance."
        case .hermesClassic:
            "The Hermes desktop look: clean chrome, Nous blue, square controls, and a faint etched backdrop. Follows macOS appearance."
        case .ares: "Oxblood panels, bronze contours, crisp corners, and hard offset shadows."
        case .mono: "Graphite surfaces, monospaced lettering, and inverted silver selection."
        case .slate: "Steel-blue panels, a fine blueprint grid, and precise blue selection bars."
        case .warmLight: "Cream paper, brown ink, serif lettering, and gently pressed surfaces."
        case .cartoon: "Cream canvas, white stickers, chunky ink outlines, and springy rounded controls."
        case .terminal: "Green-black surfaces, fine scanlines, monospaced lettering, and inverted selection."
        case .brutalist: "White stock, a dotted print grid, cobalt actions, and heavy black offset outlines."
        case .origami: "Ivory paper, indigo ink, clipped folds, and softly layered panels."
        case .dusk: "Plum-black surfaces, lavender accents, soft depth, and generous corners."
        case .retro: "Silver panels, blue selection, and raised and sunken desktop bevels. No motion."
        case .eInk: "Crisp paper, black rules, square controls, and inverted selection. No motion."
        case .swiss: "Open typographic layout, a clear canvas, red underlines, and a single-rule composer."
        case .clay: "Warm porcelain, terracotta accents, rounded lettering, and softly molded controls."
        case .pixel: "Indigo panels, magenta accents, stepped corners, and pixel-grid shadows. No motion."
        case .notebook: "Ruled cream paper, blue accents, pencil outlines, and highlighter selection."
        case .hud: "Cyan instruments, crosshair grid, chamfered panels, and fine corner brackets."
        case .storm: "Storm-night indigo, matte blue controls, falling rain streaks, and crisp selection bars."
        case .island: "Pure black surfaces and white type that blend with the camera notch. Used by the top island."
        }
    }
    var appearance: DockThemeAppearance {
        switch self {
        case .glass, .clean, .swiss, .hermesClassic: .system
        case .warmLight, .cartoon, .brutalist, .origami, .eInk, .clay, .notebook, .retro: .light
        case .ares, .mono, .slate, .terminal, .dusk, .pixel, .hud, .storm, .island: .dark
        }
    }
    var usesNativeMaterial: Bool { style.material == .glass }
    /// Themes Herm ships without a matching Hermes skin; always selectable.
    static var hermOnly: [DockThemeID] { allCases.filter { $0.hermesSkinID == nil } }
    var style: DockThemeStyle {
        switch self {
        case .hermesClassic:
            DockThemeStyle(
                controlRadius: 2, paneRadius: 3, outlineWidth: 0.5, backdrop: .etching, motion: .snap, pressScale: 1,
                cardFill: 1, tintedSidebar: true, flatShell: true)
        case .warmLight:
            DockThemeStyle(
                controlRadius: 12, paneRadius: 16, outlineWidth: 0.5, fontDesign: .serif, selection: .fill,
                cardShadow: 6, emboss: 3, pressScale: 0.98, cardFill: 1, neutralUserBubble: true, tintedSidebar: true)
        case .ares:
            DockThemeStyle(
                controlRadius: 2, paneRadius: 4, outlineWidth: 1.5, stickerShadow: 3, selection: .bar,
                accentGradient: true, motion: .mechanical, pressScale: 0.97, cardFill: 1, tintedSidebar: true)
        case .mono:
            DockThemeStyle(
                controlRadius: 2, paneRadius: 4, outlineWidth: 0.5, fontDesign: .monospaced, selection: .invert,
                motion: .mechanical, pressScale: 1, cardFill: 1, neutralUserBubble: true, tintedSidebar: true)
        case .clay:
            DockThemeStyle(
                controlRadius: 16, paneRadius: 22, outlineWidth: 0, fontDesign: .rounded, cardShadow: 5,
                accentGradient: true, emboss: 4, motion: .bouncy, pressScale: 0.94, cardFill: 1, tintedSidebar: true)
        case .pixel:
            DockThemeStyle(
                controlRadius: 0, paneRadius: 0, outlineWidth: 3, stickerShadow: 4, geometry: .pixel,
                fontDesign: .monospaced, selection: .invert, animates: false, backdrop: .grid, pressScale: 1,
                cardFill: 1, tintedSidebar: true)
        case .notebook:
            DockThemeStyle(
                controlRadius: 6, paneRadius: 8, outlineWidth: 1.5, geometry: .sketch, fontDesign: .serif,
                selection: .highlight, backdrop: .ruled, pressScale: 0.97, cardFill: 1, neutralUserBubble: true,
                tintedSidebar: true)
        case .hud:
            DockThemeStyle(
                controlRadius: 2, paneRadius: 4, outlineWidth: 1, geometry: .chamfered, fontDesign: .monospaced,
                selection: .bar, glow: 5, backdrop: .crosshairs, motion: .mechanical, pressScale: 0.98, cardFill: 0.8,
                tintedSidebar: true)
        case .storm:
            DockThemeStyle(
                controlRadius: 8, paneRadius: 12, outlineWidth: 1, selection: .bar, cardShadow: 5,
                backdrop: .rain, motion: .float, pressScale: 0.97, cardFill: 1,
                tintedSidebar: true)
        case .cartoon:
            DockThemeStyle(
                controlRadius: 14, paneRadius: 18, outlineWidth: 2.5, stickerShadow: 4, fontDesign: .rounded,
                motion: .bouncy, pressScale: 0.94, cardFill: 1, tintedSidebar: true)
        case .retro:
            DockThemeStyle(
                controlRadius: 0, paneRadius: 0, outlineWidth: 0, selection: .invert, animates: false, bevel: true,
                pressScale: 1, cardFill: 1, neutralUserBubble: true, tintedSidebar: true)
        case .terminal:
            DockThemeStyle(
                controlRadius: 2, paneRadius: 2, outlineWidth: 1, fontDesign: .monospaced, selection: .invert, glow: 3,
                backdrop: .scanlines, motion: .mechanical, pressScale: 1, cardFill: 0.85, tintedSidebar: true)
        case .brutalist:
            DockThemeStyle(
                controlRadius: 2, paneRadius: 2, outlineWidth: 3, stickerShadow: 5, selection: .invert, backdrop: .dots,
                motion: .mechanical, pressScale: 1, cardFill: 1, tintedSidebar: true)
        case .dusk:
            DockThemeStyle(
                controlRadius: 12, paneRadius: 20, outlineWidth: 0.5, glow: 2, cardShadow: 6, accentGradient: true,
                motion: .float, pressScale: 0.98, cardFill: 1, tintedSidebar: true)
        case .origami:
            DockThemeStyle(
                controlRadius: 3, paneRadius: 4, outlineWidth: 1, geometry: .folded, selection: .bar, cardShadow: 6,
                pressScale: 0.98, cardFill: 1, neutralUserBubble: true, tintedSidebar: true)
        case .glass:
            DockThemeStyle(
                controlRadius: 14, paneRadius: 20, outlineWidth: 0.5, material: .glass, cardShadow: 0, motion: .float,
                pressScale: 0.97, neutralUserBubble: true)
        case .eInk:
            DockThemeStyle(
                controlRadius: 0, paneRadius: 0, outlineWidth: 1, selection: .invert, animates: false, pressScale: 1,
                cardFill: 1, neutralUserBubble: true)
        case .swiss:
            DockThemeStyle(
                controlRadius: 0, paneRadius: 0, outlineWidth: 0, selection: .underline, chrome: .open,
                motion: .mechanical, pressScale: 1, neutralUserBubble: true)
        case .clean:
            DockThemeStyle(
                controlRadius: 10, paneRadius: 18, outlineWidth: 0, pressScale: 0.98, cardFill: 1,
                neutralUserBubble: true, tintedSidebar: true)
        case .slate:
            DockThemeStyle(
                controlRadius: 4, paneRadius: 6, outlineWidth: 1, selection: .bar, backdrop: .grid, motion: .mechanical,
                pressScale: 0.98, cardFill: 0.8, tintedSidebar: true)
        case .island:
            DockThemeStyle(
                controlRadius: 14, paneRadius: 22, outlineWidth: 0, motion: .float, pressScale: 0.97, cardFill: 1,
                neutralUserBubble: true)
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
/// `.neon` is a gradient wash with a glowing leading bar, drawn from the palette's `neonHues`.
enum DockThemeSelection: Equatable { case fill, invert, underline, highlight, bar, neon }
/// Faint pattern drawn on the window canvas.
enum DockThemeBackdrop: Equatable { case none, ruled, grid, dots, scanlines, crosshairs, rain, etching }
/// How a skin moves: the curve and pace every `dockEase` transition takes.
enum DockThemeMotion: Equatable {
    /// Soft deceleration; the default.
    case glide
    /// Hermes desktop: fast ease-out, and hover/press paint instantly so only the return eases.
    case snap
    /// Short, overshoot-free instrument motion.
    case mechanical
    /// Springy overshoot for sticker and molded skins.
    case bouncy
    /// Slower, weightless settle for glass and night skins.
    case float
}
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
    var motion: DockThemeMotion = .glide
    var pressScale: CGFloat = 0.96
    /// Opacity of the surface fill behind cards; solid skins raise it so cards read by tone alone.
    var cardFill: CGFloat = 0.26
    /// User bubbles take a neutral surface instead of the accent tint.
    var neutralUserBubble: Bool = false
    /// Rail and session list sit on a tinted surface so the chat reads as the page.
    var tintedSidebar: Bool = false
    /// Hermes Desktop's flat shell: content meets the sidebar edge to edge, and section labels are tracked caps.
    var flatShell: Bool = false

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
                let theme = DockThemeID.allCases.first(where: { $0.hermesSkinID == skin.id })
            else {
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
    var labelFont: Font { DockTypography.font(.navigation) }
    var profileFont: Font { .system(size: 13, weight: .medium) }
    var sectionFont: Font { .system(size: 12, weight: .medium) }
    var rowHeight: CGFloat { 44 }
    var cornerRadius: CGFloat { 7 }
    var sectionSpacing: CGFloat { 12 }
    var usesStructuredDividers: Bool { true }
    var showsDestinationIcons: Bool { true }
    /// Semantic hex roles for one appearance of a theme.
    static func luminance(_ hex: String) -> Double {
        let c = NSColor(hex: hex).usingColorSpace(.sRGB) ?? .black
        func lin(_ v: CGFloat) -> Double {
            let d = Double(v)
            return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
    static func onAccentHex(forAccent accent: String) -> String {
        let l = luminance(accent)
        return (1.05 / (l + 0.05)) >= ((l + 0.05) / (luminance("#111111") + 0.05)) ? "#FFFFFF" : "#111111"
    }
    typealias Roles = (
        bg: String, surface: String, surface2: String, surface4: String, primary: String, secondary: String,
        metadata: String, accent: String, selected: String, divider: String, success: String, warning: String,
        destructive: String
    )
    fileprivate static func roles(_ theme: DockThemeID, dark isDark: Bool) -> Roles {
        var roles = baseRoles(theme, dark: isDark)
        guard theme != .mono && theme != .eInk else { return roles }
        // Interaction and selection belong to the skin, never the status palette.
        roles.success = DockAccentColor.green.hex(on: roles)
        roles.warning = DockAccentColor.orange.hex(on: roles)
        roles.destructive = DockAccentColor.coral.hex(on: roles)
        return roles
    }

    private static func baseRoles(_ theme: DockThemeID, dark isDark: Bool) -> Roles {
        switch theme {
        // Hermes desktop "Nous": GitHub Default neutrals carrying Nous blue.
        case .hermesClassic:
            return isDark
                ? (
                    "#0D1117", "#161B22", "#010409", "#21262D", "#D3D9E0", "#B8C2CE", "#939EAB", "#4A84FE", "#17243A",
                    "#30363D", "#3FB950", "#D29922", "#F85149"
                )
                : (
                    "#FFFFFF", "#F6F8FA", "#F6F8FA", "#EAEEF2", "#1F2328", "#424A53", "#656D76", "#0053FD", "#E3EDFF",
                    "#D0D7DE", "#1A7F37", "#9A6700", "#CF222E"
                )
        case .ares:
            return isDark
                ? (
                    "#1A1115", "#291B20", "#21151A", "#38252B", "#E3D7C7", "#CCBDAE", "#BA9690", "#DD4A3A", "#692620",
                    "#6E584B", "#7BC96F", "#C7A96B", "#EF5350"
                )
                : (
                    "#F8EEE8", "#F1DDD3", "#FCF7F4", "#E8C6B8", "#3B201B", "#60433C", "#7E5850", "#DD4A3A", "#F0D1C7",
                    "#DAB2A2", "#4CAF50", "#C7A96B", "#EF5350"
                )
        case .mono:
            return isDark
                ? (
                    "#1B1B1B", "#262626", "#202020", "#383838", "#D8D8D8", "#BFBFBF", "#A2A2A2", "#BFBFBF", "#424242",
                    "#5E5E5E", "#B5B5B5", "#AAAAAA", "#D0D0D0"
                )
                : (
                    "#F5F5F5", "#EDEDED", "#FAFAFA", "#D8D8D8", "#202020", "#565656", "#696969", "#555555", "#E0E0E0",
                    "#C7C7C7", "#5F5F5F", "#777777", "#8A8A8A"
                )
        case .slate:
            return isDark
                ? (
                    "#141C2A", "#1D293C", "#182234", "#2A3B53", "#D2D9E3", "#BCCADA", "#9AAAC0", "#7EB8F6", "#3A5375",
                    "#545E6B", "#63D0A6", "#E6A855", "#F7A072"
                )
                : (
                    "#EFF4FA", "#E4ECF6", "#F7FAFD", "#D4E1F0", "#17243A", "#46576B", "#5B6A7F", "#2563C7", "#D3E0F4",
                    "#B7C8DD", "#238B67", "#A86916", "#C94C4C"
                )
        case .warmLight:
            return (
                "#F5F0E8", "#FFFAF2", "#EEE6D8", "#E9DDCA", "#2C1810", "#664F3D", "#745D45", "#8B4513", "#E8DAD0",
                "#D2BE9D", "#2E7D32", "#E65100", "#C62828"
            )
        case .cartoon:
            return (
                "#FFF6E2", "#FFFDF7", "#FFF0CF", "#FFE4A8", "#1E1A16", "#4A4038", "#786859", "#F0481F", "#FFD3C2",
                "#1E1A16", "#168F55", "#B86E00", "#E5383B"
            )
        case .retro:
            return (
                "#C4C4C4", "#DCDAD4", "#CCCAC4", "#E8E6E0", "#000000", "#2B2B2B", "#454545", "#000080", "#B4B8D8",
                "#7F7F7F", "#005A00", "#7A4A00", "#A00000"
            )
        case .terminal:
            return (
                "#0B120E", "#131E17", "#0F1913", "#213126", "#CDDCCF", "#B6D0BD", "#94B59F", "#4ADE80", "#1F4A2B",
                "#3D5C46", "#4ADE80", "#F2C94C", "#FF6B6B"
            )
        case .brutalist:
            return (
                "#F7F7F2", "#FFFFFF", "#ECEDE7", "#FFE500", "#000000", "#222222", "#555555", "#0047FF", "#FFE500",
                "#000000", "#00A152", "#B86A00", "#FF1F1F"
            )
        case .origami:
            return (
                "#F1EDE5", "#FFFCF5", "#EAE3D8", "#E1D7C7", "#29251F", "#554E45", "#6B6156", "#6252B5", "#DED8F5",
                "#A89D8E", "#2F7D62", "#A95F1E", "#B63E42"
            )
        case .clay:
            return (
                "#F3EBE5", "#FFF8F2", "#EEE0D6", "#E8D7CB", "#382B29", "#5E4945", "#715C56", "#B94F40", "#FFD9D0",
                "#D6C0B2", "#2F8A66", "#A86A10", "#D9443D"
            )
        case .pixel:
            return (
                "#17102E", "#251A43", "#1E1539", "#35245D", "#DCD5EE", "#CBBFE9", "#AB9BCD", "#FF4FA3", "#4B2F8A",
                "#5A46A0", "#3DDC97", "#FFD23F", "#FF5C6C"
            )
        case .notebook:
            return (
                "#F8F3E5", "#FFFCF2", "#F0E8D3", "#E8DDC1", "#2B2A33", "#55525E", "#686473", "#2F4FA8", "#FFF0A8",
                "#77747F", "#3F8F5B", "#A86F00", "#C8362E"
            )
        case .hud:
            return (
                "#080F18", "#101D2B", "#0C1622", "#193047", "#C2DEE4", "#A6CDD8", "#84AABA", "#19D3F3", "#0F3A52",
                "#1F5C75", "#3DEB9A", "#FFB020", "#FF4D5E"
            )
        // Tokyo Night Storm, with metadata lifted from the comment gray for legible text.
        case .storm:
            return (
                "#1C2132", "#272D43", "#22273B", "#343C57", "#D1D8F0", "#BAC7E8", "#9CAACF", "#7AA2F7", "#394B70",
                "#414868", "#9ECE6A", "#E0AF68", "#F7768E"
            )
        case .island:
            return (
                "#000000", "#141414", "#0A0A0A", "#262626", "#D8D8DB", "#BEBEC4", "#9C9CA5", "#F5F5F7", "#2C2C2E",
                "#2A2A2C", "#30D158", "#FF9F0A", "#FF453A"
            )
        case .dusk:
            return (
                "#17131F", "#241D30", "#1D1828", "#332A42", "#DDD5E6", "#C3B6D2", "#A99ABB", "#9B8CF0", "#2A2740",
                "#2E2E38", "#6EDDB0", "#F5B965", "#FF6B6B"
            )
        // Apple system grays and a graphite accent: neutral, like macOS 26 Liquid Glass.
        case .glass:
            return isDark
                ? (
                    "#1C1D20", "#303236", "#26282C", "#3B3D42", "#D7D8DA", "#C3C5CA", "#A9ACB3", "#BDBFC1", "#3A3A3C",
                    "#48484A", "#30D158", "#FF9F0A", "#FF453A"
                )
                : (
                    "#F4F5F7", "#FFFFFF", "#E9EBEF", "#DEE1E6", "#171A1F", "#3E454F", "#424955", "#535557", "#DADCE0",
                    "#7F8691", "#248A3D", "#C93400", "#D70015"
                )
        case .clean:
            return isDark
                ? (
                    "#181918", "#252625", "#202120", "#323330", "#E4E4E4", "#C1C3BC", "#A4A79E", "#B0B0AE", "#2B2B2A",
                    "#303030", "#4CC27A", "#E5A640", "#FF6B6B"
                )
                : (
                    "#F7F7F5", "#FFFFFF", "#EFEFEB", "#E6E7E2", "#111111", "#5C5C5C", "#6B6B6B", "#666664", "#EFEFEE",
                    "#D6D6D3", "#2F8F4E", "#B26A00", "#D93A3A"
                )
        case .eInk:
            return (
                "#FFFFFF", "#FFFFFF", "#F5F5F5", "#E8E8E8", "#000000", "#2B2B2B", "#555555", "#000000", "#D9D9D9",
                "#000000", "#1A1A1A", "#333333", "#000000"
            )
        case .swiss:
            return isDark
                ? (
                    "#111111", "#111111", "#171717", "#252525", "#D8D8D7", "#BCBCB8", "#999995", "#FF3B30", "#2A1412",
                    "#2E2E2E", "#9A9A9A", "#B0B0B0", "#FF3B30"
                )
                : (
                    "#FAFAF7", "#FAFAF7", "#F1F1EC", "#E8E8E2", "#0A0A0A", "#4A4A4A", "#6C6C68", "#E30613", "#FBE4E5",
                    "#D9D9D9", "#555555", "#777777", "#E30613"
                )
        }
    }
    /// Colors are resolved once per theme. Native macOS colors are dynamic and
    /// resolve against the appearance they draw in, so AppKit text, nested
    /// hosting views, and Office materials never pick up a stale Light/Dark
    /// variant from whatever appearance happened to be current when read.
    private static let tokens: [DockThemeID: Tokens] = Dictionary(
        uniqueKeysWithValues: DockThemeID.allCases.map { ($0, Tokens(theme: $0)) })
    private var resolvedTokens: Tokens { Self.tokens[theme]! }
    var windowBackground: Color { resolvedTokens.windowBackground }
    var opaqueBackground: Color { resolvedTokens.opaqueBackground }
    var background: Color { resolvedTokens.background }
    var surface: Color { resolvedTokens.surface }
    var surface2: Color { resolvedTokens.surface2 }
    var surface4: Color { resolvedTokens.surface4 }
    var surface6: Color { surface4.opacity(0.86) }
    var surface8: Color { surface4.opacity(0.72) }
    var onAccent: Color { resolvedTokens.onAccent }
    func color(_ accent: DockAccentColor) -> Color { resolvedTokens.accents[accent.rawValue] }
    /// Solid identity artwork keeps the midtone fill; small text uses contrast-adjusted ink.
    func fill(_ accent: DockAccentColor) -> Color {
        theme == .mono || theme == .eInk ? color(accent) : Color(nsColor: NSColor(hex: accent.hex))
    }
    var info: Color { resolvedTokens.info }
    var merged: Color { resolvedTokens.merged }
    var review: Color { resolvedTokens.review }
    var primaryText: Color { resolvedTokens.primaryText }
    var secondaryText: Color { resolvedTokens.secondaryText }
    var metadataText: Color { resolvedTokens.metadataText }
    var accent: Color { resolvedTokens.accent }
    var selectedFill: Color { resolvedTokens.selectedFill }
    var divider: Color { resolvedTokens.divider }
    var success: Color { resolvedTokens.success }
    var warning: Color { resolvedTokens.warning }
    var destructive: Color { resolvedTokens.destructive }
    /// Rail and session list; tinted skins set them apart from the chat page.
    var sidebarBackground: Color { theme.style.tintedSidebar ? surface2 : background }
    var swatches: [Color] {
        neonHues.isEmpty
            ? [background, selectedFill, primaryText, accent, success]
            : [background, selectedFill, primaryText] + neonHues
    }
    /// Neon skins light card rims, primary fills, and selection with a gradient
    /// from the accent through these hues; empty on every other skin.
    var neonHues: [Color] { [] }
}

private struct Tokens {
    let accents: [Color]
    let windowBackground, opaqueBackground, background, surface, surface2, surface4, primaryText, secondaryText,
        metadataText, accent,
        onAccent, selectedFill, divider, success, warning, destructive, info, merged, review: Color

    init(theme: DockThemeID) {
        let light = DockThemePalette.roles(theme, dark: false)
        let dark = DockThemePalette.roles(theme, dark: true)
        func color(
            _ pick: (DockThemePalette.Roles) -> String, nativeAlpha: CGFloat = 1, nativeLightAlpha: CGFloat? = nil
        ) -> Color {
            func resolved(_ roles: DockThemePalette.Roles, alpha: CGFloat) -> NSColor {
                let value = NSColor(hex: pick(roles))
                return theme.usesNativeMaterial ? value.withAlphaComponent(alpha) : value
            }
            let lightColor = resolved(light, alpha: nativeLightAlpha ?? nativeAlpha)
            let darkColor = resolved(dark, alpha: nativeAlpha)
            switch theme.appearance {
            case .light: return Color(nsColor: lightColor)
            case .dark: return Color(nsColor: darkColor)
            case .system:
                return Color(
                    nsColor: NSColor(name: nil) { appearance in
                        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
                    })
            }
        }
        accents = DockAccentColor.allCases.map { accent in
            color { roles in
                theme == .mono || theme == .eInk ? roles.secondary : accent.hex(on: roles)
            }
        }
        info = accents[DockAccentColor.blue.rawValue]
        merged = accents[DockAccentColor.violet.rawValue]
        review = accents[DockAccentColor.teal.rawValue]
        // Light glass lets the desktop through; 80% is the floor that keeps
        // body text and dividers readable over a black desktop.
        windowBackground = color({ $0.bg }, nativeAlpha: 0.12, nativeLightAlpha: 0.80)
        opaqueBackground = color { $0.bg }
        // Clear so nested page canvases never stack into darker panes; the
        // window tint above is the only layer over the glass.
        background = color({ $0.bg }, nativeAlpha: 0)
        surface = color({ $0.surface }, nativeAlpha: 0.40, nativeLightAlpha: 0.72)
        surface2 = color({ $0.surface2 }, nativeAlpha: 0.32, nativeLightAlpha: 0.62)
        surface4 = color({ $0.surface4 }, nativeAlpha: 0.60, nativeLightAlpha: 0.80)
        primaryText = color { $0.primary }
        secondaryText = color { $0.secondary }
        metadataText = color { $0.metadata }
        accent = color { $0.accent }
        // Label color for filled accent controls: whichever of white/near-black
        // reads better on this theme's accent (a pale accent needs dark text).
        onAccent = color { DockThemePalette.onAccentHex(forAccent: $0.accent) }
        selectedFill = color { $0.selected }
        divider = color { $0.divider }
        success = color { $0.success }
        warning = color { $0.warning }
        destructive = color { $0.destructive }
    }
}

extension Color {
    /// A translucent white frost above the material lifts light controls off the
    /// canvas while the desktop still reads through, like macOS Light glass.
    static let dockLightGlassLift = Color(
        nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? NSColor.white.withAlphaComponent(0.6) : .clear
        })
    static let dockLightGlassEdge = Color(
        nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .aqua
                ? NSColor.black.withAlphaComponent(0.10) : NSColor.white.withAlphaComponent(0.08)
        })
    static let dockGlassHighlight = Color(
        nsColor: NSColor(name: nil) {
            NSColor.white.withAlphaComponent($0.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? 0.70 : 0.24)
        })
    /// Selected glass rows: a soft graphite rim in Light, the bright rim in Dark.
    static let dockGlassSelectionEdge = Color(
        nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .aqua
                ? NSColor.black.withAlphaComponent(0.18) : NSColor(hex: "#D7D8DA").withAlphaComponent(0.75)
        })
}

extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
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
    private var popoverObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, appliesToApplication: Bool = false) {
        self.defaults = defaults
        self.appliesToApplication = appliesToApplication
        defaults.removeObject(forKey: Self.legacyStorageKey)
        selectedThemeID = defaults.string(forKey: Self.storageKey).flatMap(DockThemeID.init(rawValue:)) ?? .glass
        applyToApplication(themeID: selectedThemeID)
        observeSystemAppearance()
        pinPopoverAppearance()
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
        let appearance = Self.nsAppearance(for: themeID)
        if app.appearance?.name != appearance?.name { app.appearance = appearance }
        // A window keeps a forced appearance (e.g. .aqua from a light skin) after
        // the app-level one is cleared, which left System/Glass stuck on a plain
        // light material until relaunch. Re-assert it per window.
        for window in app.windows where window.appearance?.name != appearance?.name { window.appearance = appearance }
    }

    private static func nsAppearance(for themeID: DockThemeID) -> NSAppearance? {
        switch themeID.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Popovers open in their own window, which kept the system (or a previous
    /// skin's) appearance and painted a light material under dark-skin text.
    /// Pin each one to the current skin as it opens.
    private func pinPopoverAppearance() {
        guard appliesToApplication else { return }
        popoverObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.willShowNotification, object: nil, queue: .main
        ) { note in
            // Delivered on the main queue, where the popover lives.
            nonisolated(unsafe) let popover = note.object as? NSPopover
            MainActor.assumeIsolated {
                popover?.appearance = Self.nsAppearance(for: DockThemeRuntime.current)
            }
        }
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

/// Observable so every view body that reads a `Color.dock*` token re-renders on
/// a skin switch. A plain static only refreshed views whose inputs happened to
/// change; the rest kept the old skin until relaunch.
@Observable
final class DockThemeRuntimeState: @unchecked Sendable {
    var current: DockThemeID = .glass
    var revision = 0
}

enum DockThemeRuntime {
    static let state = DockThemeRuntimeState()
    static var current: DockThemeID {
        get { state.current }
        set { state.current = newValue }
    }
    static var revision: Int {
        get { state.revision }
        set { state.revision = newValue }
    }
}

extension Color {
    /// Device pixels contain black corner masks; keep their surrounding canvas black in every skin.
    static var dockDeviceCanvas: Color { .black }
}
