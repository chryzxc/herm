import Foundation
import Testing
@testable import Herm

@MainActor
struct CodeExplorerTests {
    @Test func treeListsFoldersBeforeFilesAtEveryLevel() {
        let entries = [
            ProjectFileEntry(path: "README.md", depth: 0, isDirectory: false),
            ProjectFileEntry(path: "Sources", depth: 0, isDirectory: true),
            ProjectFileEntry(path: "Sources/b.swift", depth: 1, isDirectory: false),
            ProjectFileEntry(path: "Sources/App", depth: 1, isDirectory: true),
            ProjectFileEntry(path: "Sources/App/a.swift", depth: 2, isDirectory: false),
            ProjectFileEntry(path: "package.json", depth: 0, isDirectory: false),
        ]
        #expect(SessionFilesView.foldersFirst(entries).map(\.path) == [
            "Sources", "Sources/App", "Sources/App/a.swift", "Sources/b.swift", "package.json", "README.md",
        ])
    }

    @Test func gitStatusIsProjectRelativeAndPrefersWorktree() {
        let files = [
            RepositoryFileChange(path: "app/src/a.ts", status: .added, isStaged: true, renameSource: nil),
            RepositoryFileChange(path: "app/src/a.ts", status: .modified, isStaged: false, renameSource: nil),
            RepositoryFileChange(path: "other/b.ts", status: .modified, isStaged: false, renameSource: nil),
        ]
        #expect(SessionFilesView.projectRelativeStatus(files, projectPrefix: "app/") == ["src/a.ts": .modified])
    }

    @Test func stringsWinOverCommentMarkersAndJSONKeysAreProperties() {
        let source = #"{ "url": "http://x", "n": 1 } // "note""#
        let tokens = CodeTokenizer.tokens(in: source, language: CodeLanguage(path: "a.jsonc"))
        let text = source as NSString
        let last = Dictionary(tokens.map { (text.substring(with: $0.0), $0.1) }, uniquingKeysWith: { _, new in new })
        #expect(last[#""url""#] == .property)
        #expect(last[#""http://x""#] == .string)
        #expect(last["1"] == .number)
        #expect(last[#"// "note""#] == .comment)
    }

    @Test func expandingAFolderCutByTheScanBudgetLoadsItsChildren() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let big = root.appendingPathComponent("a-big")
        let later = root.appendingPathComponent("z-later")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0...RepositoryService.maxProjectExplorerEntries {
            try Data().write(to: big.appendingPathComponent("f\(index).txt"))
        }
        try Data().write(to: later.appendingPathComponent("app.js"))

        let scanned = await RepositoryService.projectFiles(path: root.path)
        #expect(!scanned.contains { $0.path == "z-later/app.js" })
        let children = await RepositoryService.projectDirectory(path: root.path, directory: "z-later")
        #expect(children == [ProjectFileEntry(path: "z-later/app.js", depth: 1, isDirectory: false)])
    }
}
