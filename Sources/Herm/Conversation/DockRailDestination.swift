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

    static func pins(_ raw: String) -> Set<Self> {
        Set(raw.split(separator: ",").compactMap { Self(rawValue: String($0)) })
    }

    static func toggling(_ item: Self, in raw: String) -> String {
        var selected = pins(raw)
        if selected.contains(item) { selected.remove(item) } else { selected.insert(item) }
        return allCases.filter { selected.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}
