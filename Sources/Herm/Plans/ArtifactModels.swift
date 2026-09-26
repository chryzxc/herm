import Foundation

enum ArtifactKind: String, CaseIterable, Equatable {
    case image
    case file
    case link
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

    var id: String { "\(sessionID):\(value)" }
    var kind: ArtifactKind {
        ArtifactService.kind(for: value)
    }
    var label: String {
        if let url = URL(string: value), let last = url.pathComponents.last, last != "/" {
            return last.removingPercentEncoding ?? last
        }
        return value.split(separator: "/").last.map(String.init) ?? value
    }
    /// Parent folder for local files, host for links.
    var location: String {
        if kind == .link || value.hasPrefix("http") { return URL(string: value)?.host ?? value }
        return ((value as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    }
}
