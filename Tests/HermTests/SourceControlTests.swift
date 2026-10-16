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
        #expect(await RepositoryService.applySourceControl(.unstage(snapshot.files.filter(\.isStaged)), path: root.path) == nil)
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
        #expect(try String(contentsOf: root.appendingPathComponent(literal.path), encoding: .utf8) == "unstaged version\n")
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
        #expect(RepositoryService.parseCommits("broken\0message\0author\0invalid\0refs\0").isEmpty)
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
            RepositoryChangesBrowser(model: model, workflow: workflow, projectPath: root.path, onRefresh: {}, isInspector: true)
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
