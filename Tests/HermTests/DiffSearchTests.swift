import Foundation
import Testing

@testable import Herm

struct DiffSearchTests {
    @Test func searchIncludesAllLoadedFilesAndPreservesUTF16Offsets() {
        let patches = [
            "a.swift": RepositoryDiff(
                path: "a.swift", text: "@@ -1 +1 @@\n-old\n+日本語 🐈 needle needle", isTruncated: false, isStaged: false),
            "z.swift": RepositoryDiff(
                path: "z.swift", text: "@@ -2 +2 @@\n context\n+NEEDLE", isTruncated: true, isStaged: false),
        ]
        let matches = DiffSearch.matches(query: "needle", patches: patches)
        #expect(matches.count == 3)
        #expect(matches.map(\.path) == ["a.swift", "a.swift", "z.swift"])
        #expect(matches[0].range.location == ("日本語 🐈 " as NSString).length)
        #expect(DiffSearch.matches(query: "needle", patches: patches, limit: 1).count == 1)
        #expect(DiffSearch.matches(query: "", patches: patches).isEmpty)
    }
    @Test func newlinesAndBinaryMetadataRemainExplicit() {
        let document = DiffDocument(path: "file", patch: "@@ -1 +1 @@\n-old\n+new\n\\ No newline at end of file")
        #expect(document.missingFinalNewline)
        #expect(!document.lines.contains(where: { $0.text.contains("No newline") }))
        #expect(DiffDocument(path: "image", patch: "Binary files a/image and b/image differ").isBinary)
    }
}
