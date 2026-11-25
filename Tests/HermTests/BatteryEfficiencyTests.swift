import AppKit
import CoreServices
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct BatteryEfficiencyTests {
    @Test func aVisibleBotKeepsItsCompositedWalkOnDeactivation() async throws {
        let previous = DockThemeRuntime.current
        DockThemeRuntime.current = .glass
        defer { DockThemeRuntime.current = previous }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let host = NSHostingView(
            rootView: Color.clear.botStatusMotion(.working, size: 34)
                .environment(\.dockHostVisible, true))
        host.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))

        func artwork(in view: NSView) -> BotNotchFaceMotion.Host? {
            view as? BotNotchFaceMotion.Host ?? view.subviews.lazy.compactMap { artwork(in: $0) }.first
        }
        let layer = try #require(artwork(in: host)?.face.layer)
        let cadence = try #require(layer.animation(forKey: "bot.statusMotion")?.duration)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(30))
        #expect(cadence == BotWorkingPose.stridePeriod)
        #expect(layer.animation(forKey: "bot.statusMotion")?.duration == cadence)
    }

    @Test func externalTurnTailDetectsInPlaceEditsAndRejectsUnpagedResponses() {
        func response(_ content: String) -> [String: Any] {
            ["session_id": "fixture", "messages": [["id": 7, "content": content]], "pagination": ["returned": 1]]
        }
        let first = TranscriptHistoryPaging.externalTurnTail(response("one"))
        #expect(first != nil)
        #expect(first == TranscriptHistoryPaging.externalTurnTail(response("one")))
        #expect(first != TranscriptHistoryPaging.externalTurnTail(response("two")))
        #expect(TranscriptHistoryPaging.externalTurnTail(["messages": [["id": 7]]]) == nil)
    }

    @Test func onlyUnambiguousFileBatchesCanBypassRepositoryStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await RepositoryService.runGit(path: root.path, arguments: ["init", "-q"]).exitCode == 0)
        try "build/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let flags = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
        let buildOutput = "build/output"
        #expect(
            RepositoryWatchService.change(root: root.path, paths: [root.path + "/" + buildOutput], flags: [flags])
                == .files([buildOutput]))
        #expect(await RepositoryService.watchPathsAreIgnored([buildOutput], in: root.path))
        #expect(!(await RepositoryService.watchPathsAreIgnored([buildOutput, ".gitignore"], in: root.path)))
        #expect(
            RepositoryWatchService.change(root: root.path, paths: [root.path + "/.git/index"], flags: [flags])
                == .rescan)
        #expect(
            RepositoryWatchService.change(
                root: root.path, paths: [root.path + "/" + buildOutput],
                flags: [flags | UInt32(kFSEventStreamEventFlagMustScanSubDirs)])
                == .rescan)
    }

    @Test func hiddenQuotaPollingUsesTheIdleInterval() {
        #expect(EdgeNotchPolling.quotaInterval(workspaceVisible: false, previewExpanded: false) == 300)
        #expect(EdgeNotchPolling.quotaInterval(workspaceVisible: true, previewExpanded: false) == 30)
        #expect(EdgeNotchPolling.quotaInterval(workspaceVisible: false, previewExpanded: true) == 30)
    }

    @Test func mergedLastPullRequestStopsTheWatcher() async throws {
        let suite = "herm-pr-watch-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = GitHubRepositoryReference(
            owner: "fixture", name: "fixture", webURL: URL(string: "https://github.com/fixture/fixture")!)
        let watched = [WatchedPullRequest(repository: repository, number: 7)]
        defaults.set(try JSONEncoder().encode(watched), forKey: "herm.pr-watches.v1")
        let store = PullRequestWatchStore(
            defaults: defaults, client: GitHubClient(transport: MergedPullRequestFixture()))
        store.start()
        defer { store.stop() }
        #expect(store.isPolling)
        for _ in 0..<100 where store.isPolling { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.watched.isEmpty)
        #expect(!store.isPolling)
    }
}

private struct MergedPullRequestFixture: GitHubIssueTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let payload: String
        if url.path.hasSuffix("/pulls/7") {
            let sha = String(repeating: "a", count: 40)
            payload = #"{"merged":true,"head":{"sha":"\#(sha)"}}"#
        } else if url.path.hasSuffix("/check-runs") {
            payload = #"{"check_runs":[]}"#
        } else if url.path.hasSuffix("/status") {
            payload = #"{"state":"success"}"#
        } else {
            payload = "[]"
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(payload.utf8), response)
    }
}
