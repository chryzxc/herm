import Foundation

/// Finds Hermes Desktop plugins on disk, read-only. Desktop loads plugins from
/// `<HERMES_HOME>/desktop-plugins/<id>/`. A package installed with `hermes plugins install` keeps its
/// desktop half in `plugins/<id>/` (its root `plugin.js`, else `desktop/plugin.js`). Electron copies that
/// half into `desktop-plugins/` when Desktop starts; Herm reads it where it is instead of writing to the
/// shared folder.
enum HermesDesktopPluginCatalog {
    static func defaultHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        environment["HERMES_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes", isDirectory: true)
    }

    /// Folders whose children are plugins, in precedence order (Hermes' own: published copies, then the
    /// default home's packages, then each profile's).
    static func roots(home: URL, fileManager: FileManager = .default) -> [URL] {
        let profiles = home.appendingPathComponent("profiles", isDirectory: true)
        let names = ((try? fileManager.contentsOfDirectory(atPath: profiles.path)) ?? []).sorted()
        return [home.appendingPathComponent("desktop-plugins"), home.appendingPathComponent("plugins")]
            + names.map { profiles.appendingPathComponent($0).appendingPathComponent("plugins") }
    }

    /// The SDK names Herm's plugin host exports, read from the manifest the host build writes
    /// (`Scripts/check-plugin-host.py` keeps it in step with `sdk/sdk.js`). `nil` when this build
    /// ships without the host (`sdk/` is built, not checked in), so no page claims to run.
    static func supportedExports(bundle: Bundle = .herm) -> Set<String>? {
        guard
            let host = bundle.resourceURL?.appendingPathComponent("DesktopPluginHost/sdk/sdk.js"),
            FileManager.default.fileExists(atPath: host.path),
            let url = bundle.url(forResource: "sdk-exports", withExtension: "json", subdirectory: "DesktopPluginHost"),
            let data = try? Data(contentsOf: url),
            let names = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return Set(names)
    }

    /// Plugins sorted by name; for an id found in several roots the first root wins. A missing root is
    /// simply no plugins, and an agent package without a desktop half is skipped.
    static func scan(roots: [URL], supported: Set<String>?, fileManager: FileManager = .default)
        -> [HermesDesktopPlugin]
    {
        var seen = Set<String>()
        let entries = roots.flatMap { root -> [(String, URL)] in
            let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { folder in
                let entry = [folder, folder.appendingPathComponent("desktop")].map {
                    $0.appendingPathComponent("plugin.js")
                }.first { fileManager.fileExists(atPath: $0.path) }
                return entry.map { (folder.lastPathComponent, $0) }
            }
        }.filter { seen.insert($0.0).inserted }
        return entries.map { id, entry -> HermesDesktopPlugin in
            guard let source = try? String(contentsOf: entry, encoding: .utf8) else {
                return HermesDesktopPlugin(id: id, name: id, description: nil, entryURL: entry, compatibility: .unknown)
            }
            let compatibility = DesktopPluginCompatibility.classify(
                imports: DesktopPluginCompatibility.sdkImports(in: source), supported: supported)
            return HermesDesktopPlugin(
                id: id, name: literal("name", in: source) ?? id, description: literal("description", in: source),
                codicon: navCodicon(in: source), entryURL: entry, compatibility: compatibility)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A string field of the plugin's `export default { … }` object, read as written. Plugins
    /// declare `name`/`description` as literals; anything computed falls back to the folder id.
    static func literal(_ field: String, in source: String) -> String? {
        guard let start = source.range(of: "export default") else { return nil }
        let tail = String(source[start.upperBound...]) as NSString
        guard let regex = try? NSRegularExpression(pattern: "\\b\(field)\\s*:\\s*(['\"])((?:(?!\\1).)+)\\1"),
            let match = regex.firstMatch(in: tail as String, range: NSRange(location: 0, length: tail.length))
        else { return nil }
        let value = tail.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// The codicon of the plugin's sidebar entry, read as written: `{ area: SIDEBAR_NAV_AREA, data: { codicon: 'x' } }`.
    static func navCodicon(in source: String) -> String? {
        let name = #"\bcodicon\s*:\s*['"]([\w-]+)['"]"#
        let patterns = [#"SIDEBAR_NAV_AREA[^{}]*\{[^{}]*"# + name, name + #"[^{}]*\}[^{}]*SIDEBAR_NAV_AREA"#]
        let range = NSRange(source.startIndex..., in: source)
        for pattern in patterns {
            if let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: source, range: range),
                let value = Range(match.range(at: 1), in: source)
            {
                return String(source[value])
            }
        }
        return nil
    }
}
