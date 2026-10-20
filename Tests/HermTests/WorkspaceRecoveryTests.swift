import CryptoKit
import Foundation
import Testing

@testable import Herm

@MainActor
struct WorkspaceRecoveryTests {
    @Test func presentationIsScopedAndBrowserCredentialsAreNotRetained() throws {
        let suite = "HermPresentation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspacePresentationStore(defaults: defaults)
        store.save(
            InspectorPresentation(selected: "Terminal", closed: "Browser", recentClosed: ["Source Control"]),
            identity: "backend/profile/a")
        #expect(store.load("backend/profile/a")?.selected == "Terminal")
        #expect(store.load("backend/profile/b") == nil)
        #expect(
            WorkspacePresentationStore.restorableBrowserURL(
                "https://user:password@example.com/page?token=secret#fragment") == "https://example.com/page")
        #expect(WorkspacePresentationStore.restorableBrowserURL("file:///private/file") == nil)
    }
    @Test func terminalRestoresLayoutWithFreshShells() throws {
        let identity = "fixture-" + UUID().uuidString
        let key =
            "herm.terminal-layout." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        defer { UserDefaults.standard.removeObject(forKey: key + ".v2") }
        let first = TerminalTabStore(persistenceKey: identity)
        defer { first.closeAll() }
        first.add(directory: FileManager.default.temporaryDirectory.path)
        first.splitIDs = first.sessions.map(\.id)
        first.splitAxis = 1
        let restored = TerminalTabStore(persistenceKey: identity)
        defer { restored.closeAll() }
        #expect(restored.sessions.count == 2)
        #expect(restored.selectedID == restored.sessions[1].id)
        #expect(restored.splitIDs.count == 2)
        #expect(restored.splitAxis == 1)
        #expect(restored.sessions.allSatisfy { $0.workingDirectory == nil && $0.shellProcessID == 0 })
    }

    @Test func prWatchingOnlyReportsMeaningfulTransitions() {
        let baseline = PullRequestWatchSnapshot(
            merged: false, conflicted: false, failedChecks: [], lastReviewID: 1, lastCommentID: 2)
        #expect(baseline.changes(from: baseline).isEmpty)
        let changed = PullRequestWatchSnapshot(
            merged: true, conflicted: true, failedChecks: ["Tests"], lastReviewID: 2, lastCommentID: 3)
        #expect(
            changed.changes(from: baseline) == [
                "Merged", "Merge conflicts", "Checks failed", "New review", "New comment",
            ])
    }
}
