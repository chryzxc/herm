import Testing

@testable import Herm

@Suite struct NewChatProjectChoiceTests {
    private func project(_ id: String, _ name: String) -> ProjectSummary {
        ProjectSummary(
            id: id, name: name, repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: false)
    }

    @Test func listsOnlyRenderableProjectsByFolderName() {
        let options = NewChatProjectChoice.options(
            from: [project("a", "/work/herm"), project("b", "__no_project__"), project("c", "tmp")], query: "")
        #expect(options.map(\.title) == ["herm"])
        #expect(options.first?.path == "/work/herm")
    }

    @Test func searchMatchesNameOrPath() {
        let projects = [project("a", "/work/herm"), project("b", "/code/audition")]
        #expect(NewChatProjectChoice.options(from: projects, query: " aud ").map(\.id) == ["b"])
        #expect(NewChatProjectChoice.options(from: projects, query: "/work").map(\.id) == ["a"])
        #expect(NewChatProjectChoice.options(from: projects, query: "zzz").isEmpty)
    }

    @Test func labelPromptsUntilAProjectIsChosen() {
        #expect(NewChatProjectChoice.label(forPath: nil) == "Choose project")
        #expect(NewChatProjectChoice.label(forPath: "") == "Choose project")
        #expect(NewChatProjectChoice.label(forPath: "/work/herm") == "herm")
    }

    @Test func selectionIgnoresTrailingSlash() {
        let option = NewChatProjectChoice.Option(id: "a", path: "/work/herm", title: "herm")
        #expect(NewChatProjectChoice.isSelected(option, path: "/work/herm/"))
        #expect(!NewChatProjectChoice.isSelected(option, path: nil))
    }
}
