import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct DockThemeImportTests {
    private let json = """
        {
          "version": 1, "id": "glass", "name": "Test palette", "appearance": "light",
          "css": "body { background: url(example.png) }",
          "colors": {
            "canvas": "#eee8dd", "surface": "#f6f2e9", "sidebar": "#e0d8cf",
            "text": "#eee8dd", "textMuted": "#4a423a", "accent": "#523a49"
          },
          "variants": { "dark": { "canvas": "oklch(0.25 0 0)", "text": "#eee" } }
        }
        """

    @Test func importsBothAppearancesAndUsesReadableInk() throws {
        let theme = try DockImportedTheme(json: json)
        let palette = DockThemePalette(theme: .imported(theme))
        #expect(theme.appearance == .system)
        #expect(DockThemeID.imported(theme).style == DockThemeID.clean.style)
        #expect(DockThemeID.imported(theme).hermesSkinID == nil)
        #expect(DockThemeID.glass.originLabel == "Built-in")
        #expect(DockThemeID.imported(theme).originLabel == "Imported")
        #expect(theme.conversationWallpaper == nil)
        try expectColor(palette.background, appearance: .aqua, hex: "#eee8dd")
        try expectColor(palette.sidebarBackground, appearance: .aqua, hex: "#e0d8cf")
        try expectColor(palette.primaryText, appearance: .aqua, hex: "#1f2025")
        try expectColor(palette.accent, appearance: .aqua, hex: "#523a49")
        try expectColor(palette.background, appearance: .darkAqua, hex: "#222222")
        try expectColor(palette.background, appearance: .vibrantDark, hex: "#000000")
    }

    @Test func conversationWallpaperSurvivesImportAndReload() throws {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg'><style>@keyframes tw{100%{opacity:0}}</style></svg>"
        let bytes = Data(svg.utf8)
        let selector = #"[data-workspace-area="conversation"]"#
        var file = try JSONDecoder().decode(DockT3ThemeFile.self, from: Data(json.utf8))
        for uri in [
            "data:image/svg+xml," + svg.replacingOccurrences(of: "%", with: "%25"),
            "data:image/svg+xml;base64," + bytes.base64EncodedString(),
        ] {
            file.css = #"\#(selector){background:linear-gradient(transparent,black),url("\#(uri)") center/cover}"#
            let theme = try DockImportedTheme(definition: file)
            #expect(theme.conversationWallpaper == bytes)
            let saved = try JSONEncoder().encode(theme.definition)
            let reloaded = try DockImportedTheme(json: String(decoding: saved, as: UTF8.self))
            #expect(reloaded.conversationWallpaper == bytes)
        }
        for css in [
            #"body{background:url('data:image/svg+xml,<svg/>')}"#,
            #"\#(selector){background-image:url('https://example.com/a.svg')}"#,
            #"\#(selector){background-image:url('data:image/svg+xml;base64,!')}"#,
        ] {
            file.css = css
            #expect(try DockImportedTheme(definition: file).conversationWallpaper == nil)
        }
    }

    @Test func validatesVersionAndRejectsNonColorValues() throws {
        #expect(throws: DockThemeImportError.invalidFile) { try DockImportedTheme(json: "[]") }
        #expect(throws: DockThemeImportError.unsupportedVersion) {
            try DockImportedTheme(json: json.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2"))
        }
        #expect(throws: DockThemeImportError.unsupportedColor) {
            try DockImportedTheme(json: json.replacingOccurrences(of: "#f6f2e9", with: "url(example.png)"))
        }
        #expect(try DockThemePalette.importedHex("oklch(0.627955 0.257683 29.234)") == "#ff0000")
    }

    @Test func savesMultiplePalettesReimportsAndRemovesTheActiveSkin() throws {
        let suite = "DockThemeImportTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DockThemeStore(defaults: defaults)

        try store.importTheme(json: json)
        #expect(store.selectedThemeID.id == "t3:glass")
        #expect(store.availableThemes.contains(.glass))

        try store.importTheme(json: json.replacingOccurrences(of: "\"glass\"", with: "\"second\""))
        let updated = json.replacingOccurrences(of: "Test palette", with: "Updated palette")
        try store.importTheme(json: updated)
        #expect(throws: DockThemeImportError.invalidFile) { try store.importTheme(json: "{") }
        let restored = DockThemeStore(defaults: defaults)
        #expect(restored.importedThemes.map(\.id) == ["t3:glass", "t3:second"])
        #expect(restored.selectedThemeID.title == "Updated palette")
        #expect(restored.selectedThemeID == store.selectedThemeID)
        try restored.removeImportedTheme(restored.selectedThemeID)
        #expect(DockThemeStore(defaults: defaults).selectedThemeID == .glass)
        #expect(DockThemeStore(defaults: defaults).importedThemes.map(\.id) == ["t3:second"])
    }

    private func expectColor(_ color: Color, appearance: NSAppearance.Name, hex: String) throws {
        var resolved: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        let actual = try #require(resolved)
        let expected = NSColor(hex: hex)
        #expect(abs(actual.redComponent - expected.redComponent) < 0.004)
        #expect(abs(actual.greenComponent - expected.greenComponent) < 0.004)
        #expect(abs(actual.blueComponent - expected.blueComponent) < 0.004)
    }
}
