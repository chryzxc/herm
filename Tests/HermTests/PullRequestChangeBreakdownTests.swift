import Testing
@testable import Herm

struct PullRequestChangeBreakdownTests {
    @Test func classifiesPathsWithSpecificTestSupportBeforeTests() {
        let examples: [(String, PullRequestChangeCategory)] = [
            ("Sources/App.swift", .code), ("src/card.tsx", .code),
            ("Tests/HermTests/StateTests.swift", .tests), ("src/card.test.tsx", .tests),
            ("handler_test.go", .tests), ("test_state.py", .tests),
            ("Tests/Fixtures/payload.json", .mocks), ("src/__mocks__/api.ts", .mocks),
            ("Tests/HermTests/MockTransport.swift", .mocks),
            ("docs/setup.md", .docs), ("README.md", .docs),
            (".github/workflows/ci.yml", .config), ("Package.swift", .config),
            ("assets/logo.png", .other), ("src/contest.ts", .code)
        ]
        for (path, category) in examples { #expect(PullRequestChangeCategory.classify(path) == category) }
    }

    @Test func totalsEveryFileExactlyOnceIncludingRenamesAndBinaryFiles() {
        let files = [
            PullRequestFile(path: "src/app.ts", status: "modified", additions: 20, deletions: 4, patch: nil, webURL: nil),
            PullRequestFile(path: "src/new.ts", status: "renamed", additions: 2, deletions: 1, patch: nil, webURL: nil, previousPath: "src/old.ts"),
            PullRequestFile(path: "tests/__mocks__/api.ts", status: "added", additions: 8, deletions: 0, patch: nil, webURL: nil),
            PullRequestFile(path: "logo.png", status: "added", additions: 0, deletions: 0, patch: nil, webURL: nil)
        ]
        let groups = PullRequestChangeGroup.summarize(files)
        #expect(groups.map(\.category) == [.code, .mocks, .other])
        #expect(groups.first == PullRequestChangeGroup(category: .code, files: 2, additions: 22, deletions: 5))
        #expect(groups.reduce(0) { $0 + $1.files } == files.count)
        #expect(groups.reduce(0) { $0 + $1.additions } == 30)
        #expect(groups.reduce(0) { $0 + $1.deletions } == 5)
        #expect(PullRequestChangeGroup.summarize([]).isEmpty)
    }

    @Test func aggregatesGitHubFileLimitWithoutDroppingFiles() {
        let files = (0..<3000).map { index in
            PullRequestFile(path: "\(index.isMultiple(of: 2) ? "Sources" : "Tests")/File\(index).swift",
                            status: "modified", additions: 3, deletions: 2, patch: nil, webURL: nil)
        }
        let groups = PullRequestChangeGroup.summarize(files)
        #expect(groups.count == 2)
        #expect(groups.reduce(0) { $0 + $1.files } == 3000)
        #expect(groups.reduce(0) { $0 + $1.additions } == 9000)
        #expect(groups.reduce(0) { $0 + $1.deletions } == 6000)
    }

}
