import Foundation
import Testing

@testable import Herm

struct DiffContextExpansionTests {
    @Test func expandsOnlySourceProvenOnBothSides() throws {
        let old = "first\nunchanged\nold\nlast\nend\n"
        let new = "first\nunchanged\n日本語\nlast\nend\n"
        let result = try DiffContextExpansion.expand(
            patch: "@@ -3 +3 @@\n-old\n+日本語", oldSource: old, newSource: new, additionalContext: 2)
        #expect(result == "@@ -1,5 +1,5 @@\n first\n unchanged\n-old\n+日本語\n last\n end")
        #expect(throws: (any Error).self) {
            try DiffContextExpansion.expand(
                patch: "@@ -3 +3 @@\n-stale\n+日本語", oldSource: old, newSource: new, additionalContext: 2)
        }
    }
    @Test func multipleHunksDoNotDuplicateUnchangedRows() throws {
        let patch = "@@ -2 +2 @@\n-old\n+new\n@@ -6 +6 @@\n-other\n+changed"
        let result = try DiffContextExpansion.expand(
            patch: patch, oldSource: "a\nold\nc\nd\ne\nother\ng\n", newSource: "a\nnew\nc\nd\ne\nchanged\ng\n",
            additionalContext: 10)
        #expect(result.components(separatedBy: "\n c").count == 2)
        #expect(result.components(separatedBy: "\n e").count == 2)
        #expect(result.contains("@@ -1,3 +1,3 @@"))
        #expect(result.contains("@@ -5,3 +5,3 @@"))
    }
    @Test func addedDeletedEmptyAndMissingNewlineFilesRemainValid() throws {
        let added = "@@ -0,0 +1,1 @@\n+new\n\\ No newline at end of file"
        #expect(
            try DiffContextExpansion.expand(patch: added, oldSource: "", newSource: "new", additionalContext: 20)
                == added)
        let deleted = "@@ -1,1 +0,0 @@\n-old"
        #expect(
            try DiffContextExpansion.expand(patch: deleted, oldSource: "old\n", newSource: "", additionalContext: 20)
                == deleted)
        #expect(throws: (any Error).self) {
            try DiffContextExpansion.expand(
                patch: "@@ -99999999999999999999,99 +1,1 @@", oldSource: "", newSource: "", additionalContext: 20)
        }
    }
}
