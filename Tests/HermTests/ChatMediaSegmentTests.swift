import Foundation
import Testing
@testable import Herm

struct ChatMediaSegmentTests {
    @Test @MainActor func openingAttachmentDiffReplacesFilePreviewAndKeepsItsOwnWorktree() {
        let center = FilePreviewCenter(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        center.url = URL(fileURLWithPath: "/tmp/report.md")
        let files = [
            RepositoryFileChange(path: "src/main.swift", status: .modified, isStaged: true, renameSource: nil),
            RepositoryFileChange(path: "src/main.swift", status: .deleted, isStaged: false, renameSource: nil),
        ]
        center.openDiff(RepositoryAttachmentChanges(repositoryPath: "/tmp/other-worktree", files: files))
        #expect(center.url == nil)
        #expect(center.attachmentDiff?.repositoryPath == "/tmp/other-worktree")
        #expect(center.attachmentDiff?.files == files)
        center.url = URL(fileURLWithPath: "/tmp/report.md")
        #expect(center.attachmentDiff == nil)
    }

    @Test func attachmentDiffUsesExactGitFileAndBothChangeScopes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try git(["init"])
        let file = root.appendingPathComponent("FloatingChatOverlays.spec.js")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "Initial"])
        #expect(await RepositoryService.attachmentChanges(url: file) == nil)
        try "staged\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."])
        try "working\n".write(to: file, atomically: true, encoding: .utf8)
        let changes = try #require(await RepositoryService.attachmentChanges(url: file))
        #expect(changes.files.count == 2)
        for change in changes.files {
            let diff = try #require(await RepositoryService.diff(path: changes.repositoryPath, file: change))
            #expect(diff.text.contains(change.isStaged ? "+staged" : "+working"))
        }
        let newFile = root.appendingPathComponent("floating-dom-check.cjs")
        try "new code\n".write(to: newFile, atomically: true, encoding: .utf8)
        let added = try #require(await RepositoryService.attachmentChanges(url: newFile))
        #expect(added.files.first?.status == .untracked)
        let diff = await RepositoryService.diff(path: added.repositoryPath, file: added.files[0])
        #expect(diff?.text.contains("+new code") == true)
        #expect(await RepositoryService.attachmentChanges(url: root.appendingPathComponent("other.spec.js")) == nil)
        #expect(await RepositoryService.attachmentChanges(url: URL(string: "https://example.com/file.js")!) == nil)
        try FileManager.default.removeItem(at: file)
        #expect(await RepositoryService.attachmentChanges(url: file)?.files.contains { $0.status == .deleted } == true)
    }

    @Test func standaloneMarkdownImageBecomesMedia() {
        #expect(ChatMediaSegment.split("Here:\n![dog](/tmp/dog.png)\nDone") == [
            .markdown("Here:"), .media("/tmp/dog.png"), .markdown("Done"),
        ])
    }

    @Test func producerToolResultsDeliverFiles() {
        func call(_ name: String, _ result: String) -> ActiveToolCall {
            ActiveToolCall(id: name, name: name, input: "", context: "", startedAt: .now, result: result, isComplete: true)
        }
        #expect(ArtifactService.deliveredFiles(in: [
            call("image_generate", #"{"success": true, "image": "https://x.test/dog.png"}"#),
            call("text_to_speech", "MEDIA:/tmp/a.mp3"),
            call("read_file", #"{"path": "/tmp/src.swift"}"#),
        ]) == ["https://x.test/dog.png", "/tmp/a.mp3"])
    }

    @Test func splitsMediaLinesIntoAttachments() {
        let text = "The file is here:\nMEDIA:/Users/me/report.docx\nTap the attachment above to download it."
        #expect(ChatMediaSegment.split(text) == [
            .markdown("The file is here:"),
            .media("/Users/me/report.docx"),
            .markdown("Tap the attachment above to download it."),
        ])
    }

    @Test func leavesInlineMentionsAndPlainTextAlone() {
        let text = "Use a `MEDIA:` tag like MEDIA:/tmp/x.png to deliver files."
        #expect(ChatMediaSegment.split(text) == [.markdown(text)])
        #expect(ChatMediaSegment.split("hello") == [.markdown("hello")])
    }

    @Test func stripsQuotesAroundPaths() {
        #expect(ChatMediaSegment.split("MEDIA: \"/tmp/a b.pdf\"") == [.media("/tmp/a b.pdf")])
    }
}
