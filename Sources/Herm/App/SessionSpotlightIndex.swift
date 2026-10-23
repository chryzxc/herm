import Combine
import CoreSpotlight
import Foundation

/// Optional Spotlight entries for sessions (title and a short preview). Off by default: previews leave the app.
@MainActor
final class SessionSpotlightIndex {
    static let enabledKey = "herm.spotlightSessions.v1"
    static let domain = "dev.herm.sessions"
    private static let maxPreview = 160

    private let model: DockModel
    private var observer: AnyCancellable?
    private var indexed: Set<String> = []
    private var cleared = false

    init(model: DockModel) {
        self.model = model
        observer = Publishers.CombineLatest(
            model.$sessions,
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () }.prepend(())
        )
        .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
        .sink { [weak self] sessions, _ in self?.sync(sessions) }
    }

    /// Spotlight identifier. The profile is part of it so opening an entry can resume the right session.
    static func identifier(for session: HermesSession) -> String { "\(session.profileID ?? "")|\(session.id)" }

    static func sessionID(from identifier: String) -> String {
        identifier.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init)
            ?? identifier
    }

    static func item(for session: HermesSession) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = session.displayTitle
        attributes.contentDescription = session.displayPreview.map { String($0.prefix(maxPreview)) }
        attributes.contentModificationDate = session.lastUpdatedAt
        return CSSearchableItem(
            uniqueIdentifier: identifier(for: session), domainIdentifier: domain, attributeSet: attributes)
    }

    private func sync(_ sessions: [HermesSession]) {
        let index = CSSearchableIndex.default()
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            // Turning the setting off removes everything Herm put in Spotlight.
            if !cleared {
                index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
                cleared = true
            }
            indexed = []
            return
        }
        cleared = false
        let visible = sessions.filter { !$0.isHidden }
        let ids = Set(visible.map(Self.identifier(for:)))
        let stale = indexed.subtracting(ids)
        if !stale.isEmpty { index.deleteSearchableItems(withIdentifiers: Array(stale)) }
        if !visible.isEmpty { index.indexSearchableItems(visible.map(Self.item(for:))) }
        indexed = ids
    }
}
