import AppKit
import SwiftUI
import Testing

@testable import Herm

/// Audits every theme's palette so text and icons stay visible on the
/// surfaces they sit on. Ratios are WCAG contrast.
@MainActor
struct DockThemeContrastTests {
    private func resolve(_ color: Color, dark: Bool, opaque: Bool = true) -> NSColor {
        var out = NSColor.black
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return opaque ? out.withAlphaComponent(1) : out
    }
    private func lum(_ c: NSColor) -> Double {
        func lin(_ v: CGFloat) -> Double {
            let d = Double(v)
            return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
    private func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let x = lum(a)
        let y = lum(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test func buildBadgeTextContrastsWithTintedToolbar() {
        for theme in DockThemeID.allCases {
            let palette = DockThemePalette(theme: theme)
            for dark in [false, true] {
                let background = resolve(palette.sidebarBackground, dark: dark)
                for accent in [DockAccentColor.violet, .blue] {
                    let tint = resolve(palette.fill(accent), dark: dark)
                    let pill = NSColor(
                        srgbRed: background.redComponent * 0.86 + tint.redComponent * 0.14,
                        green: background.greenComponent * 0.86 + tint.greenComponent * 0.14,
                        blue: background.blueComponent * 0.86 + tint.blueComponent * 0.14, alpha: 1)
                    #expect(ratio(resolve(palette.primaryText, dark: dark), pill) >= 4.5, "\(theme) \(accent)")
                }
            }
        }
    }

    static func failures() -> [String] { MainActor.assumeIsolated { DockThemeContrastTests().audit() } }

    func audit() -> [String] {
        var out: [String] = []
        for theme in DockThemeID.allCases {
            let modes: [Bool] =
                switch theme.appearance {
                case .light: [false]
                case .dark: [true]
                case .system: [false, true]
                }
            for dark in modes {
                let p = DockThemePalette(theme: theme)
                let tag = "\(theme.rawValue)/\(dark ? "dark" : "light")"
                func c(_ x: Color) -> NSColor { resolve(x, dark: dark) }
                let surfaces: [(String, Color)] = [
                    ("bg", p.background), ("surface", p.surface), ("surface2", p.surface2), ("surface4", p.surface4),
                    ("selected", p.selectedFill),
                ]
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
                for accent in DockAccentColor.allCases {
                    check("family/\(accent)", p.color(accent), Array(surfaces.prefix(3)), min: 4.5)
                }
                for tone in DockStatusTone.allCases {
                    let saved = DockThemeRuntime.current
                    DockThemeRuntime.current = theme
                    check("status/\(tone)", tone.color, Array(surfaces.prefix(3)), min: 4.5)
                    DockThemeRuntime.current = saved
                }
                check("success", p.success, Array(surfaces.prefix(2)), min: 3.0)
                check("warning", p.warning, Array(surfaces.prefix(2)), min: 3.0)
                check("destructive", p.destructive, Array(surfaces.prefix(2)), min: 3.0)
                check("onAccent", p.onAccent, [("accent", p.accent)], min: 3.5)
                // Primary buttons keep themed text over a tonal control fill.
                for opacity in [0.14, 0.24, 0.30] {
                    for tint in [p.accent, p.destructive] {
                        let base = c(p.background)
                        let overlay = c(tint)
                        let fill = NSColor(
                            red: base.redComponent * (1 - opacity) + overlay.redComponent * opacity,
                            green: base.greenComponent * (1 - opacity) + overlay.greenComponent * opacity,
                            blue: base.blueComponent * (1 - opacity) + overlay.blueComponent * opacity,
                            alpha: 1
                        )
                        let r = ratio(c(p.primaryText), fill)
                        if r < 4.5 {
                            out.append("\(tag) primary button at \(opacity) = \(String(format: "%.2f", r)) < 4.5")
                        }
                    }
                }
                check("divider", p.divider, [("bg", p.background)], min: 1.3)
            }
        }
        return out
    }

    @Test func lightGlassKeepsContrastOverBrightAndDarkBackdrops() {
        let saved = DockThemeRuntime.current
        DockThemeRuntime.current = .glass
        defer { DockThemeRuntime.current = saved }
        let palette = DockThemePalette(theme: .glass)
        func composite(_ foreground: Color, over background: NSColor) -> NSColor {
            let ink = resolve(foreground, dark: false, opaque: false)
            let alpha = ink.alphaComponent
            return NSColor(
                srgbRed: ink.redComponent * alpha + background.redComponent * (1 - alpha),
                green: ink.greenComponent * alpha + background.greenComponent * (1 - alpha),
                blue: ink.blueComponent * alpha + background.blueComponent * (1 - alpha), alpha: 1)
        }
        for backdrop in [NSColor.black, .white, NSColor(hex: "#214FC0"), NSColor(hex: "#ECA954")] {
            let canvas = composite(palette.windowBackground, over: backdrop.usingColorSpace(.sRGB)!)
            let control = composite(Color.dockLightGlassLift, over: canvas)
            for surface in [canvas, control] {
                for ink in [palette.primaryText, palette.secondaryText, palette.metadataText] {
                    #expect(ratio(composite(ink, over: surface), surface) >= 4.5)
                }
                #expect(ratio(composite(Color.dockMarkdownText, over: surface), surface) >= 7)
            }
            #expect(ratio(composite(Color.dockBorderLight, over: canvas), canvas) >= 1.25)
        }
    }

    @Test func presentationCanvasAndLightGlassSurfacesDoNotInheritBackdropColors() {
        for theme in DockThemeID.allCases {
            let palette = DockThemePalette(theme: theme)
            for dark in [false, true] {
                let canvas = resolve(palette.opaqueBackground, dark: dark, opaque: false)
                let reference = resolve(palette.background, dark: dark)
                #expect(canvas.alphaComponent == 1)
                #expect(abs(canvas.redComponent - reference.redComponent) < 0.001)
                #expect(abs(canvas.greenComponent - reference.greenComponent) < 0.001)
                #expect(abs(canvas.blueComponent - reference.blueComponent) < 0.001)
            }
        }
        let glass = DockThemePalette(theme: .glass)
        // Light glass lets the desktop through, but bodies stay mostly white.
        for surface in [glass.surface, glass.surface2, glass.surface4, Color.dockLightGlassLift] {
            #expect(resolve(surface, dark: false, opaque: false).alphaComponent >= 0.6)
        }
    }

    @Test func activeIconsHaveDistinctFilledArtwork() throws {
        for icon in Ph.allCases {
            let filled = try #require(icon.fillPath, "Missing active artwork: \(icon)")
            #expect(!filled.isEmpty)
        }
        for icon in [Ph.pushPin, .cardsThree, .sidebarSimple, .files, .checkSquare] {
            #expect(icon.fillPath != icon.regularPath)
        }
    }

    @Test func neutralSkinsKeepNeutralInteractionAndSelection() {
        for theme in [DockThemeID.clean, .glass, .mono, .eInk] {
            let palette = DockThemePalette(theme: theme)
            for dark in [false, true] {
                for token in [palette.accent, palette.selectedFill] {
                    let color = resolve(token, dark: dark)
                    #expect(abs(color.blueComponent - color.redComponent) < 0.025)
                    #expect(abs(color.greenComponent - color.redComponent) < 0.025)
                }
            }
        }
    }

    @Test func liveActivityUsesTheSharedWorkingTone() {
        #expect(DockActivityState.running.color == DockStatusTone.working.color)
        #expect(DockActivityState.clarification.color == DockStatusTone.working.color)
        #expect(SessionAttentionDot.activity.color == DockStatusTone.working.color)
    }

    @Test func characterSkinsKeepTheirOwnInteractionHue() {
        let lavender = resolve(DockThemePalette(theme: .dusk).accent, dark: true)
        #expect(lavender.blueComponent > lavender.redComponent)
        #expect(lavender.redComponent > lavender.greenComponent)
        let terminal = resolve(DockThemePalette(theme: .terminal).accent, dark: true)
        #expect(terminal.greenComponent > terminal.blueComponent)
        #expect(terminal.greenComponent > terminal.redComponent)
        let warm = resolve(DockThemePalette(theme: .warmLight).accent, dark: false)
        #expect(warm.redComponent > warm.blueComponent)
    }

    @Test func approvedSolidFillsDoNotChangeBetweenLightAndDark() {
        let approved: [DockAccentColor: String] = [
            .teal: "#50B8A6", .orange: "#FA9D29",
            .indigo: "#6957E8", .violet: "#8955F5", .blue: "#387FF2", .tangerine: "#F97029",
        ]
        for (family, hex) in approved { #expect(family.hex == hex) }
        for family in DockAccentColor.allCases {
            let expected = NSColor(hex: family.hex).usingColorSpace(.sRGB)!
            for theme in DockThemeID.allCases {
                for dark in [false, true] {
                    let fill = resolve(DockThemePalette(theme: theme).fill(family), dark: dark)
                    #expect(abs(fill.redComponent - expected.redComponent) < 0.001)
                    #expect(abs(fill.greenComponent - expected.greenComponent) < 0.001)
                    #expect(abs(fill.blueComponent - expected.blueComponent) < 0.001)
                }
            }
        }
    }

    @Test func accentFamiliesStayConsistentAcrossThemes() {
        #expect(DockAccentColor.allCases.count == 11)
        #expect(DockAccentColor.identity(for: " Agent ") == DockAccentColor.identity(for: "agent"))
        for dark in [false, true] {
            let clean = DockThemePalette(theme: .clean)
            let glass = DockThemePalette(theme: .glass)
            for family in DockAccentColor.allCases {
                let a = resolve(clean.color(family), dark: dark)
                let b = resolve(glass.color(family), dark: dark)
                // Backgrounds may require different ink lightness, but retain the same hue family.
                #expect(abs(a.hueComponent - b.hueComponent) < 0.02)
            }
        }
        for theme in DockThemeID.allCases {
            let palette = DockThemePalette(theme: theme)
            let blue = resolve(palette.color(.blue), dark: theme.appearance == .dark)
            let green = resolve(palette.color(.green), dark: theme.appearance == .dark)
            #expect(abs(blue.hueComponent - green.hueComponent) > 0.1)
        }
    }

    @Test func browserAnnotationsReceiveOpaqueThemeColors() throws {
        _ = NSApplication.shared
        let saved = DockThemeRuntime.current
        defer { DockThemeRuntime.current = saved }
        for theme in [DockThemeID.glass, .clean, .mono, .eInk] {
            DockThemeRuntime.current = theme
            let data = Data(BrowserAnnotation.themeJSON.utf8)
            let tokens = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
            #expect(tokens.count == 7)
            #expect(tokens.values.allSatisfy { $0.hasSuffix("FF") })
        }
    }

    @Test func editorRecolorsUnchangedTextWhenTheThemeChanges() async throws {
        let saved = DockThemeRuntime.current
        let revision = DockThemeRuntime.revision
        defer {
            DockThemeRuntime.current = saved
            DockThemeRuntime.revision = revision
        }
        let editor = CodeEditorContainerView(text: "let value = 42", filePath: "example.swift")
        for theme in [DockThemeID.clean, .mono, .clean] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            editor.applyThemeIfNeeded()
            let storage = try #require(editor.textView.textStorage)
            let deadline = Date().addingTimeInterval(3)
            while storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                != CodeToken.keyword.color,
                Date() < deadline
            {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(editor.textView.string == "let value = 42")
            #expect(
                storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == CodeToken.keyword.color)
        }
    }

    @Test func categoryColorsDoNotImplyFailureOrUrgency() {
        #expect(DockCategoryTone.reminder.accent == .amber)
        #expect(DockCategoryTone.automation.accent == .violet)
        #expect(DockCategoryTone.modified.accent == .cyan)
        #expect(DockCategoryTone.renamed.accent == .violet)
        #expect(DockCategoryTone.task.accent == .teal)
        for category in DockCategoryTone.allCases {
            #expect(category.accent != .orange)
            #expect(category.accent != .coral)
        }
    }

    @Test func renderAccentPalette() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_ACCENT_REVIEW_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let saved = DockThemeRuntime.current
        defer { DockThemeRuntime.current = saved }
        for (theme, dark) in [
            (DockThemeID.clean, false), (.clean, true), (.glass, false), (.glass, true), (.mono, true), (.eInk, false),
            (.warmLight, false),
        ] {
            DockThemeRuntime.current = theme
            let palette = DockThemePalette(theme: theme)
            let content = VStack(alignment: .leading, spacing: 20) {
                Text("Herm · \(theme.title) · \(dark ? "Dark" : "Light")")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(palette.primaryText)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                    ForEach(DockAccentColor.allCases, id: \.rawValue) { family in
                        VStack(alignment: .leading, spacing: 10) {
                            Circle().fill(palette.fill(family)).frame(width: 24, height: 24)
                            Text(String(describing: family).capitalized).font(.system(size: 12, weight: .semibold))
                            Text("Accent text").font(.system(size: 12))
                        }
                        .foregroundStyle(palette.color(family))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(palette.color(family).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                HStack {
                    Button("Primary action") {}.buttonStyle(.dockPrimary)
                    Button("Secondary action") {}.buttonStyle(.dockSecondary)
                    Button("Open details") {}.buttonStyle(.dockLink)
                    Spacer()
                }
                HStack {
                    ForEach(DockStatusTone.allCases, id: \.self) { tone in
                        DockStatusPill(tone: tone, text: String(describing: tone).capitalized)
                    }
                }
            }
            .padding(24).frame(width: 860).background(palette.background)
            .background(dark ? Color.black : Color.white).dockThemedRoot()
            .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent(
                    "\(theme.rawValue)-\(dark ? "dark" : "light").png"))
        }
    }

    @Test func everyThemeKeepsTextAndIconsVisible() {
        let failures = audit()
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
}
