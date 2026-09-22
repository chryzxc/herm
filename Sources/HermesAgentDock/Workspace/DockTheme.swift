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
        switch self { case .nativeMacOS: "Cool navy surfaces with system-aware light and dark appearance."; case .hermesClassic: "Gold identity accents with calm midnight surfaces."; case .ares: "Crimson actions, bronze labels, and a warm operational tone."; case .mono: "A focused grayscale palette with minimal distraction."; case .slate: "Developer-focused blue surfaces with crisp cool contrast."; case .daylight: "Bright surfaces with dark text and clear blue actions."; case .warmLight: "Warm paper surfaces with brown and gold hierarchy."; case .poseidon: "Deep ocean blue with seafoam highlights."; case .sisyphus: "Austere grayscale built for persistent work."; case .charizard: "Burnt orange controls with ember-colored emphasis." }
    }
    var appearance: DockThemeAppearance { self == .nativeMacOS ? .system : (self == .daylight || self == .warmLight ? .light : .dark) }
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
    private var isDark: Bool {
        theme.appearance == .dark ||
        (theme.appearance == .system && NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }
    private var colors: (bg: String, surface: String, surface2: String, surface4: String, primary: String, secondary: String, metadata: String, accent: String, selected: String, divider: String, success: String, warning: String, destructive: String) {
        switch theme {
        case .nativeMacOS: return isDark ? ("#111624", "#131A2A", "#101521", "#1A2131", "#F0F1F5", "#A7AAB5", "#737C8D", "#169BFF", "#1A2131", "#2A3040", "#39C878", "#F2A33B", "#EC5C64") : ("#F4F7FC", "#EEF2F8", "#F8FAFD", "#E2E8F2", "#18202D", "#5F6878", "#7C8697", "#0071D8", "#DFE9F8", "#D3DBE8", "#238636", "#B45309", "#B4232F")
        case .hermesClassic: return isDark ? ("#1A1A2E", "#211F35", "#171728", "#333355", "#FFF8DC", "#C0C0C0", "#8A7A4A", "#FFBF00", "#3A3A55", "#544F67", "#8FBC8F", "#FFD700", "#FF6B6B") : ("#F7F3E8", "#F1E8D3", "#FBF9F2", "#E9DFC6", "#3E321F", "#76664A", "#948261", "#B8860B", "#E8DCC2", "#D7C9A9", "#2E7D32", "#B45309", "#B4232F")
        case .ares: return isDark ? ("#2A1212", "#321719", "#241010", "#5C221D", "#F1E6CF", "#D4B4A9", "#905151", "#DD4A3A", "#692620", "#6E584B", "#7BC96F", "#C7A96B", "#EF5350") : ("#F8EEE8", "#F1DDD3", "#FCF7F4", "#E8C6B8", "#3B201B", "#795A52", "#966C63", "#DD4A3A", "#F0D1C7", "#DAB2A2", "#4CAF50", "#C7A96B", "#EF5350")
        case .mono, .sisyphus: return isDark ? ("#1F1F1F", "#282828", "#181818", "#464646", "#F5F5F5", "#C9C9C9", "#777777", "#AAAAAA", "#505050", "#5E5E5E", "#B5B5B5", "#AAAAAA", "#D0D0D0") : ("#F5F5F5", "#EDEDED", "#FAFAFA", "#E2E2E2", "#202020", "#606060", "#888888", "#555555", "#E0E0E0", "#C7C7C7", "#5F5F5F", "#777777", "#8A8A8A")
        case .slate: return isDark ? ("#151C2F", "#1C2740", "#111827", "#324867", "#C9D1D9", "#AEBBCA", "#5D6672", "#7EB8F6", "#3A5375", "#545E6B", "#63D0A6", "#E6A855", "#F7A072") : ("#EFF4FA", "#E4ECF6", "#F7FAFD", "#D4E1F0", "#17243A", "#536579", "#718095", "#2563C7", "#D3E0F4", "#B7C8DD", "#238B67", "#A86916", "#C94C4C")
        case .daylight: return ("#F8FAFC", "#EEF3FA", "#FFFFFF", "#DBEAFE", "#111827", "#475569", "#64748B", "#2563EB", "#D3E0FB", "#CBD5E1", "#15803D", "#B45309", "#B91C1C")
        case .warmLight: return ("#F5F0E8", "#EEE5D5", "#FBF7EF", "#E8DCC8", "#2C1810", "#6E5743", "#8A735A", "#8B4513", "#E8DAD0", "#D2BE9D", "#2E7D32", "#E65100", "#C62828")
        case .poseidon: return isDark ? ("#0F2440", "#162E4E", "#0B1C33", "#254D73", "#EAF7FF", "#B4D0E2", "#52708A", "#5DB8F5", "#2A587F", "#496884", "#6ED7B0", "#5DB8F5", "#D94F4F") : ("#EDF7FC", "#E0F0F8", "#F7FCFF", "#CDE5F2", "#123047", "#476A80", "#66869B", "#267FB9", "#CBE7F5", "#B8D3E1", "#2E8B69", "#B4771D", "#C74747")
        case .charizard: return isDark ? ("#2B160E", "#351B11", "#1E0F09", "#4A1B07", "#FFF0D4", "#D9B58B", "#826144", "#F29C38", "#5A260D", "#7B593A", "#6BCB77", "#F29C38", "#EF5350") : ("#FFF5E9", "#F8E8D0", "#FFFAF3", "#F5D2A8", "#3A2114", "#765741", "#96704F", "#C75B1D", "#F5D2A8", "#D8B487", "#2E7D32", "#F29C38", "#C62828")
        }
    }
    private func color(_ value: String) -> Color { Color(hex: value) }
    var background: Color { color(colors.bg) }; var surface: Color { color(colors.surface) }; var surface2: Color { color(colors.surface2) }; var surface4: Color { color(colors.surface4) }
    var surface6: Color { color(colors.surface4).opacity(0.86) }; var surface8: Color { color(colors.surface4).opacity(0.72) }
    var primaryText: Color { color(colors.primary) }; var secondaryText: Color { color(colors.secondary) }; var metadataText: Color { color(colors.metadata) }; var accent: Color { color(colors.accent) }; var selectedFill: Color { color(colors.selected) }; var divider: Color { color(colors.divider) }; var success: Color { color(colors.success) }; var warning: Color { color(colors.warning) }; var destructive: Color { color(colors.destructive) }
    var swatches: [Color] { [background, selectedFill, primaryText, accent, success] }
}

private extension Color {
    init(hex: String) {
        var value: UInt64 = 0; Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

@MainActor
final class DockThemeStore: ObservableObject {
    static let storageKey = "hermes.dock.theme.v1"
    static let legacyStorageKey = "hermes.sidebar.brand-concept.v1"
    @Published var selectedThemeID: DockThemeID { didSet { defaults.set(selectedThemeID.rawValue, forKey: Self.storageKey); DockThemeRuntime.current = selectedThemeID } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.removeObject(forKey: Self.legacyStorageKey)
        selectedThemeID = defaults.string(forKey: Self.storageKey).flatMap(DockThemeID.init(rawValue:)) ?? .nativeMacOS
        DockThemeRuntime.current = selectedThemeID
    }
    var palette: DockThemePalette { DockThemePalette(theme: selectedThemeID) }
}

enum DockThemeRuntime {
    nonisolated(unsafe) static var current: DockThemeID = .nativeMacOS
}
