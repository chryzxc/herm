import Foundation
import Testing

@testable import Herm

struct DiffTextSelectionTests {
    @Test func copyOmitsHeadersAndAlignmentPlaceholders() {
        let hunk = PullRequestDiffLine(index: 0, text: "@@ -1 +1 @@")
        var added = PullRequestDiffLine(index: 1, text: "+\t日本語")
        added.newLine = 1
        var empty = PullRequestDiffLine(index: 2, text: " ")
        empty.oldLine = 2
        empty.newLine = 2
        let lines: [PullRequestDiffLine?] = [hunk, added, nil, empty]
        let rendered = lines.map { $0.map(DiffDocument.source) ?? "" }.joined(separator: "\n")
        #expect(
            DiffTextSelection.source(lines: lines, range: NSRange(location: 0, length: (rendered as NSString).length))
                == "\t日本語\n")
    }
    @Test func selectingThroughNewlineDoesNotAnchorTheNextLine() {
        #expect(DiffTextSelection.rowRange(in: "one\ntwo", selection: NSRange(location: 0, length: 4)) == 0...0)
        #expect(DiffTextSelection.rowRange(in: "one\ntwo", selection: NSRange(location: 4, length: 3)) == 1...1)
    }
    @Test func leftContextNotesKeepOldSideCoordinates() {
        var line = PullRequestDiffLine(index: 0, text: " unchanged")
        line.oldLine = 7
        line.newLine = 12
        let note = RevisionNote(
            documentID: "revision", path: "file", selection: DiffSelection(lines: [line], side: "LEFT"), text: "Review")
        #expect(note.context(currentIdentity: "revision").body.contains("old lines 7–7"))
    }
}
