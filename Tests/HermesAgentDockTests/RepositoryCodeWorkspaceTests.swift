import Foundation
import Testing
@testable import HermesAgentDock

struct RepositoryCodeWorkspaceTests {
    @Test func documentURLStaysWithinTheSelectedRepository() {
        #expect(RepositoryService.documentURL(repositoryPath: "/workspace/project", filePath: "Sources/App.swift")?.path == "/workspace/project/Sources/App.swift")
        #expect(RepositoryService.documentURL(repositoryPath: "/workspace/project", filePath: "../outside.swift") == nil)
        #expect(RepositoryService.documentURL(repositoryPath: "/workspace/project", filePath: "/outside.swift") == nil)
    }

    @Test func documentSizeLimitIsExplicit() {
        #expect(RepositoryService.maxDocumentBytes == 256_000)
    }

    @Test func blameModeHasExplicitLineBound() {
        #expect(RepositoryService.maxBlameLines == 10_000)
    }

    @Test func parsesPorcelainBlameWithRepeatedMetadataAndBlankLines() {
        let committedHash = String(repeating: "a", count: 40)
        let output = """
        \(committedHash) 1 1 2
        author Ada Lovelace
        author-time 1700000000
        author-tz +0000
        summary Add parser
        filename Sources/App.swift
        \tlet first = true
        \(committedHash) 2 2 1
        author Ada Lovelace
        author-time 1700000000
        author-tz +0000
        summary Add parser
        filename Sources/App.swift
        \t
        \(String(repeating: "0", count: 40)) 3 3 1
        author Working Tree
        author-time 1700000000
        author-tz +0000
        summary Temporary change
        filename Sources/App.swift
        \tlet changed = true
        """

        let document = RepositoryService.parseBlamePorcelain(output, path: "Sources/App.swift")

        #expect(document?.path == "Sources/App.swift")
        #expect(document?.lines.count == 3)
        #expect(document?.lines[0].commit.author == "Ada Lovelace")
        #expect(document?.lines[0].commit.summary == "Add parser")
        #expect(document?.lines[1].text.isEmpty == true)
        #expect(document?.lines[2].commit.isUncommitted == true)
        #expect(document?.lines[2].commit.author == "Not committed yet")
        #expect(document?.lines[2].commit.summary == "Working tree changes")
    }

    @Test func malformedBlamePorcelainIsRejected() {
        #expect(RepositoryService.parseBlamePorcelain("not porcelain output", path: "App.swift") == nil)
        #expect(RepositoryService.parseBlamePorcelain("abc 1 1 1\nauthor Missing source", path: "App.swift") == nil)
    }

    @Test func blameRejectsUnsafePathsWithoutRunningGit() async {
        let absolute = await RepositoryService.blame(path: "/tmp/project", filePath: "/etc/passwd")
        let traversal = await RepositoryService.blame(path: "/tmp/project", filePath: "../outside.swift")

        #expect(absolute == .unavailable("Blame is unavailable for this file path."))
        #expect(traversal == .unavailable("Blame is unavailable for this file path."))
    }

    @Test func blameReturnsSafeUnavailableResultForMissingRepository() async {
        let result = await RepositoryService.blame(path: "/tmp/does-not-exist", filePath: "App.swift")

        #expect(result == .unavailable("Blame is unavailable for untracked, binary, or non-Git files."))
    }

    @Test func blameRejectsFilesOverTheLineLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-blame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("Large.swift")
        try String(repeating: "let value = true\n", count: RepositoryService.maxBlameLines + 1)
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(runGit(path: root.path, arguments: ["init", "-q"]))
        #expect(runGit(path: root.path, arguments: ["config", "user.email", "tests@example.com"]))
        #expect(runGit(path: root.path, arguments: ["config", "user.name", "Hermes Tests"]))
        #expect(runGit(path: root.path, arguments: ["add", "Large.swift"]))
        #expect(runGit(path: root.path, arguments: ["commit", "-qm", "large fixture"]))

        let result = await RepositoryService.blame(path: root.path, filePath: "Large.swift")

        #expect(result == .unavailable("Blame is unavailable for files over 10,000 lines."))
    }

    @Test func blameReadsTrackedWorkingTreeContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-blame-tracked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Title\n\nTracked content\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        #expect(runGit(path: root.path, arguments: ["init", "-q"]))
        #expect(runGit(path: root.path, arguments: ["config", "user.email", "tests@example.com"]))
        #expect(runGit(path: root.path, arguments: ["config", "user.name", "Hermes Tests"]))
        #expect(runGit(path: root.path, arguments: ["add", "README.md"]))
        #expect(runGit(path: root.path, arguments: ["commit", "-qm", "tracked README"]))

        let result = await RepositoryService.blame(path: root.path, filePath: "README.md")

        guard case .available(let document) = result else {
            Issue.record("Expected tracked README blame to be available, got \(result)")
            return
        }
        #expect(document.lines.map(\.text) == ["# Title", "", "Tracked content"])
    }

    private func runGit(path: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

}
