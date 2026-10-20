import Testing

@testable import Herm

struct DiffFileMetadataTests {
    @Test func gitHeadersDoNotBecomeSourceLines() {
        let patch = "diff --git a/file b/file\nindex 123..456 100644\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new\n"
        let document = DiffDocument(path: "file", patch: patch)
        #expect(document.lines.count == 3)
        #expect(document.lines[1].oldLine == 1)
        #expect(document.lines[2].newLine == 1)
        #expect(!document.lines.contains(where: { $0.text.hasPrefix("index") || $0.text.isEmpty }))
    }
    @Test func emptyRenameAndBinaryStatesAreDistinct() {
        #expect(DiffDocument(path: "new", patch: "new file mode 100644\nindex 000..e69").fileNotice == "New empty file")
        #expect(
            DiffDocument(path: "old", patch: "deleted file mode 100644\nindex e69..000").fileNotice
                == "Deleted empty file")
        #expect(
            DiffDocument(path: "new", patch: "similarity index 100%\nrename from old\nrename to new").fileNotice
                == "Renamed from old")
        #expect(DiffDocument(path: "image", patch: "Binary files old/image and new/image differ").isBinary)
    }
    @Test func splitViewRequiresSourceOnBothSides() {
        #expect(!DiffDocument(path: "new", patch: "@@ -0,0 +1,2 @@\n+first\n+second").supportsSplitView)
        #expect(!DiffDocument(path: "old", patch: "@@ -1,2 +0,0 @@\n-first\n-second").supportsSplitView)
        #expect(!DiffDocument(path: "empty", patch: "new file mode 100644").supportsSplitView)
        #expect(DiffDocument(path: "modified", patch: "@@ -1 +1 @@\n-old\n+new").supportsSplitView)
        #expect(DiffDocument(path: "insertion", patch: "@@ -1 +1,2 @@\n context\n+added").supportsSplitView)
    }

    @Test func malformedHugeLineNumbersCannotOverflow() {
        let document = DiffDocument(
            path: "file", patch: "@@ -9223372036854775807 +9223372036854775807 @@\n first\n second")
        #expect(!document.lines.isEmpty)
    }
}
