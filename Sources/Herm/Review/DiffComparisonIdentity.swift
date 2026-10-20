import CryptoKit
import Foundation

struct DiffComparisonIdentity: Equatable, Codable, Sendable {
    let repository: String
    let revision: String
    var fingerprint: String = ""

    func documentID(_ document: DiffDocument) -> String {
        SHA256.hash(data: Data([repository, revision, fingerprint, document.identity].joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    static func local(path: String, comparison: RepositoryComparison) -> Self {
        Self(repository: path, revision: comparison.revision, fingerprint: comparison.fingerprint)
    }
    static func pullRequest(_ record: PullRequestRecord) -> Self {
        Self(
            repository: record.repository.id,
            revision: (record.baseRevision ?? "unavailable") + ".." + (record.headRevision ?? "unavailable"))
    }
}
