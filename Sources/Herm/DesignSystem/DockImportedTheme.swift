import Foundation

struct DockT3ThemeFile: Codable, Hashable, Sendable {
    struct Colors: Codable, Hashable, Sendable {
        var canvas, chrome, surface, surfaceRaised, surfaceOverlay, sidebar: String?
        var text, textMuted, secondaryLabel, accent, border, sidebarRowSelected, accentSurface: String?

        var isEmpty: Bool { self == Self() }
    }

    struct Variants: Codable, Hashable, Sendable {
        let light, dark: Colors?
    }

    let version: Int
    let id, name: String
    let appearance: DockThemeAppearance
    let colors: Colors
    let variants: Variants?
    var css: String?
}

enum DockThemeImportError: LocalizedError {
    case tooLarge, invalidFile, unsupportedVersion, missingColors, unsupportedColor, unusableContrast

    var errorDescription: String? {
        switch self {
        case .tooLarge: "Choose a theme JSON smaller than 256 KB."
        case .invalidFile: "Copy valid T3Code theme JSON, then try again."
        case .unsupportedVersion: "Herm supports T3Code theme JSON version 1."
        case .missingColors: "This theme contains no colors Herm can import."
        case .unsupportedColor: "Theme colors must use opaque hex or OKLCH values."
        case .unusableContrast: "This theme needs more contrast between its surfaces and text."
        }
    }
}

struct DockImportedTheme: Hashable, Sendable {
    let definition: DockT3ThemeFile
    let appearance: DockThemeAppearance
    let tokens: DockThemeTokens
    let conversationWallpaper: Data?

    init(json: String) throws {
        guard json.utf8.count <= 256 * 1024 else { throw DockThemeImportError.tooLarge }
        guard let definition = try? JSONDecoder().decode(DockT3ThemeFile.self, from: Data(json.utf8)) else {
            throw DockThemeImportError.invalidFile
        }
        try self.init(definition: definition)
    }

    init(definition: DockT3ThemeFile) throws {
        guard definition.version == 1 else { throw DockThemeImportError.unsupportedVersion }
        let name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard definition.id.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,47}/) != nil, !name.isEmpty, name.utf16.count <= 48,
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            definition.appearance != .system
        else { throw DockThemeImportError.invalidFile }
        let isDark = definition.appearance == .dark
        let alternate = isDark ? definition.variants?.light : definition.variants?.dark
        guard !definition.colors.isEmpty || alternate?.isEmpty == false else {
            throw DockThemeImportError.missingColors
        }
        let base = try Self.roles(definition.colors, dark: isDark)
        let other = try alternate.map { try Self.roles($0, dark: !isDark) } ?? base
        conversationWallpaper = definition.css.flatMap(Self.wallpaper)
        self.definition = DockT3ThemeFile(
            version: definition.version, id: definition.id, name: name, appearance: definition.appearance,
            colors: definition.colors, variants: definition.variants,
            css: conversationWallpaper == nil ? nil : definition.css)
        appearance = alternate == nil ? definition.appearance : .system
        tokens = DockThemeTokens(
            light: isDark ? other : base, dark: isDark ? base : other, appearance: appearance,
            usesNativeMaterial: false)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.definition == rhs.definition }
    func hash(into hasher: inout Hasher) { hasher.combine(definition) }

    /// Extract a quoted SVG image from a conversation background. The host document
    /// only receives the image bytes, so T3 selectors never style Herm controls.
    private static func wallpaper(in css: String) -> Data? {
        let declaration =
            #"(?:^|})\s*\[data-workspace-area\s*=\s*(?:"conversation"|'conversation')\s*\]\s*\{(?:\s*[-\w]+\s*:[^;{}]*;)*?\s*background(?:-image)?\s*:[^;{}]*?url\(\s*["']"#
        guard let start = css.range(of: declaration, options: [.regularExpression, .caseInsensitive]),
            let quote = css[start].last
        else { return nil }
        let tail = css[start.upperBound...]
        guard let end = tail.firstIndex(of: quote),
            tail[tail.index(after: end)...].drop(while: { $0.isWhitespace }).first == ")",
            let comma = tail[..<end].firstIndex(of: ",")
        else { return nil }
        let header = tail[..<comma].lowercased().components(separatedBy: ";")
        guard header.first == "data:image/svg+xml" else { return nil }
        let payload = String(tail[tail.index(after: comma)..<end])
        guard !payload.isEmpty else { return nil }
        if header.contains("base64") { return Data(base64Encoded: payload) }
        return payload.removingPercentEncoding.map { Data($0.utf8) }
    }

    private static func roles(_ colors: DockT3ThemeFile.Colors, dark: Bool) throws -> DockThemePalette.Roles {
        let defaults = DockThemePalette.baseRoles(.clean, dark: dark)
        var roles = defaults
        let canvas = try (colors.canvas ?? colors.chrome).map(DockThemePalette.importedHex)
        roles.bg = canvas ?? defaults.bg
        roles.surface = try colors.surface.map(DockThemePalette.importedHex) ?? canvas ?? defaults.surface
        roles.surface2 =
            try (colors.sidebar ?? colors.surfaceRaised).map(DockThemePalette.importedHex) ?? canvas
            ?? defaults.surface2
        roles.surface4 =
            try (colors.surfaceRaised ?? colors.surfaceOverlay).map(DockThemePalette.importedHex) ?? canvas
            ?? defaults.surface4
        roles.selected =
            try (colors.sidebarRowSelected ?? colors.accentSurface).map(DockThemePalette.importedHex) ?? canvas
            ?? defaults.selected
        roles.divider = try colors.border.map(DockThemePalette.importedHex) ?? defaults.divider
        let surfaces = [roles.bg, roles.surface, roles.surface2, roles.surface4, roles.selected]
        roles.primary = try DockThemePalette.importedInk(colors.text, fallback: defaults.primary, over: surfaces)
        roles.secondary = try DockThemePalette.importedInk(
            colors.textMuted ?? defaults.secondary, fallback: roles.primary, over: surfaces)
        roles.metadata = try DockThemePalette.importedInk(
            colors.secondaryLabel ?? colors.textMuted ?? defaults.metadata, fallback: roles.secondary, over: surfaces)
        roles.accent = try DockThemePalette.importedInk(
            colors.accent ?? defaults.accent, fallback: roles.primary, over: surfaces)
        return roles
    }
}
