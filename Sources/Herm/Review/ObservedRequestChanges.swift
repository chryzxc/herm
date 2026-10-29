import Combine
import Foundation

/// Bounded ephemeral comparisons. These describe observed local changes, never authorship.
struct ObservedRequestComparison: Identifiable {
    let id: UUID
    let origin: QuickDestination
    let path: String
    let head: String
    let fingerprint: String
    let patches: [RepositoryDiff]
    let completionRowID: Int
    let capturedAt: Date
}

@MainActor
final class ObservedRequestChanges: ObservableObject {
    static let shared = ObservedRequestChanges()
    @Published var requestedReview: ObservedReviewRequest?
    @Published private(set) var comparisons: [ObservedRequestComparison] = []
    private var generations: [String: UUID] = [:]

    func invalidate(_ origin: QuickDestination) {
        generations[origin.sessionKey] = UUID()
        if generations.count > 256 { generations = [origin.sessionKey: UUID()] }
    }

    func capture(_ baseline: TurnRepositoryBaseline, concurrent: Bool) {
        guard baseline.eligible, baseline.clean, !concurrent, let head = baseline.head,
            let completionRowID = baseline.completionRowID, completionRowID > 0,
            GatewayConnectionStore.isLocalBackend
        else { return }
        let token = UUID()
        generations[baseline.origin.sessionKey] = token
        Task {
            do {
                let before = await RepositoryComparisonService.fingerprint(baseline.path)
                let currentHead = await RepositoryService.runGit(path: baseline.path, arguments: ["rev-parse", "HEAD"])
                guard currentHead.exitCode == 0, currentHead.output == head else { return }
                let loaded = try await RepositoryComparisonService.load(
                    path: baseline.path, scope: .working, reference: "HEAD", ignoreWhitespace: false)
                let names = await RepositoryService.runGit(
                    path: baseline.path, arguments: ["diff", "--no-renames", "--name-only", "-z", head],
                    trimOutput: false)
                let files = Array(Set(loaded.files + names.output.split(separator: "\0").map(String.init))).sorted()
                guard names.exitCode == 0, !loaded.partial, files.count <= 100 else { return }
                let comparison = RepositoryComparison(
                    title: loaded.title, revision: head, files: files,
                    arguments: ["diff", "--no-ext-diff", "--no-renames", head], fingerprint: before, partial: false)
                var patches: [RepositoryDiff] = []
                var bytes = 0
                for file in files {
                    let patch = try await RepositoryComparisonService.patch(
                        path: baseline.path, file: file, comparison: comparison)
                    bytes += patch.text.utf8.count
                    guard !patch.isTruncated, bytes <= 512 * 1024 else { return }
                    if !patch.text.isEmpty { patches.append(patch) }
                }
                let afterHead = await RepositoryService.runGit(path: baseline.path, arguments: ["rev-parse", "HEAD"])
                guard generations[baseline.origin.sessionKey] == token, !patches.isEmpty,
                    afterHead.output == head, before == (await RepositoryComparisonService.fingerprint(baseline.path))
                else { return }
                comparisons.append(
                    ObservedRequestComparison(
                        id: baseline.attemptID, origin: baseline.origin, path: baseline.path,
                        head: head, fingerprint: before, patches: patches, completionRowID: completionRowID,
                        capturedAt: .now))
                comparisons = Array(comparisons.suffix(8))
            } catch {
                // Missing or unstable comparisons fall back to current Git changes.
            }
        }
    }
    func current(for session: HermesSession, replyID: String?) async -> ObservedRequestComparison? {
        guard GatewayConnectionStore.isLocalBackend,
            let saved = comparisons.last(where: {
                String($0.completionRowID) == replyID && $0.origin.sessionID == session.id
                    && ($0.origin.profileID ?? "default") == (session.profileID ?? "default")
            })
        else { return nil }
        let fingerprint = await RepositoryComparisonService.fingerprint(saved.path)
        let head = await RepositoryService.runGit(path: saved.path, arguments: ["rev-parse", "HEAD"])
        return fingerprint == saved.fingerprint && head.output == saved.head ? saved : nil
    }
}
