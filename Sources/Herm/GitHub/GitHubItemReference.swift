import Foundation
import SwiftUI

enum GitHubItemKind: String, Codable, Sendable { case issue, pullRequest }
struct GitHubItemReference: Hashable, Codable, Sendable, Identifiable {
    let repository: GitHubRepositoryReference
    let number: Int
    let kind: GitHubItemKind
    var nodeID: String? = nil
    var id: String { "github:\(repository.id)#\(number)" }
    var webURL: URL { repository.webURL.appendingPathComponent("\(kind == .issue ? "issues" : "pull")/\(number)") }
    var issuePath: String { repository.apiRepositoryPath + "/issues/\(number)" }
    var title: String { "\(repository.id)#\(number)" }
}
enum GitHubMergeability: String, Sendable, Equatable { case mergeable, conflicting, unknown }
private struct GitHubNavigationKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (GitHubItemReference) -> Void = { reference in NSWorkspace.shared.open(reference.webURL) }
}
extension EnvironmentValues {
    var openGitHubItem: @MainActor @Sendable (GitHubItemReference) -> Void {
        get { self[GitHubNavigationKey.self] }
        set { self[GitHubNavigationKey.self] = newValue }
    }
}
