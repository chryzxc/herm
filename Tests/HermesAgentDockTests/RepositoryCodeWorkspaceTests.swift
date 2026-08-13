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
}
