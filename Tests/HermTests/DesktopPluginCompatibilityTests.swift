import Foundation
import Testing

@testable import Herm

struct DesktopPluginCompatibilityTests {
    private let supported: Set<String> = ["ROUTES_AREA", "PALETTE_AREA", "host", "atom"]

    @Test func parsesNamedImportsAcrossLinesAndAliases() {
        let source = """
            import { jsx } from 'react/jsx-runtime';
            import {
              ROUTES_AREA,
              host as h,
              type RouteContribution,
            } from '@hermes/plugin-sdk'
            import{PALETTE_AREA}from"@hermes/plugin-sdk";
            import sdkDefault, { atom } from '@hermes/plugin-sdk'
            """
        #expect(
            DesktopPluginCompatibility.sdkImports(in: source)
                == ["ROUTES_AREA", "host", "RouteContribution", "PALETTE_AREA", "atom"])
    }

    @Test func namespaceImportCountsItsMemberReads() {
        let source = """
            import*as sdk from"@hermes/plugin-sdk";import{ROUTES_AREA}from"@hermes/plugin-sdk";
            const a = sdk.TRANSCRIPT_DIRECTIVE_AREA, b = sdk . host, c = other.sdk, d = "sdk"
            """
        #expect(
            DesktopPluginCompatibility.sdkImports(in: source) == ["TRANSCRIPT_DIRECTIVE_AREA", "host", "ROUTES_AREA"])
        // A namespace passed along or indexed can't be checked.
        #expect(DesktopPluginCompatibility.sdkImports(in: "import * as sdk from '@hermes/plugin-sdk'; use(sdk)") == nil)
        #expect(DesktopPluginCompatibility.sdkImports(in: "import * as s from '@hermes/plugin-sdk'; s[k]") == nil)
        #expect(DesktopPluginCompatibility.classify(imports: nil, supported: supported) == .unknown)
    }

    @Test func classifiesPagesMissingNamesAndDesktopOnly() {
        #expect(
            DesktopPluginCompatibility.classify(imports: ["ROUTES_AREA", "host"], supported: supported) == .runsInHerm)
        #expect(
            DesktopPluginCompatibility.classify(imports: ["ROUTES_AREA", "Panel", "Chat"], supported: supported)
                == .needs(["Chat", "Panel"]))
        #expect(
            DesktopPluginCompatibility.classify(imports: ["THEMES_AREA", "host"], supported: supported)
                == .desktopOnly)
        // A build without the plugin host runs no page, but still knows a theme-only plugin has none.
        #expect(DesktopPluginCompatibility.classify(imports: ["ROUTES_AREA"], supported: nil) == .hostMissing)
        #expect(DesktopPluginCompatibility.classify(imports: ["THEMES_AREA"], supported: nil) == .desktopOnly)
    }

    @Test func navCodiconIsReadFromTheSidebarEntryOnly() {
        let imports = "import { SIDEBAR_NAV_AREA, ROUTES_AREA } from '@hermes/plugin-sdk'\n"
        let pane = "{ area: PANES_AREA, data: { codicon: 'wrong' } },"
        #expect(
            HermesDesktopPluginCatalog.navCodicon(
                in: imports + pane
                    + "{ area: SIDEBAR_NAV_AREA, data: { label: tr('nav'), codicon: 'lightbulb-sparkle' } }")
                == "lightbulb-sparkle")
        #expect(
            HermesDesktopPluginCatalog.navCodicon(
                in: imports + #"{id:"nav",data:{path:P,codicon:"compass"},area:SIDEBAR_NAV_AREA}"#) == "compass")
        #expect(HermesDesktopPluginCatalog.navCodicon(in: imports + pane) == nil)
    }

    @Test func codiconGlyphsComeFromTheHostMap() {
        let json = #"{"compass":"ebd5","x":"EA76","bad":"zz"}"#
        #expect(DesktopPluginIcon.codepoints(json: Data(json.utf8)) == ["compass": "\u{ebd5}", "x": "\u{ea76}"])
    }

    @Test func skinShapeMapsOntoDesktopThemeVariables() {
        // Desktop's rounded-md is scalar × 10px; its own default scalar 0.2 is a 2px corner.
        #expect(DesktopPluginTheme.radiusScalar(8) == "0.800")
        #expect(DesktopPluginTheme.radiusScalar(0) == "0.000")
        #expect(DesktopPluginTheme.fontFamily(.default) == nil)
        #expect(DesktopPluginTheme.fontFamily(.rounded)?.hasPrefix("ui-rounded") == true)
    }

    @Test func scanReadsPluginFoldersAndSkipsOthers() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        func plugin(_ path: String, _ source: String) throws {
            let folder = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try source.write(to: folder.appendingPathComponent("plugin.js"), atomically: true, encoding: .utf8)
        }
        let page = "import { ROUTES_AREA, host } from '@hermes/plugin-sdk'\n"
        try plugin(
            "desktop-plugins/board",
            page + """
                const x = { name: 'inner' }
                export default { id: 'board', name: "Whiteboard", description: 'Draw it', register(ctx) {} }
                """)
        try plugin("desktop-plugins/theme", "import { THEMES_AREA } from '@hermes/plugin-sdk'\nexport default {}")
        // Installed packages: a `desktop/` half, a shadowed duplicate, and an agent-only package.
        try plugin("plugins/sketch/desktop", page + "export default { name: 'Sketch' }")
        try plugin("plugins/board", page + "export default { name: 'Shadowed' }")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("plugins/agent-only"), withIntermediateDirectories: true)
        try plugin("profiles/work/plugins/sketch", page + "export default { name: 'Profile copy' }")
        try plugin("profiles/work/plugins/notes", page + "export default { name: 'Notes' }")

        let roots = HermesDesktopPluginCatalog.roots(home: home)
        let plugins = HermesDesktopPluginCatalog.scan(roots: roots, supported: supported)

        #expect(plugins.map(\.id) == ["notes", "sketch", "theme", "board"])
        #expect(plugins.map(\.name) == ["Notes", "Sketch", "theme", "Whiteboard"])
        #expect(plugins[1].entryURL.path.hasSuffix("plugins/sketch/desktop/plugin.js"))
        #expect(plugins[3].description == "Draw it")
        #expect(plugins[3].compatibility == .runsInHerm)
        #expect(plugins[2].compatibility == .desktopOnly)
        #expect(HermesDesktopPluginCatalog.scan(roots: [home.appendingPathComponent("missing")], supported: []).isEmpty)
    }

    @Test func bundledManifestListsSupportedNamesOnlyWhenTheHostIsBuilt() throws {
        let built = Bundle.herm.resourceURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("DesktopPluginHost/sdk/sdk.js").path)
        }
        guard built == true else {
            #expect(HermesDesktopPluginCatalog.supportedExports() == nil)
            return
        }
        let names = try #require(HermesDesktopPluginCatalog.supportedExports())
        #expect(names.contains("ROUTES_AREA"))
        #expect(names.contains("host"))
    }
}
