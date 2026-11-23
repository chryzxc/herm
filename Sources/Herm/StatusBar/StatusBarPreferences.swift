import Combine
import SwiftUI

/// The bar's local preferences. Views bind to it; the bar reads it.
@MainActor
final class StatusBarPreferences: ObservableObject {
    static let shared = StatusBarPreferences()

    static let enabledKey = "herm.statusBar.enabled"
    static let hiddenKey = "herm.statusBar.hidden"
    static let shownKey = "herm.statusBar.shown"
    static let floatingKey = "herm.statusBar.floating"
    static let returnSummaryKey = "herm.statusBar.returnSummaryMinutes"
    static let stalledMinutesKey = "herm.statusBar.stalledMinutes"

    private let defaults: UserDefaults
    /// Optional items the user chose to show.
    @Published private var shown: Set<String>
    @Published private var hidden: Set<String>
    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Self.enabledKey) } }
    @Published var showsInFloating: Bool { didSet { defaults.set(showsInFloating, forKey: Self.floatingKey) } }
    /// Idle minutes before the bar sums up what changed; 0 turns it off.
    @Published var returnSummaryMinutes: Int {
        didSet { defaults.set(returnSummaryMinutes, forKey: Self.returnSummaryKey) }
    }
    @Published var stalledMinutes: Int { didSet { defaults.set(stalledMinutes, forKey: Self.stalledMinutesKey) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shown = Set(defaults.stringArray(forKey: Self.shownKey) ?? [])
        hidden = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        showsInFloating = defaults.object(forKey: Self.floatingKey) as? Bool ?? true
        returnSummaryMinutes = defaults.object(forKey: Self.returnSummaryKey) as? Int ?? 15
        stalledMinutes = defaults.object(forKey: Self.stalledMinutesKey) as? Int ?? 5
    }

    func isVisible(inFloatingPanel: Bool) -> Bool {
        isEnabled && (!inFloatingPanel || showsInFloating)
    }

    func binding(for item: StatusBarItem) -> Binding<Bool> {
        Binding(get: { self.isOn(item) }, set: { self.set(item, on: $0) })
    }

    func isOn(_ item: StatusBarItem) -> Bool {
        item.isLocked || (item.isOnByDefault ? !hidden.contains(item.rawValue) : shown.contains(item.rawValue))
    }

    func set(_ item: StatusBarItem, on: Bool) {
        guard !item.isLocked else { return }
        if item.isOnByDefault {
            if on { hidden.remove(item.rawValue) } else { hidden.insert(item.rawValue) }
            defaults.set(hidden.sorted(), forKey: Self.hiddenKey)
        } else {
            if on { shown.insert(item.rawValue) } else { shown.remove(item.rawValue) }
            defaults.set(shown.sorted(), forKey: Self.shownKey)
        }
    }

    var enabledItems: Set<StatusBarItem> { Set(StatusBarItem.allCases.filter(isOn)) }
}
