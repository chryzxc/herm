import Foundation
import Testing

@testable import Herm

@MainActor
struct RepositoryComparisonServiceTests {
    @Test func comparisonsResolveReferencesAndDetectChangedContents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herm-comparison-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ arguments: [String]) async throws {
            let result = await RepositoryService.runGit(path: directory.path, arguments: arguments)
            #expect(result.exitCode == 0)
        }
        try await git(["init"])
        try await git(["config", "user.name", "Fixture"])
        try await git(["config", "user.email", "fixture@example.invalid"])
        let file = directory.appendingPathComponent("example.swift")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["add", "example.swift"])
        try await git(["commit", "-m", "fixture"])
        try "let value = 2\n".write(to: file, atomically: true, encoding: .utf8)
        let working = try await RepositoryComparisonService.load(
            path: directory.path, scope: .working, reference: "HEAD", ignoreWhitespace: false)
        #expect(working.files == ["example.swift"])
        let diff = try await RepositoryComparisonService.patch(
            path: directory.path, file: "example.swift", comparison: working)
        #expect(diff.text.contains("+let value = 2"))
        let before = await RepositoryComparisonService.fingerprint(directory.path)
        try "let value = 3\n".write(to: file, atomically: true, encoding: .utf8)
        let after = await RepositoryComparisonService.fingerprint(directory.path)
        #expect(before != after)
        await #expect(throws: (any Error).self) {
            try await RepositoryComparisonService.expandedPatch(
                path: directory.path, file: "example.swift", arguments: working.arguments, original: diff.text,
                lines: 23)
        }
        let untracked = directory.appendingPathComponent("untracked.txt")
        try "first".write(to: untracked, atomically: true, encoding: .utf8)
        let untrackedBefore = await RepositoryComparisonService.fingerprint(directory.path)
        try "other".write(to: untracked, atomically: true, encoding: .utf8)
        #expect(untrackedBefore != (await RepositoryComparisonService.fingerprint(directory.path)))
        let commit = try await RepositoryComparisonService.load(
            path: directory.path, scope: .commit, reference: "HEAD", ignoreWhitespace: false)
        #expect(commit.files.contains("example.swift"))
        #expect(commit.revision.count >= 40)
    }

    @Test func renameMetadataUsesBothSafePaths() {
        let changes = RepositoryComparisonService.namedChanges("R100\0old name.swift\0new name.swift\0M\0other.swift\0")
        #expect(changes.paths == ["new name.swift", "other.swift"])
        #expect(changes.renames["new name.swift"] == "old name.swift")
        #expect(RepositoryComparisonService.namedChanges("R100\0../outside\0inside\0").paths.isEmpty)
    }

    @Test func wordChangesTrackSequenceRatherThanWordMembership() {
        let text = "value value changed"
        let ranges = DiffDocument.changedWordRanges(text, comparedWith: "value changed value")
        #expect(!ranges.isEmpty)
        #expect(ranges.allSatisfy { $0.location + $0.length <= (text as NSString).length })
    }
}
