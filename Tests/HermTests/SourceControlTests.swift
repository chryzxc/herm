import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

struct SourceControlTests {
    @Test func stagingAndCommittingPreserveUnstagedContentAndLiteralPaths() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("original\n", "file [1].txt", in: root)
        try write("other\n", "file 1.txt", in: root)
        var snapshot = await RepositoryService.changeSnapshot(path: root.path)
        let literal = try #require(snapshot.files.first { $0.path == "file [1].txt" })
        #expect(await RepositoryService.applySourceControl(.stage([literal]), path: root.path) == nil)
        snapshot = await RepositoryService.changeSnapshot(path: root.path)
        #expect(snapshot.stagedCount == 1)
        #expect(snapshot.files.first { $0.isStaged }?.path == "file [1].txt")
        #expect(
            await RepositoryService.applySourceControl(.unstage(snapshot.files.filter(\.isStaged)), path: root.path)
                == nil)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(literal.path).path))
        #expect(await RepositoryService.changeSnapshot(path: root.path).stagedCount == 0)
        #expect(await RepositoryService.applySourceControl(.stage([literal]), path: root.path) == nil)
        #expect(await RepositoryService.applySourceControl(.commit("Initial commit"), path: root.path) == nil)
        try write("staged version\n", literal.path, in: root)
        snapshot = await RepositoryService.changeSnapshot(path: root.path)
        let modified = try #require(snapshot.files.first { $0.path == literal.path })
        #expect(modified.status == .modified && !modified.isStaged)
        #expect(await RepositoryService.applySourceControl(.stage([modified]), path: root.path) == nil)
        try write("unstaged version\n", literal.path, in: root)
        snapshot = await RepositoryService.changeSnapshot(path: root.path)
        #expect(snapshot.files.filter { $0.path == literal.path }.count == 2)
        #expect(await RepositoryService.applySourceControl(.commit("Staged only"), path: root.path) == nil)
        #expect(try git(root, ["show", "HEAD:file [1].txt"]) == "staged version\n")
        #expect(
            try String(contentsOf: root.appendingPathComponent(literal.path), encoding: .utf8) == "unstaged version\n")
        #expect(await RepositoryService.applySourceControl(.commit("Nothing staged"), path: root.path) != nil)
        #expect(await RepositoryService.applySourceControl(.commit(" \n"), path: root.path) != nil)
        let invalid = RepositoryFileChange(path: "../outside", status: .untracked, isStaged: false, renameSource: nil)
        #expect(await RepositoryService.applySourceControl(.stage([invalid]), path: root.path) != nil)
    }

    @Test func unstageRenameAndDeletionKeepsWorkingFiles() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("rename me\n", "old.txt", in: root)
        try write("delete me\n", "deleted.txt", in: root)
        _ = try git(root, ["add", "."])
        _ = try git(root, ["commit", "-qm", "Initial"])
        _ = try git(root, ["mv", "old.txt", "new name.txt"])
        _ = try git(root, ["rm", "deleted.txt"])
        let snapshot = await RepositoryService.changeSnapshot(path: root.path)
        #expect(snapshot.files.contains { $0.status == .renamed && $0.renameSource == "old.txt" })
        #expect(await RepositoryService.applySourceControl(.unstage(snapshot.files), path: root.path) == nil)
        #expect(await RepositoryService.changeSnapshot(path: root.path).stagedCount == 0)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("new name.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("old.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("deleted.txt").path))
    }

    @Test func historyFollowsSelectedBranchAndUnbornBranchesAreEmpty() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await RepositoryService.recentCommits(path: root.path) == [])
        try write("base\n", "file.txt", in: root)
        _ = try git(root, ["add", "."])
        _ = try git(root, ["commit", "-qm", "Base"])
        _ = try git(root, ["switch", "-qc", "feature"])
        try write("feature\n", "file.txt", in: root)
        _ = try git(root, ["commit", "-qam", "Feature change"])
        let feature = try #require(await RepositoryService.recentCommits(path: root.path))
        #expect(feature.map(\.subject) == ["Feature change", "Base"])
        #expect(feature.first?.author == "Source Control Tests")
        #expect(feature.first?.references.contains("feature") == true)
        _ = try git(root, ["switch", "-q", "main"])
        #expect(await RepositoryService.recentCommits(path: root.path)?.map(\.subject) == ["Base"])
        _ = try git(root, ["switch", "--detach", "-q", feature[0].id])
        #expect(await RepositoryService.recentCommits(path: root.path)?.first?.id == feature[0].id)
        #expect(RepositoryService.parseCommits("broken\0message\0author\0invalid\0refs\0parents\0").isEmpty)
        #expect(feature.first?.parents == [feature[1].id])
        #expect(feature.last?.parents == [])
        let detail = try #require(await RepositoryService.commitDetail(path: root.path, hash: feature[0].id))
        #expect(detail.body == "Feature change")
        #expect(detail.files == [RepositoryCommitDetail.File(path: "file.txt", additions: 1, deletions: 1)])
    }

    @Test func discardRestoresWorkingTreeFromIndexAndIgnoreAppendsAnchoredEntries() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("base\n", "file [1].txt", in: root)
        _ = try git(root, ["add", "."])
        _ = try git(root, ["commit", "-qm", "Base"])
        try write("staged\n", "file [1].txt", in: root)
        _ = try git(root, ["add", "."])
        try write("unstaged\n", "file [1].txt", in: root)
        var snapshot = await RepositoryService.changeSnapshot(path: root.path)
        #expect(
            await RepositoryService.applySourceControl(.discard(snapshot.files.filter(\.isStaged)), path: root.path)
                != nil)
        #expect(
            await RepositoryService.applySourceControl(
                .discard(snapshot.files.filter { !$0.isStaged }), path: root.path) == nil)
        // Only the unstaged edit is dropped; the staged version survives.
        #expect(try String(contentsOf: root.appendingPathComponent("file [1].txt"), encoding: .utf8) == "staged\n")
        snapshot = await RepositoryService.changeSnapshot(path: root.path)
        #expect(snapshot.files.map(\.isStaged) == [true])

        try write("secret\n", "notes*.txt", in: root)
        let untracked = try #require(
            await RepositoryService.changeSnapshot(path: root.path).files.first { $0.status == .untracked })
        #expect(await RepositoryService.applySourceControl(.ignore([untracked]), path: root.path) == nil)
        #expect(await RepositoryService.applySourceControl(.ignore([untracked]), path: root.path) == nil)
        #expect(try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8) == "/notes\\*.txt\n")
        #expect(
            await RepositoryService.changeSnapshot(path: root.path).files.map(\.path).sorted() == [
                ".gitignore", "file [1].txt",
            ])
        #expect(RepositoryService.gitignorePattern("dir/a [b]?.md ") == "/dir/a \\[b]\\?.md\\ ")
    }

    @Test func commitDetailParsesBodyEmailAndBinaryFiles() {
        let detail = RepositoryService.parseCommitDetail(
            "Subject\n\nBody line\n\0me@example.com\0\n\n3\t1\tsrc/a.swift\n-\t-\timage.png\n")
        #expect(detail?.body == "Subject\n\nBody line")
        #expect(detail?.email == "me@example.com")
        #expect(
            detail?.files == [
                .init(path: "src/a.swift", additions: 3, deletions: 1),
                .init(path: "image.png", additions: nil, deletions: nil),
            ])
        #expect(RepositoryService.parseCommitDetail("no separators") == nil)
    }

    @Test func graphKeepsBranchesInSeparateLanesUntilTheyMerge() {
        func commit(_ id: String, _ parents: [String]) -> RepositoryCommit {
            RepositoryCommit(id: id, subject: id, author: "", date: .now, references: "", parents: parents)
        }
        // merge(m) of feature(f) into main(c); both fork from base(a).
        let rows = RepositoryCommitGraph.layout([
            commit("m", ["c", "f"]), commit("f", ["a"]), commit("c", ["a"]), commit("a", []),
        ])
        #expect(rows.map(\.lane) == [0, 1, 0, 0])
        #expect(rows[0].top.isEmpty)
        #expect(rows[0].bottom.map { [$0.from, $0.to] } == [[0, 0], [0, 1]])
        #expect(rows[1].color != rows[0].color)
        // Both branch lanes converge into the base commit.
        #expect(rows[3].top.map { [$0.from, $0.to] } == [[0, 0], [1, 0]])
        #expect(rows[3].bottom.isEmpty)
        #expect(rows.map(\.width) == [2, 2, 2, 2])
    }

    @Test func decorationsMergeSyncedRemotesAndPutHeadFirst() {
        let references = RepositoryCommitReference.parse(
            "tag: refs/tags/v1.0, refs/remotes/origin/feature/x, HEAD -> refs/heads/main, refs/remotes/origin/main, refs/remotes/origin/HEAD, refs/heads/feature/y"
        )
        #expect(references.map(\.name) == ["main", "feature/y", "origin/feature/x", "v1.0"])
        #expect(references[0].isHead && references[0].isSynced)
        #expect(!references[1].isSynced)
        #expect(references[3].kind == .tag)
        #expect(RepositoryCommitReference.parse("HEAD").first?.isHead == true)
    }

    @Test func conflictsStayInChangesAndCannotBeCommitted() async throws {
        let parsed = RepositoryService.parsePorcelainV1("UU both.txt\0AA added.txt\0DD deleted.txt\0")
        #expect(parsed.count == 3)
        #expect(parsed.allSatisfy { $0.status == .conflicted && !$0.isStaged })
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("base\n", "file.txt", in: root)
        _ = try git(root, ["add", "."])
        _ = try git(root, ["commit", "-qm", "Base"])
        _ = try git(root, ["switch", "-qc", "feature"])
        try write("feature\n", "file.txt", in: root)
        _ = try git(root, ["commit", "-qam", "Feature"])
        _ = try git(root, ["switch", "-q", "main"])
        try write("main\n", "file.txt", in: root)
        _ = try git(root, ["commit", "-qam", "Main"])
        _ = try git(root, ["merge", "feature"], expectedExit: 1)
        #expect(await RepositoryService.applySourceControl(.commit("Unresolved"), path: root.path) != nil)
    }

    @MainActor @Test func renderSourceControlWhenRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["SOURCE_CONTROL_SNAPSHOT_DIR"] else { return }
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("# Project\n", "README.md", in: root)
        try write("let value = 1\n", "App.swift", in: root)
        _ = try git(root, ["add", "."])
        _ = try git(root, ["commit", "-qm", "Build the workspace shell"])
        try write("Saved draft\n", "draft.md", in: root)
        #expect(
            await RepositoryService.createStash(
                path: root.path, message: "Save work in progress", includeUntracked: true) == nil)
        try write("# Project\nNew instructions\n", "README.md", in: root)
        _ = try git(root, ["add", "README.md"])
        try write("let value = 2\n", "App.swift", in: root)
        try write("draft\n", "notes.md", in: root)
        let workflow = DeveloperWorkflowModel()
        let control = ControlCenterModel()
        let suite = "SourceControlTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CommandCenterPreferencesStore(defaults: defaults)
        await workflow.setActiveRepository(path: root.path, preferences: preferences, control: control)
        let model = DockModel()
        defer { model.shutdown() }
        let view = ScrollView {
            RepositoryChangesBrowser(
                model: model, workflow: workflow, projectPath: root.path, onRefresh: {}, isInspector: true
            )
            .padding(12)
        }.frame(width: 440, height: 700).background(Color.dockCanvas)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("source-control.png"))
    }

    @Test func stashRoundTripRestoresIndexWorkingTreeAndUntrackedFiles() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("base\n", "file.txt", in: root)
        _ = try git(root, ["add", "."])
        _ = try git(root, ["commit", "-qm", "Base"])
        try write("staged\n", "file.txt", in: root)
        _ = try git(root, ["add", "."])
        try write("working\n", "file.txt", in: root)
        try write("draft\n", "untracked.txt", in: root)
        #expect(
            await RepositoryService.applySourceControl(
                .createStash(message: "Draft with spaces", includeUntracked: true), path: root.path) == nil)
        #expect(await RepositoryService.changeSnapshot(path: root.path).files.isEmpty)
        let stashes = try #require(await RepositoryService.stashes(path: root.path))
        let stash = try #require(stashes.first)
        #expect(stashes.count == 1)
        #expect(stash.subject.contains("Draft with spaces"))
        let preview = try #require(await RepositoryService.stashDiff(path: root.path, stash: stash))
        #expect(preview.text.contains("+working"))
        #expect(preview.text.contains("+draft"))
        #expect(await RepositoryService.applySourceControl(.updateStash(stash, .apply), path: root.path) == nil)
        #expect(try git(root, ["show", ":file.txt"]) == "staged\n")
        #expect(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8) == "working\n")
        #expect(try String(contentsOf: root.appendingPathComponent("untracked.txt"), encoding: .utf8) == "draft\n")
        #expect(await RepositoryService.stashes(path: root.path)?.count == 1)
        #expect(await RepositoryService.applySourceControl(.updateStash(stash, .drop), path: root.path) == nil)
        #expect(await RepositoryService.stashes(path: root.path) == [])
        #expect(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8) == "working\n")
        #expect(await RepositoryService.applySourceControl(.updateStash(stash, .apply), path: root.path) != nil)
    }

    @Test func stashPopUsesSelectedHashAfterIndicesMoveAndPreservesStashOnConflict() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("base\n", "file.txt", in: root)
        _ = try git(root, ["add", "."])
        _ = try git(root, ["commit", "-qm", "Base"])
        try write("first\n", "file.txt", in: root)
        #expect(await RepositoryService.createStash(path: root.path, message: "First", includeUntracked: false) == nil)
        let firstEntries = try #require(await RepositoryService.stashes(path: root.path))
        let first = try #require(firstEntries.first)
        try write("second\n", "file.txt", in: root)
        #expect(await RepositoryService.createStash(path: root.path, message: "Second", includeUntracked: false) == nil)
        #expect(await RepositoryService.updateStash(path: root.path, stash: first, operation: .pop) == nil)
        #expect(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8) == "first\n")
        let remaining = try #require(await RepositoryService.stashes(path: root.path))
        #expect(remaining.count == 1)
        let second = try #require(remaining.first)
        #expect(second.subject.contains("Second"))
        #expect(await RepositoryService.updateStash(path: root.path, stash: second, operation: .pop) != nil)
        #expect(await RepositoryService.stashes(path: root.path) == remaining)
        #expect(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8) == "first\n")
        _ = try git(root, ["restore", "--worktree", "--", "file.txt"])
        try write("divergent commit\n", "file.txt", in: root)
        _ = try git(root, ["commit", "-qam", "Diverge"])
        #expect(await RepositoryService.updateStash(path: root.path, stash: second, operation: .pop) != nil)
        #expect(await RepositoryService.stashes(path: root.path) == remaining)
        #expect(await RepositoryService.changeSnapshot(path: root.path).files.contains { $0.status == .conflicted })
    }

    @Test func stashCanLeaveUntrackedFilesAndRejectsMalformedEntries() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("base\n", "file.txt", in: root)
        _ = try git(root, ["add", "."])
        _ = try git(root, ["commit", "-qm", "Base"])
        try write("change\n", "file.txt", in: root)
        try write("draft\n", "draft.txt", in: root)
        #expect(await RepositoryService.createStash(path: root.path, message: "", includeUntracked: false) == nil)
        #expect(await RepositoryService.changeSnapshot(path: root.path).files.map(\.path) == ["draft.txt"])
        #expect(RepositoryService.parseStashes("") == [])
        #expect(RepositoryService.parseStashes("broken\0entry\0") == nil)
        let invalid = RepositoryStash(hash: "--all", reference: "stash@{0}", subject: "Invalid", date: .now)
        #expect(await RepositoryService.updateStash(path: root.path, stash: invalid, operation: .drop) != nil)
        #expect(await RepositoryService.stashDiff(path: root.path, stash: invalid) == nil)
        #expect(
            await RepositoryService.createStash(path: root.path, message: "bad\0message", includeUntracked: false)
                != nil)
    }

    @MainActor @Test func stashMutationsRefreshWorkflowAndClearOnRepositorySwitch() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("base\n", "file.txt", in: root)
        _ = try git(root, ["add", "."])
        _ = try git(root, ["commit", "-qm", "Base"])
        try write("work\n", "file.txt", in: root)
        let suite = "SourceControlTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CommandCenterPreferencesStore(defaults: defaults)
        let workflow = DeveloperWorkflowModel()
        let control = ControlCenterModel()
        await workflow.setActiveRepository(path: root.path, preferences: preferences, control: control)
        #expect(
            await workflow.applySourceControl(
                .createStash(message: "Workflow draft", includeUntracked: true), path: root.path,
                refresh: {
                    await workflow.refresh(preferences: preferences, control: control)
                }))
        #expect(workflow.stashes.count == 1)
        #expect(workflow.stashesError == nil)
        #expect(workflow.changes?.files.isEmpty == true)
        let stash = try #require(workflow.stashes.first)
        #expect(
            await workflow.applySourceControl(
                .updateStash(stash, .pop), path: root.path,
                refresh: {
                    await workflow.refresh(preferences: preferences, control: control)
                }))
        #expect(workflow.stashes.isEmpty)
        #expect(workflow.changes?.files.map(\.path) == ["file.txt"])
        #expect(
            await workflow.applySourceControl(
                .createStash(message: "Before switching", includeUntracked: false), path: root.path,
                refresh: {
                    await workflow.refresh(preferences: preferences, control: control)
                }))
        #expect(workflow.stashes.count == 1)
        await workflow.setActiveRepository(path: nil, preferences: preferences, control: control)
        #expect(workflow.stashes.isEmpty)
        #expect(workflow.stashesError == nil)
    }

    private func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herm-source-control-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try git(root, ["init", "-q", "-b", "main"])
        _ = try git(root, ["config", "user.name", "Source Control Tests"])
        _ = try git(root, ["config", "user.email", "source-control@example.invalid"])
        _ = try git(root, ["config", "commit.gpgsign", "false"])
        _ = try git(root, ["config", "core.hooksPath", "/dev/null"])
        return root
    }

    private func write(_ text: String, _ file: String, in root: URL) throws {
        try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    @discardableResult private func git(_ root: URL, _ arguments: [String], expectedExit: Int32 = 0) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == expectedExit)
        return String(decoding: data, as: UTF8.self)
    }
}
