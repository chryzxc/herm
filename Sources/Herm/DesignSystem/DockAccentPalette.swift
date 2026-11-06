import AppKit
import SwiftUI

/// Approved solid reference palette. Change color families here, never in feature views.
enum DockAccentColor: Int, CaseIterable {
    case teal, amber, violet, coral, blue, orange, pink, green, cyan, indigo, tangerine

    var hex: String {
        switch self {
        case .teal: "#50B8A6"
        case .amber: "#E8AF36"
        case .violet: "#8955F5"
        case .coral: "#E86372"
        case .blue: "#387FF2"
        case .orange: "#FA9D29"
        case .pink: "#D85BA4"
        case .green: "#55AD70"
        case .cyan: "#38AFC8"
        case .indigo: "#6957E8"
        case .tangerine: "#F97029"
        }
    }

    /// Contrast-safe text and small symbols.
    var color: Color { DockThemePalette(theme: DockThemeRuntime.current).color(self) }
    /// Solid artwork and data marks retain the approved color in Light and Dark.
    var fill: Color { DockThemePalette(theme: DockThemeRuntime.current).fill(self) }

    /// Office signals sit on dark signage even in a light workspace.
    var signageColor: NSColor {
        var result = NSColor.gray
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            result = NSColor(DockThemePalette(theme: .clean).fill(self)).usingColorSpace(.sRGB) ?? .gray
        }
        return result
    }

    static func identity(for id: String) -> Self {
        let seed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8
            .reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return allCases[Int(seed % UInt64(allCases.count))]
    }

    /// Keep the reference hue, adjusting only as far as compact text contrast needs.
    func hex(on roles: DockThemePalette.Roles) -> String {
        let surfaces = [roles.bg, roles.surface, roles.surface2]
        let target: CGFloat = DockThemePalette.onAccentHex(forAccent: roles.bg) == "#111111" ? 0 : 1
        let base = NSColor(hex: hex).usingColorSpace(.sRGB)!
        for step in 0...50 {
            let amount = CGFloat(step) / 50
            let channels = [base.redComponent, base.greenComponent, base.blueComponent]
                .map { Int(($0 + (target - $0) * amount) * 255) }
            let candidate = String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
            let ink = DockThemePalette.luminance(candidate)
            if surfaces.allSatisfy({ surface in
                let paper = DockThemePalette.luminance(surface)
                return (max(ink, paper) + 0.05) / (min(ink, paper) + 0.05) >= 4.5
            }) {
                return candidate
            }
        }
        return target == 0 ? "#111111" : "#FFFFFF"
    }
}

/// Category identity is independent of health, urgency, and the selected skin.
enum DockCategoryTone: CaseIterable {
    case event, reminder, automation, task, integration, review, modified, renamed

    var accent: DockAccentColor {
        switch self {
        case .event: .blue
        case .reminder: .amber
        case .automation, .review, .renamed: .violet
        case .task: .teal
        case .integration, .modified: .cyan
        }
    }

    var color: Color { accent.color }
    var fill: Color { accent.fill }
}
