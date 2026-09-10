import Foundation

enum ArtifactKind: String, CaseIterable, Equatable {
    case image
    case file
    case link
}

struct ArtifactRecord: Identifiable, Equatable {
    let value: String
    let sessionID: String
    let sessionTitle: String
    let timestamp: Date

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
}
