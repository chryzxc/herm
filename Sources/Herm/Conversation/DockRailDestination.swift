import Foundation

/// Local navigation preferences, shared by floating and window presentations.
enum DockRailDestination: String, CaseIterable, Identifiable {
    case kanban, github, automations, calendar, integrations, artifacts, office, usage, quota, bots

    static let pinsKey = "herm.navigation.pinnedDestinations.v1"
    static let defaultPins = "automations,calendar"
    var id: String { rawValue }

    var tab: ControlTab? {
        switch self {
        case .kanban: .kanban
        case .calendar: .calendar
        case .automations: .automations
        case .integrations: .integrations
        case .office: .officePreview
        case .usage: .usage
        case .quota: .quota
        case .bots: .bots
        case .github, .artifacts: nil
        }
    }

    var title: String {
        switch self {
        case .github: "GitHub"
        case .artifacts: "Artifacts"
        default: tab?.globalRailLabel ?? rawValue
        }
    }

    var icon: Ph {
        switch self {
        case .github: .githubLogo
        case .artifacts: .files
        default: tab?.icon ?? .dotsThree
        }
    }
}

/// One rail slot: a built-in destination or a Desktop plugin page. Pins persist as one comma-separated
/// string; plugin pins are `plugin:<id>`, so existing built-in pins read unchanged.
enum DockRailItem: Hashable, Identifiable {
    case builtIn(DockRailDestination)
    case plugin(String)

    static let pluginPrefix = "plugin:"

    init?(rawValue: String) {
        if rawValue.hasPrefix(Self.pluginPrefix) {
            let id = String(rawValue.dropFirst(Self.pluginPrefix.count))
            guard !id.isEmpty else { return nil }
            self = .plugin(id)
        } else if let destination = DockRailDestination(rawValue: rawValue) {
            self = .builtIn(destination)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .builtIn(let destination): destination.rawValue
        case .plugin(let id): Self.pluginPrefix + id
        }
    }

    var id: String { rawValue }

    /// Pinned items in the order the user arranged them. A plugin pin survives while the plugin is
    /// missing or off; the rail hides it, and it returns when the plugin does.
    static func ordered(_ raw: String) -> [Self] {
        var seen = Set<Self>()
        return raw.split(separator: ",").compactMap { Self(rawValue: String($0)) }.filter { seen.insert($0).inserted }
    }

    static func pins(_ raw: String) -> Set<Self> { Set(ordered(raw)) }

    static func raw(_ items: [Self]) -> String { items.map(\.rawValue).joined(separator: ",") }

    /// Pinning appends to the end of the rail; unpinning keeps the rest in place.
    static func toggling(_ item: Self, in raw: String) -> String {
        var items = ordered(raw)
        if let index = items.firstIndex(of: item) { items.remove(at: index) } else { items.append(item) }
        return Self.raw(items)
    }

    static func moving(_ item: Self, to index: Int, in items: [Self]) -> [Self] {
        guard let from = items.firstIndex(of: item) else { return items }
        var items = items
        items.remove(at: from)
        items.insert(item, at: min(max(index, 0), items.count))
        return items
    }

    /// Saves a reordered visible rail without dropping pins that are hidden right now.
    static func raw(visible: [Self], keepingHiddenFrom raw: String) -> String {
        let shown = Set(visible)
        return Self.raw(visible + ordered(raw).filter { !shown.contains($0) })
    }
}
