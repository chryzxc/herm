import Foundation

/// One Hermes Desktop plugin found on disk, with whether Herm's plugin host can render its page.
struct HermesDesktopPlugin: Identifiable, Equatable, Sendable {
    /// The plugin's folder name under `desktop-plugins/`; Desktop uses the same slug as its id.
    let id: String
    let name: String
    let description: String?
    /// The codicon name its Desktop sidebar entry declares (`SIDEBAR_NAV_AREA` `data.codicon`), if any.
    var codicon: String? = nil
    /// The plugin's `plugin.js`.
    let entryURL: URL
    let compatibility: DesktopPluginCompatibility
}

/// What Herm can do with a Desktop plugin, decided from its `@hermes/plugin-sdk` imports before
/// anything runs: an ES import of a name the host does not export fails the whole module at link time.
enum DesktopPluginCompatibility: Equatable, Sendable {
    /// Every SDK name it imports is supported and it registers a page.
    case runsInHerm
    /// It registers a page but imports SDK names Herm does not provide (sorted).
    case needs([String])
    /// It contributes no page (themes, panes, composer slots only), so there is nothing to open in Herm.
    case desktopOnly
    /// Its source could not be read, or imports the SDK as a namespace Herm cannot check name by name.
    case unknown
    /// It registers a page, but this build of Herm ships without the plugin host to run it.
    case hostMissing

    static let sdkModule = "@hermes/plugin-sdk"

    /// Names used from `@hermes/plugin-sdk`, original names (`a as b` yields `a`). A namespace import
    /// (`import * as sdk`) contributes its `sdk.Name` reads; `nil` when that namespace is used any other way
    /// (`sdk[key]`, passed along), which cannot be checked.
    static func sdkImports(in source: String) -> Set<String>? {
        let module = #"['"]@hermes/plugin-sdk['"]"#
        let text = source as NSString
        let whole = NSRange(location: 0, length: text.length)
        var names = Set<String>()
        let namespace = try? NSRegularExpression(pattern: #"import\s*\*\s*as\s+([\w$]+)\s*from\s*"# + module)
        for match in namespace?.matches(in: source, range: whole) ?? [] {
            let alias = NSRegularExpression.escapedPattern(for: text.substring(with: match.range(at: 1)))
            guard
                let uses = try? NSRegularExpression(
                    pattern: #"(?<![\w$./'"`-])"# + alias + #"(?![\w$])(\s*\.\s*([\w$]+))?"#)
            else { return nil }
            for use in uses.matches(in: source, range: whole)
            where NSIntersectionRange(use.range, match.range).length == 0 {
                guard use.range(at: 2).location != NSNotFound else { return nil }
                names.insert(text.substring(with: use.range(at: 2)))
            }
        }
        // `import { a }` and `import Default, { a }`; the default binding names no SDK export.
        guard
            let pattern = try? NSRegularExpression(
                pattern: #"import\s*(?:[\w$]+\s*,\s*)?\{([^}]*)\}\s*from\s*"# + module)
        else {
            return nil
        }
        for match in pattern.matches(in: source, range: whole) {
            for specifier in text.substring(with: match.range(at: 1)).split(separator: ",") {
                let words = specifier.split(whereSeparator: \.isWhitespace).filter { $0 != "type" }
                if let name = words.first { names.insert(String(name)) }
            }
        }
        return names
    }

    // ponytail: "has a page" means it imports ROUTES_AREA; a plugin registering the raw area string
    // instead would read as desktop-only. Move to a runtime registration probe if one ever does.
    /// `supported` is `nil` when the plugin host is not in this build, so no page can run.
    static func classify(imports: Set<String>?, supported: Set<String>?) -> DesktopPluginCompatibility {
        guard let imports else { return .unknown }
        guard imports.contains("ROUTES_AREA") else { return .desktopOnly }
        guard let supported else { return .hostMissing }
        let missing = imports.subtracting(supported).sorted()
        return missing.isEmpty ? .runsInHerm : .needs(missing)
    }
}
