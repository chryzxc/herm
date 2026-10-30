import Foundation

/// Local navigation preferences, shared by floating and window presentations.
enum DockRailDestination: String, CaseIterable, Identifiable {
    case kanban, github, automations, calendar, integrations, artifacts, office, bots, usage, quota, settings

    static let pinsKey = "herm.navigation.pinnedDestinations.v1"
    static let defaultPins = "automations,calendar,bots"
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
        case .settings: .core
        case .github, .artifacts, .bots: nil
        }
    }

    var title: String {
        switch self {
        case .github: "GitHub"
        case .artifacts: "Artifacts"
        case .bots: "Bots"
        default: tab?.globalRailLabel ?? rawValue
        }
    }

    var icon: Ph {
        switch self {
        case .github: .githubLogo
        case .artifacts: .files
        case .bots: .ghost
        default: tab?.icon ?? .dotsThree
        }
    }

    /// Pinned destinations in the order the user arranged them.
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
}
