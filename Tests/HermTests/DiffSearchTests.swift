import Foundation
import Testing

@testable import Herm

struct DiffSearchTests {
    @Test func searchIncludesAllLoadedFilesAndPreservesUTF16Offsets() {
        let comparison = DiffComparisonIdentity(repository: "/tmp/repo", revision: "HEAD")
        let patches = [
            "a.swift": RepositoryDiff(
                path: "a.swift", text: "@@ -1 +1 @@\n-old\n+日本語 🐈 needle needle", isTruncated: false, isStaged: false),
            "z.swift": RepositoryDiff(
                path: "z.swift", text: "@@ -2 +2 @@\n context\n+NEEDLE", isTruncated: true, isStaged: false),
        ].mapValues { DiffSearch.Patch($0, at: comparison) }
        let matches = DiffSearch.matches(query: "needle", patches: patches)
        #expect(matches.count == 3)
        #expect(matches.map(\.path) == ["a.swift", "a.swift", "z.swift"])
        #expect(matches[0].range.location == ("日本語 🐈 " as NSString).length)
        #expect(DiffSearch.matches(query: "needle", patches: patches, limit: 1).count == 1)
        #expect(DiffSearch.matches(query: "", patches: patches).isEmpty)
    }
    @Test func filteringAndRepeatedQueriesSharePreparedPatches() async {
        let file = "a.swift"
        let identity = DiffComparisonIdentity(repository: "/tmp/repo", revision: "HEAD")
        let raw = RepositoryDiff(
            path: file, text: "diff --git a/a.swift b/a.swift\n@@ -1 +1 @@\n-old\n+needle",
            isTruncated: false, isStaged: false)
        let patches = [file: DiffSearch.Patch(raw, at: identity)]
        let first = await DiffSearch.project(
            search: "needle", filter: "DIFF --GIT", files: [file, "b.swift"], patches: patches)
        let second = await DiffSearch.project(
            search: "OLD", filter: "b.swift", files: [file, "b.swift"], patches: patches)
        #expect(first.files == [file])
        #expect(first.matches.map(\.lineIndex) == [3])
        #expect(second.files == ["b.swift"])
        #expect(second.matches.map(\.lineIndex) == [2])
    }

    @Test func newlinesAndBinaryMetadataRemainExplicit() {
        let document = DiffDocument(path: "file", patch: "@@ -1 +1 @@\n-old\n+new\n\\ No newline at end of file")
        #expect(document.missingFinalNewline)
        #expect(!document.lines.contains(where: { $0.text.contains("No newline") }))
        #expect(DiffDocument(path: "image", patch: "Binary files a/image and b/image differ").isBinary)
    }
}
