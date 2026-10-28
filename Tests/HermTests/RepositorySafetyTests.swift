import Foundation
import Testing

@testable import Herm

struct RepositorySafetyTests {
    private func repository() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herm-safety-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(await RepositoryService.runGit(path: root.path, arguments: ["init", "--quiet"]).exitCode == 0)
        return root
    }

    @Test func subfolderStagingAndUnstagingUseRootRelativePaths() async throws {
        let root = try await repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(
            at: sub.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for path in ["sub/file.txt", "sub/sub/file.txt"] {
            try Data(path.utf8).write(to: root.appendingPathComponent(path))
        }
        let changes = await RepositoryService.changeSnapshot(path: sub.path)
        let selected = try #require(changes.files.first { $0.path == "sub/file.txt" })
        let preview = try #require(await RepositoryService.diff(path: sub.path, file: selected))
        #expect(preview.text.contains("+sub/file.txt"))
        #expect(!preview.text.contains("+sub/sub/file.txt"))
        #expect(await RepositoryService.applySourceControl(.stage([selected]), path: sub.path) == nil)
        let staged = await RepositoryService.changeSnapshot(path: sub.path).files.filter(\.isStaged)
        #expect(staged.map(\.path) == ["sub/file.txt"])
        #expect(await RepositoryService.applySourceControl(.unstage(staged), path: sub.path) == nil)
        #expect(await RepositoryService.changeSnapshot(path: root.path).stagedCount == 0)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sub/file.txt").path))
    }

    @Test func unreadableStatusCannotBecomeCleanOrReviewed() async throws {
        let root = try await repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("invalid".utf8).write(to: root.appendingPathComponent(".git/index"))
        let changes = await RepositoryService.changeSnapshot(path: root.path)
        let snapshot = await RepositoryService.inspect(path: root.path)
        #expect(changes.error != nil)
        #expect(snapshot.isGitRepository && snapshot.isStale)
        #expect(snapshot.workingTreeSummary == "Git status unavailable")
        #expect(await RepositoryService.review(path: root.path) == nil)
        #expect(await RepositoryService.fingerprint(path: root.path) == nil)
    }

    @Test func invalidUTF8IgnoreFileIsPreserved() async throws {
        let root = try await repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data([0x23, 0xff, 0x0a])
        let ignore = root.appendingPathComponent(".gitignore")
        try original.write(to: ignore)
        let file = RepositoryFileChange(path: "notes.txt", status: .untracked, isStaged: false, renameSource: nil)
        #expect(await RepositoryService.applySourceControl(.ignore([file]), path: root.path) != nil)
        #expect(try Data(contentsOf: ignore) == original)
    }

    @Test func fileSaveChecksTheLoadedContentsAndPreservesExternalEdits() async throws {
        let root = try await repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.txt")
        try Data("initial".utf8).write(to: file)
        let document = try #require(await RepositoryService.loadDocument(path: root.path, filePath: "source.txt"))
        try Data("external edit".utf8).write(to: file)
        #expect(
            await RepositoryService.saveDocument(
                path: root.path, filePath: document.path, contents: "my edit", expectedContents: document.contents)
                == false)
        #expect(try String(contentsOf: file, encoding: .utf8) == "external edit")
        #expect(
            await RepositoryService.saveDocument(
                path: root.path, filePath: document.path, contents: "merged edit", expectedContents: "external edit"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "merged edit")
    }

    @Test func ignoreDoesNotReadOrReplaceASymlinkTarget() async throws {
        let root = try await repository()
        let outside = root.deletingLastPathComponent().appendingPathComponent("herm-external-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let original = Data("external configuration".utf8)
        try original.write(to: outside)
        let ignore = root.appendingPathComponent(".gitignore")
        try FileManager.default.createSymbolicLink(at: ignore, withDestinationURL: outside)
        let file = RepositoryFileChange(path: "notes.txt", status: .untracked, isStaged: false, renameSource: nil)
        #expect(await RepositoryService.applySourceControl(.ignore([file]), path: root.path) != nil)
        #expect(try Data(contentsOf: outside) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: ignore.path) == outside.path)
    }

    @Test func saveCompletionAndRefreshKeepNewerDraftText() {
        var draft = RepositoryEditorDraft("initial")
        draft.text = "save snapshot"
        let snapshot = draft.text
        draft.text = "typed while saving"
        draft.receive(snapshot)
        draft.didSave(snapshot)
        #expect(draft.text == "typed while saving" && draft.isDirty)
        #expect(draft.savedContents == snapshot)
        draft.receive("external change")
        #expect(draft.text == "typed while saving" && draft.savedContents == snapshot)
        draft.didSave(draft.text)
        draft.receive("fresh disk contents")
        #expect(draft.text == "fresh disk contents" && !draft.isDirty)
    }

    @Test func oversizedFilesAreRejectedByABoundedRead() async throws {
        let root = try await repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.txt")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1_024 * 1_024 * 1_024)
        try handle.close()
        #expect(await RepositoryService.loadDocument(path: root.path, filePath: "large.txt") == nil)
    }

    @Test func gitCommandsHaveDeadlinesCancellationAndOutputLimits() async throws {
        let root = try await repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let arguments = ["-c", "alias.wait=!sleep 30", "wait"]
        let started = Date()
        #expect(await RepositoryService.runGit(path: root.path, arguments: arguments, timeout: 0.2).exitCode != 0)
        let task = Task { await RepositoryService.runGit(path: root.path, arguments: arguments) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        #expect(await task.value.exitCode != 0)
        #expect(Date().timeIntervalSince(started) < 5)
        let large = await RepositoryService.runGit(
            path: root.path, arguments: ["-c", "alias.large=!printf %04096d 0", "large"], maxOutputBytes: 1024)
        #expect(large.exitCode != 0 && large.output.isEmpty)
    }
}
