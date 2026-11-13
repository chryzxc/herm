import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct WorktreeChooserRenderTests {
    @Test func chooserRetainsItsSizeWithManyLongWorktrees() throws {
        _ = NSApplication.shared
        let trees = (0..<30).map { index in
            let path = "/tmp/repository/worktree-\(index)"
            return RepositoryWorktreeSummary(
                path: path, displayName: "worktree-\(index)-with-a-long-descriptive-name",
                branch: "feature/very-long-worktree-branch-\(index)", headRevision: "123456789abc",
                isDetached: false, isLocked: false, isPrunable: false,
                snapshot: RepositorySnapshot(
                    path: path, branch: "feature/test", changedFiles: index, latestCommit: "",
                    isGitRepository: true))
        }
        let oldTheme = DockThemeRuntime.current
        defer {
            DockThemeRuntime.current = oldTheme
            DockThemeRuntime.revision &+= 1
        }
        for theme in [DockThemeID.glass, .clean, .mono] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            let host = NSHostingView(
                rootView: WorktreeChooserPanel(
                    worktrees: trees, selection: trees[0].path, unavailable: false, canStartTask: true,
                    onSelect: { _ in }, onCreate: {}
                ).background(Color.dockOpaqueCanvas).dockThemedRoot())
            host.frame = CGRect(x: 0, y: 0, width: 340, height: 440)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width == 340)
            #expect(host.fittingSize.height == 440)
            if let directory = ProcessInfo.processInfo.environment["HERM_WORKTREE_UI_DIR"] {
                let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                let data = try #require(image.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("worktrees-\(theme).png"))
            }
        }
    }

    @Test func chatChoiceKeepsThePopoverSizeInEveryMoveState() throws {
        _ = NSApplication.shared
        let path = "/tmp/repository/feature-move"
        let tree = RepositoryWorktreeSummary(
            path: path, displayName: "feature-move", branch: "feature/move-chat", headRevision: "123456789abc",
            isDetached: false, isLocked: false, isPrunable: false,
            snapshot: RepositorySnapshot(
                path: path, branch: "feature/move-chat", changedFiles: 2, latestCommit: "", isGitRepository: true))
        let oldTheme = DockThemeRuntime.current
        defer {
            DockThemeRuntime.current = oldTheme
            DockThemeRuntime.revision &+= 1
        }
        for theme in [DockThemeID.glass, .clean, .mono] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for canMove in [true, false] {
                let host = NSHostingView(
                    rootView: WorktreeChatChoice(
                        tree: tree, currentName: "herm", canMove: canMove,
                        onBack: {}, onMove: {}, onNewChat: {}
                    ).frame(width: 340, height: 440).background(Color.dockOpaqueCanvas).dockThemedRoot())
                host.frame = CGRect(x: 0, y: 0, width: 340, height: 440)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.width == 340)
                #expect(host.fittingSize.height == 440)
                if let directory = ProcessInfo.processInfo.environment["HERM_WORKTREE_UI_DIR"] {
                    let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: image)
                    let data = try #require(image.representation(using: .png, properties: [:]))
                    let name = "worktree-choice-\(theme)-\(canMove ? "ready" : "busy").png"
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                }
            }
        }
    }
}
