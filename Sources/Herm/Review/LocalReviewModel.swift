import Combine
import Foundation

@MainActor
final class LocalReviewModel: ObservableObject {
    let revisionNotes: RevisionNoteStore
    init(revisionNotes: RevisionNoteStore? = nil) { self.revisionNotes = revisionNotes ?? RevisionNoteStore() }
    @Published var comparison: RepositoryComparison?
    @Published var patches: [String: RepositoryDiff] = [:]
    @Published var error: String?
    @Published var loading = false
    @Published var partial = false
    @Published private(set) var stale = false
    private var generation = UUID()
    func load(path: String, scope: RepositoryComparison.Scope, reference: String, ignoreWhitespace: Bool) async {
        let token = UUID()
        generation = token
        loading = true
        error = nil
        let previous = (comparison, patches, partial)
        defer { if generation == token { loading = false } }
        do {
            let result = try await RepositoryComparisonService.load(
                path: path, scope: scope, reference: reference, ignoreWhitespace: ignoreWhitespace)
            guard generation == token, !Task.isCancelled else { return }
            comparison = result
            revisionNotes.invalidateSources()
            patches = [:]
            partial = result.partial
            stale = false
            for file in result.files {
                try Task.checkCancellation()
                let diff = try await RepositoryComparisonService.patch(path: path, file: file, comparison: result)
                guard generation == token else { return }
                revisionNotes.register(
                    path: file,
                    identity: DiffComparisonIdentity.local(path: path, comparison: result).documentID(
                        DiffDocument(path: file, patch: diff.text)))
                patches[file] = diff
                partial = partial || diff.isTruncated
            }
            if scope == .working || scope == .staged {
                guard await RepositoryComparisonService.fingerprint(path) == result.fingerprint else {
                    throw QuickDraftError.message(
                        "Local files changed during loading. Refresh before using this comparison.")
                }
            }
        } catch {
            if generation == token, !Task.isCancelled {
                if previous.0 != nil {
                    comparison = previous.0
                    patches = previous.1
                    partial = previous.2
                    stale = true
                }
                self.error = DockModel.safeUserDiagnostic(error.localizedDescription)
            }
        }
    }
}
