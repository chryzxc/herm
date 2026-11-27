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
    @Test func browserPresentationIsScopedByOwningProfileAndChat() throws {
        let suite = "HermBrowserPresentation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspacePresentationStore(defaults: defaults)
        let first = SessionBrowserKey(profileID: "bot-one", sessionID: "same-chat")
        let second = SessionBrowserKey(profileID: "bot-two", sessionID: "same-chat")
        store.save(InspectorPresentation(selected: "Terminal"), identity: "workspace")
        store.saveBrowser(
            InspectorPresentation(browserURL: "https://example.com/a", browserTabs: ["https://example.com/a/extra"],
                selectedBrowser: 0), for: first)
        #expect(store.loadBrowser(second) == nil)
        store.saveBrowser(
            InspectorPresentation(browserURL: "https://example.com/b", browserTabs: ["https://example.com/b/extra"]),
            for: second)
        #expect(store.loadBrowser(first)?.browserURL == "https://example.com/a")
        #expect(store.loadBrowser(first)?.browserTabs == ["https://example.com/a/extra"])
        #expect(store.loadBrowser(first)?.selectedBrowser == 0)
        #expect(store.loadBrowser(second)?.browserURL == "https://example.com/b")
        #expect(store.loadBrowser(second)?.browserTabs == ["https://example.com/b/extra"])
        #expect(store.load("workspace")?.selected == "Terminal")
    }

    @Test func browserSaveWaitsForTheMatchingProfileRestore() {
        let first = SessionBrowserKey(profileID: "first", sessionID: "same")
        let second = SessionBrowserKey(profileID: "second", sessionID: "same")
        #expect(WorkspacePresentationStore.browserRestored(first, current: first))
        #expect(!WorkspacePresentationStore.browserRestored(first, current: second))
        #expect(!WorkspacePresentationStore.browserRestored(nil, current: second))
        #expect(WorkspacePresentationStore.browserRestored(second, current: second))
    }

    @Test func legacyBrowserMigrationRequiresRecordedOwner() throws {
        let suite = "HermLegacyBrowser.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspacePresentationStore(defaults: defaults)
        let first = SessionBrowserKey(profileID: "first", sessionID: "same")
        let second = SessionBrowserKey(profileID: "second", sessionID: "same")
        let firstIdentity = WorkspaceIdentity.session(profileID: first.profileID, sessionID: first.sessionID)
        let secondIdentity = WorkspaceIdentity.session(profileID: second.profileID, sessionID: second.sessionID)
        store.save(
            InspectorPresentation(selected: "Terminal", browserURL: "https://example.com/a", browserOwner: first),
            identity: firstIdentity)
        store.save(
            InspectorPresentation(selected: "Changes", browserURL: "https://example.com/b"), identity: secondIdentity)
        #expect(store.loadBrowser(first)?.browserURL == "https://example.com/a")
        #expect(store.loadBrowser(second) == nil)
        #expect(store.load(firstIdentity)?.selected == "Terminal")
        #expect(store.load(secondIdentity)?.selected == "Changes")
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
