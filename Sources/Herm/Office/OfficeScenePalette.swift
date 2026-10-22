import AppKit
import SwiftUI

/// 3D office materials for the active Dock theme. Plaster, floors and ground
/// take the theme's base hue; furniture keeps one honey-oak studio set in
/// every theme. Dark themes dim the studio's materials; light and sky follow
/// the local clock (`OfficeDaylight`). Robots stay
/// white in every theme so they remain the visual focus.
struct OfficeScenePalette: Equatable {
    /// Interaction markers share the workspace blue, resolved for dark scene signage.
    static var interactionBeacon: NSColor { DockAccentColor.blue.signageColor }

    let theme: DockThemeID
    let isDark: Bool
    let background: NSColor
    let plaster: NSColor
    let trim: NSColor
    let floor: NSColor
    let roomFloor: NSColor
    let wood: NSColor
    let frame: NSColor
    let cork: NSColor
    let paper: NSColor
    let fabric: NSColor
    let coral: NSColor
    let leaf: NSColor
    let lawn: NSColor
    let steel: NSColor
    let signInk: NSColor
    let lamp: NSColor
    let neon: NSColor
    let neonAlt: NSColor
    let stone: NSColor
    let gravel: NSColor
    let soil: NSColor
    let water: NSColor
    let windowView: NSColor
    let glass: NSColor
    let idleScreen: NSColor
    let activeScreen: NSColor
    /// Soft glow color for lamp halos and floor light pools.
    let glowPool: NSColor

    static func == (a: Self, b: Self) -> Bool { a.theme == b.theme && a.isDark == b.isDark }

    /// The palette for the running theme. `isDark` resolves the Native macOS
    /// theme, which follows the system appearance.
    static func current(isDark: Bool? = nil) -> OfficeScenePalette {
        let theme = DockThemeRuntime.current
        let dark: Bool
        switch theme.appearance {
        case .dark: dark = true
        case .light: dark = false
        case .system: dark = isDark ?? ((NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
        return OfficeScenePalette(theme: theme, isDark: dark)
    }

    init(theme: DockThemeID, isDark: Bool) {
        self.theme = theme
        self.isDark = isDark
        // DockThemePalette resolves the system theme from the drawing
        // appearance, so read it under the appearance being rendered.
        var t: DockThemePalette.Resolved!
        NSAppearance(named: isDark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            t = DockThemePalette(theme: theme).resolved
        }
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let rgb = { (r: CGFloat, g: CGFloat, b: CGFloat) in NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        let warmLamp = rgb(1.0, 0.86, 0.66)
        // The theme's base colour sets the shell (plaster, floors, ground) at
        // fixed lightness, so every theme keeps the same contrast and only the
        // hue shifts. Furniture stays one honey-oak set; the accent tints glass,
        // neon and screens. Dark themes dim the materials; light follows the clock.
        let honey = rgb(0.86, 0.66, 0.45), cream = rgb(0.97, 0.94, 0.90)
        let base = t.surface4
        if isDark {
            background = mix(t.bg, black, 0.35)
            plaster = tone(base, brightness: 0.68, saturation: 0.3, cap: 0.2)
            trim = mix(tone(base, brightness: 0.19, saturation: 0.4, cap: 0.3), black, 0.1)
            floor = tone(base, brightness: 0.56, saturation: 0.25, cap: 0.16)
            roomFloor = tone(base, brightness: 0.58, saturation: 0.45, cap: 0.28)
            wood = mix(honey, black, 0.3)
            frame = mix(honey, black, 0.22)
            cork = rgb(0.58, 0.43, 0.33)
            paper = mix(cream, black, 0.1)
            fabric = mix(mix(rgb(0.58, 0.52, 0.80), t.accent, 0.3), black, 0.1)
            coral = rgb(0.93, 0.58, 0.48)
            leaf = rgb(0.42, 0.62, 0.42)
            lawn = mix(tone(base, brightness: 0.3, saturation: 0.5, cap: 0.35), t.success, 0.18)
            steel = mix(rgb(0.55, 0.54, 0.58), t.surface4, 0.3)
            signInk = mix(t.bg, black, 0.45)
            lamp = warmLamp
            neon = mix(t.accent, white, 0.15)
            neonAlt = mix(honey, black, 0.15)
            stone = tone(base, brightness: 0.38, saturation: 0.35, cap: 0.2)
            gravel = tone(base, brightness: 0.3, saturation: 0.35, cap: 0.2)
            soil = mix(t.bg, black, 0.4)
            water = mix(t.accent, t.bg, 0.5)
            windowView = mix(t.bg, t.accent, 0.18)
            glass = mix(t.accent, white, 0.5).withAlphaComponent(0.12)
            idleScreen = mix(t.bg, black, 0.2)
            activeScreen = mix(t.accent, white, 0.35)
            glowPool = rgb(1.0, 0.74, 0.46)
        } else {
            background = tone(base, brightness: 0.93, saturation: 0.9, cap: 0.14)
            plaster = tone(base, brightness: 0.97, saturation: 0.6, cap: 0.1)
            trim = tone(base, brightness: 0.33, saturation: 0.5, cap: 0.2)
            floor = tone(base, brightness: 0.92, saturation: 0.6, cap: 0.1)
            roomFloor = tone(base, brightness: 0.9, saturation: 1, cap: 0.18)
            wood = honey
            frame = mix(honey, white, 0.08)
            cork = rgb(0.80, 0.59, 0.43)
            paper = rgb(0.99, 0.97, 0.94)
            fabric = mix(rgb(0.62, 0.55, 0.85), t.accent, 0.3)
            coral = rgb(0.95, 0.60, 0.48)
            leaf = rgb(0.47, 0.64, 0.42)
            lawn = mix(t.surface4, t.success, 0.3)
            steel = rgb(0.74, 0.72, 0.76)
            signInk = mix(t.primary, black, 0.2)
            lamp = rgb(1.0, 0.96, 0.88)
            neon = t.accent
            neonAlt = honey
            stone = mix(t.surface4, t.primary, 0.08)
            gravel = mix(t.surface4, t.primary, 0.2)
            soil = mix(t.primary, t.surface4, 0.5)
            water = mix(t.accent, white, 0.4)
            windowView = mix(t.accent, white, 0.75)
            glass = mix(t.accent, white, 0.7).withAlphaComponent(0.16)
            idleScreen = mix(t.primary, t.surface4, 0.3)
            activeScreen = mix(t.accent, white, 0.35)
            glowPool = rgb(1.0, 0.86, 0.62)
        }
    }
}

extension DockThemePalette {
    /// sRGB colors for AppKit and RealityKit materials.
    struct Resolved {
        let bg, surface, surface2, surface4, primary, secondary, accent, selected, success: NSColor
    }

    var resolved: Resolved {
        func ns(_ color: Color) -> NSColor { NSColor(color).usingColorSpace(.sRGB) ?? .gray }
        return Resolved(bg: ns(background), surface: ns(surface), surface2: ns(surface2), surface4: ns(surface4),
                        primary: ns(primaryText), secondary: ns(secondaryText), accent: ns(accent),
                        selected: ns(selectedFill), success: ns(success))
    }
}

/// `base`'s hue at a fixed brightness, with its saturation scaled and capped
/// so strongly coloured themes tint the shell without flooding it.
private func tone(_ base: NSColor, brightness: CGFloat, saturation: CGFloat, cap: CGFloat) -> NSColor {
    let c = base.usingColorSpace(.sRGB) ?? base
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    let tinted = NSColor(colorSpace: .sRGB, hue: h, saturation: min(cap, s * saturation), brightness: brightness, alpha: 1)
    return tinted.usingColorSpace(.sRGB) ?? tinted
}

private func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    let a = a.usingColorSpace(.sRGB) ?? a, b = b.usingColorSpace(.sRGB) ?? b
    return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                   green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                   blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                   alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t)
}
