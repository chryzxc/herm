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
    private static func root(
        of record: ArtifactRecord, lookup: [String: ArtifactRecord], aliases: [String: ArtifactRecord]
    ) -> String {
        var current = record
        var seen: Set<String> = [record.id]
        while let previous = parent(of: current, lookup: lookup, aliases: aliases), seen.insert(previous.id).inserted {
            current = previous
        }
        return current.id
    }
    static func latest(_ records: [ArtifactRecord]) -> [ArtifactRecord] {
        let lookup = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let aliases = Dictionary(
            records.compactMap { value in value.generated.map { ($0.reference.presentationKey, value) } },
            uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(grouping: records) { root(of: $0, lookup: lookup, aliases: aliases) }
        let ids = Set(
            groups.values.compactMap { values in
                values.max { earlier($0, than: $1) }?.id
            })
        return records.filter { ids.contains($0.id) }
    }
    static func versions(of record: ArtifactRecord, in records: [ArtifactRecord]) -> [ArtifactRecord] {
        let lookup = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let aliases = Dictionary(
            records.compactMap { value in value.generated.map { ($0.reference.presentationKey, value) } },
            uniquingKeysWith: { first, _ in first })
        let rootID = root(of: record, lookup: lookup, aliases: aliases)
        return records.filter { root(of: $0, lookup: lookup, aliases: aliases) == rootID }.sorted {
            earlier($1, than: $0)
        }
    }
}
