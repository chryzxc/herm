import Foundation

enum ArtifactKind: String, CaseIterable, Equatable {
    case image
    case file
    case link
    case interactive
}

/// How the artifact surfaced: returned by a producer tool, or shown in a reply.
enum ArtifactOrigin: String, Equatable {
    case generated = "Generated"
    case shared = "Shared"
}

struct ArtifactRecord: Identifiable, Equatable {
    let value: String
    let sessionID: String
    let sessionTitle: String
    let timestamp: Date
    var origin: ArtifactOrigin = .shared
    var profileID: String? = nil
    var generated: RichGeneratedArtifact? = nil
    var unavailableBookmark: RichArtifactBookmark? = nil

    var scopedSessionID: ProfileScopedID { ProfileScopedID(profileID: profileID, resourceID: sessionID) }

    var id: String {
        generated?.reference.id ?? unavailableBookmark?.id ?? "\(profileID.map { "\($0):" } ?? "")\(sessionID):\(value)"
    }
    enum Content: Equatable {
        case resource(String)
        case surface(RichGeneratedArtifact)
        case unavailable(RichArtifactBookmark)
    }
    var content: Content {
        if let generated { return .surface(generated) }
        if let unavailableBookmark { return .unavailable(unavailableBookmark) }
        return .resource(value)
    }
    var kind: ArtifactKind {
        generated != nil || unavailableBookmark != nil ? .interactive : ArtifactService.kind(for: value)
    }
    var label: String {
        if let generated { return generated.surface.title }
        if let unavailableBookmark { return unavailableBookmark.title }
        if let url = URL(string: value), let last = url.pathComponents.last, last != "/" {
            return last.removingPercentEncoding ?? last
        }
        return value.split(separator: "/").last.map(String.init) ?? value
    }
    /// Parent folder for local files, host for links.
    var location: String {
        if generated != nil || unavailableBookmark != nil { return sessionTitle }
        if kind == .link || value.hasPrefix("http") { return URL(string: value)?.host ?? value }
        return ((value as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    }
}

struct RichGeneratedArtifact: Equatable {
    let reference: RichArtifactReference
    let surface: RichSurface
    let source: String
}

enum RichArtifactIndex {
    private static func earlier(_ previous: ArtifactRecord, than record: ArtifactRecord) -> Bool {
        guard previous.scopedSessionID == record.scopedSessionID, previous.id != record.id else { return false }
        if previous.timestamp != record.timestamp { return previous.timestamp < record.timestamp }
        guard let old = previous.generated?.reference.rowID, let new = record.generated?.reference.rowID else {
            return false
        }
        return old < new
    }
    private static func parent(
        of record: ArtifactRecord, lookup: [String: ArtifactRecord], aliases: [String: ArtifactRecord]
    ) -> ArtifactRecord? {
        guard let reference = record.generated?.surface.revisionOf,
            let previous = lookup[reference.id] ?? aliases[reference.presentationKey],
            previous.generated?.reference.matches(reference) == true, earlier(previous, than: record)
        else { return nil }
        return previous
    }
    /// Construct once per record change; rendering only looks up the resulting groups.
    final class Snapshot {
        let records: [ArtifactRecord]
        let latest: [ArtifactRecord]
        private let roots: [String: String]
        private let groups: [String: [ArtifactRecord]]

        init(_ records: [ArtifactRecord]) {
            self.records = records
            let lookup = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let aliases = Dictionary(
                records.compactMap { value in value.generated.map { ($0.reference.presentationKey, value) } },
                uniquingKeysWith: { first, _ in first })
            var roots: [String: String] = [:]
            for record in records {
                var current = record
                var path: [String] = []
                var seen = Set<String>()
                while roots[current.id] == nil, seen.insert(current.id).inserted {
                    path.append(current.id)
                    guard let previous = parent(of: current, lookup: lookup, aliases: aliases) else { break }
                    current = previous
                }
                let root = roots[current.id] ?? current.id
                for id in path { roots[id] = root }
            }
            let groups = Dictionary(grouping: records) { roots[$0.id] ?? $0.id }
                .mapValues { $0.sorted { earlier($1, than: $0) } }
            let ids = Set(groups.values.compactMap { $0.first?.id })
            self.roots = roots
            self.groups = groups
            latest = records.filter { ids.contains($0.id) }
        }

        func versions(of record: ArtifactRecord) -> [ArtifactRecord] {
            groups[roots[record.id] ?? record.id] ?? []
        }
    }

    static func latest(_ records: [ArtifactRecord]) -> [ArtifactRecord] {
        Snapshot(records).latest
    }

    static func versions(of record: ArtifactRecord, in records: [ArtifactRecord]) -> [ArtifactRecord] {
        Snapshot(records).versions(of: record)
    }
}
