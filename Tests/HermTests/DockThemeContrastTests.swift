import AppKit
import SwiftUI
import Testing
@testable import Herm

/// Audits every theme's palette so text and icons stay visible on the
/// surfaces they sit on. Ratios are WCAG contrast.
@MainActor
struct DockThemeContrastTests {
    private func resolve(_ color: Color, dark: Bool) -> NSColor {
        var out = NSColor.black
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            out = (NSColor(color).usingColorSpace(.sRGB) ?? .black).withAlphaComponent(1)
        }
        return out
    }
    private func lum(_ c: NSColor) -> Double {
        func lin(_ v: CGFloat) -> Double { let d = Double(v); return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
    private func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let x = lum(a), y = lum(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func failures() -> [String] { MainActor.assumeIsolated { DockThemeContrastTests().audit() } }

    func audit() -> [String] {
        var out: [String] = []
        for theme in DockThemeID.allCases {
            let modes: [Bool] = switch theme.appearance { case .light: [false]; case .dark: [true]; case .system: [false, true] }
            for dark in modes {
                let p = DockThemePalette(theme: theme)
                let tag = "\(theme.rawValue)/\(dark ? "dark" : "light")"
                func c(_ x: Color) -> NSColor { resolve(x, dark: dark) }
                let surfaces: [(String, Color)] = [("bg", p.background), ("surface", p.surface), ("surface2", p.surface2), ("surface4", p.surface4), ("selected", p.selectedFill)]
                func check(_ name: String, _ fg: Color, _ bgs: [(String, Color)], min: Double) {
                    for (bn, bg) in bgs {
                        let r = ratio(c(fg), c(bg))
                        if r < min { out.append("\(tag) \(name) on \(bn) = \(String(format: "%.2f", r)) < \(min)") }
                    }
                }
                check("primary", p.primaryText, surfaces, min: 4.5)
                check("secondary", p.secondaryText, Array(surfaces.prefix(4)), min: 5.0)
                check("secondary", p.secondaryText, [surfaces[4]], min: 4.5)
                check("metadata", p.metadataText, Array(surfaces.prefix(3)), min: 4.5)
                check("accent", p.accent, Array(surfaces.prefix(2)), min: 3.0)
                check("info", p.info, Array(surfaces.prefix(3)), min: 4.5)
                check("merged", p.merged, Array(surfaces.prefix(3)), min: 4.5)
                check("success", p.success, Array(surfaces.prefix(2)), min: 3.0)
                check("warning", p.warning, Array(surfaces.prefix(2)), min: 3.0)
                check("destructive", p.destructive, Array(surfaces.prefix(2)), min: 3.0)
                check("onAccent", p.onAccent, [("accent", p.accent)], min: 3.5)
                // Primary buttons keep themed text over a tonal control fill.
                for opacity in [0.14, 0.24, 0.30] {
                    for tint in [p.accent, p.destructive] {
                        let base = c(p.background), overlay = c(tint)
                        let fill = NSColor(
                            red: base.redComponent * (1 - opacity) + overlay.redComponent * opacity,
                            green: base.greenComponent * (1 - opacity) + overlay.greenComponent * opacity,
                            blue: base.blueComponent * (1 - opacity) + overlay.blueComponent * opacity,
                            alpha: 1
                        )
                        let r = ratio(c(p.primaryText), fill)
                        if r < 4.5 { out.append("\(tag) primary button at \(opacity) = \(String(format: "%.2f", r)) < 4.5") }
                    }
                }
                check("divider", p.divider, [("bg", p.background)], min: 1.3)
            }
        }
        return out
    }

    @Test func everyThemeKeepsTextAndIconsVisible() {
        let failures = audit()
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
}
