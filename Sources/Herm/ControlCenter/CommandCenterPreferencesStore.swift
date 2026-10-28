import Foundation

/// Persists presentation choices and stable references only. Operational Hermes
/// content, diffs, prompts, and tool results deliberately never enter this store.
@MainActor
final class CommandCenterPreferencesStore: ObservableObject {
    static let shared = CommandCenterPreferencesStore()
    @Published private(set) var pinnedRepositoryIDs: [String]
    @Published private(set) var sourcePins: [PinnedSource] = []
    @Published private(set) var routinePins: [String] = []
    @Published private(set) var collapsedSections: Set<String>
    @Published private(set) var sectionOrder: [String]
    @Published private(set) var recentActionIDs: [String]
    @Published private(set) var watchedRepositoryIDs: [String]
    @Published private(set) var reviewBaselines: [RepositoryReviewBaseline]
    @Published private(set) var repositoryNotificationsEnabled: Bool
    @Published private(set) var launchesExpandedByDefault: Bool
    private var lastSeen: [String: TimeInterval]
    private let defaults: UserDefaults
    private let key = "hermes.command-center.preferences.v1"
    /// The panel reopens in whichever mode was last used; the Settings toggle resets it.
    static let opensFullscreenKey = "hermes.panel.opens-fullscreen"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: key) ?? [:]
        if let data = saved["sourcePins"] as? Data {
            sourcePins = (try? JSONDecoder().decode([PinnedSource].self, from: data)) ?? []
        }
        routinePins = saved["routinePins"] as? [String] ?? []
        pinnedRepositoryIDs = saved["pinnedRepositoryIDs"] as? [String] ?? []
        collapsedSections = Set(saved["collapsedSections"] as? [String] ?? [])
        sectionOrder = saved["sectionOrder"] as? [String] ?? SessionNavSection.allCases.map(\.rawValue)
        recentActionIDs = saved["recentActionIDs"] as? [String] ?? []
        watchedRepositoryIDs = saved["watchedRepositoryIDs"] as? [String] ?? []
        reviewBaselines = (saved["reviewBaselines"] as? [[String: Any]] ?? []).compactMap(
            RepositoryReviewBaseline.init(dictionary:))
        repositoryNotificationsEnabled = saved["repositoryNotificationsEnabled"] as? Bool ?? false
        launchesExpandedByDefault = saved["launchesExpandedByDefault"] as? Bool ?? false
        lastSeen = saved["lastSeen"] as? [String: TimeInterval] ?? [:]
    }

    func togglePinnedRepository(_ id: String) {
        if let index = pinnedRepositoryIDs.firstIndex(of: id) {
            pinnedRepositoryIDs.remove(at: index)
        } else {
            pinnedRepositoryIDs.append(id)
        }
        save()
    }

    func pinSource(origin: QuickDestination, url: String, label: String? = nil, revisionID: String? = nil) {
        var origin = origin
        origin.runtimeID = nil
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
            parsed.host != nil,
            !sourcePins.contains(where: { $0.origin.key == origin.key && $0.url == url && $0.revisionID == revisionID })
        else { return }
        sourcePins.append(
            PinnedSource(origin: origin, url: url, label: label.map { String($0.prefix(120)) }, revisionID: revisionID))
        save()
    }
    func removeSource(_ id: UUID) {
        sourcePins.removeAll { $0.id == id }
        save()
    }
    func toggleRoutinePin(_ id: String) {
        if routinePins.contains(id) { routinePins.removeAll { $0 == id } } else { routinePins.append(id) }
        save()
    }

    func isPinnedRepository(_ id: String) -> Bool { pinnedRepositoryIDs.contains(id) }

    func toggleCollapsed(_ section: SessionNavSection) {
        if collapsedSections.contains(section.rawValue) {
            collapsedSections.remove(section.rawValue)
        } else {
            collapsedSections.insert(section.rawValue)
        }
        save()
    }

    func isCollapsed(_ section: SessionNavSection) -> Bool { collapsedSections.contains(section.rawValue) }

    func setSectionOrder(_ sections: [SessionNavSection]) {
        sectionOrder = sections.map(\.rawValue)
        save()
    }

    func recordAction(_ actionID: String) {
        recentActionIDs.removeAll { $0 == actionID }
        recentActionIDs.insert(actionID, at: 0)
        if recentActionIDs.count > 10 { recentActionIDs.removeLast(recentActionIDs.count - 10) }
        save()
    }

    func markSeen(_ id: String, at date: Date = .now) {
        lastSeen[id] = date.timeIntervalSince1970
        save()
    }

    func isNew(_ id: String, sourceDate: Date?) -> Bool {
        guard let sourceDate else { return false }
        return sourceDate.timeIntervalSince1970 > (lastSeen[id] ?? 0)
    }

    func toggleWatchingRepository(_ id: String) {
        if let index = watchedRepositoryIDs.firstIndex(of: id) {
            watchedRepositoryIDs.remove(at: index)
        } else {
            watchedRepositoryIDs.append(id)
        }
        save()
    }

    func isWatchingRepository(_ id: String) -> Bool { watchedRepositoryIDs.contains(id) }

    func setRepositoryNotificationsEnabled(_ enabled: Bool) {
        repositoryNotificationsEnabled = enabled
        save()
    }

    func setLaunchesExpandedByDefault(_ enabled: Bool) {
        launchesExpandedByDefault = enabled
        defaults.set(enabled, forKey: Self.opensFullscreenKey)
        save()
    }

    func baseline(for repositoryID: String) -> RepositoryReviewBaseline? {
        reviewBaselines.first { $0.repositoryID == repositoryID }
    }

    func saveBaseline(_ baseline: RepositoryReviewBaseline) {
        reviewBaselines.removeAll { $0.repositoryID == baseline.repositoryID }
        reviewBaselines.insert(baseline, at: 0)
        if reviewBaselines.count > 20 { reviewBaselines.removeLast(reviewBaselines.count - 20) }
        save()
    }

    private func save() {
        defaults.set(
            [
                "sourcePins": (try? JSONEncoder().encode(sourcePins)) ?? Data(),
                "routinePins": routinePins,
                "pinnedRepositoryIDs": pinnedRepositoryIDs,
                "collapsedSections": Array(collapsedSections),
                "sectionOrder": sectionOrder,
                "recentActionIDs": recentActionIDs,
                "lastSeen": lastSeen,
                "watchedRepositoryIDs": watchedRepositoryIDs,
                "reviewBaselines": reviewBaselines.map(\.dictionary),
                "repositoryNotificationsEnabled": repositoryNotificationsEnabled,
                "launchesExpandedByDefault": launchesExpandedByDefault,
            ], forKey: key)
    }
}
