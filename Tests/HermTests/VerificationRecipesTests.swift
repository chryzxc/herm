import Foundation
import Testing
@testable import Herm

struct VerificationRecipesTests {
    @Test func recipesAcceptKnownVerificationCommandsAndDeduplicate() {
        let facts = ProjectFactsSummary(root: "/workspace/project", manifests: ["Package.swift"], packageManagers: ["swift"], verifyCommands: ["swift test", "swift test", "rm -rf .", "swift build -c release"], contextFiles: [])
        let repository = RepositorySnapshot(path: "/workspace/project", branch: "main", changedFiles: 0, latestCommit: "abc", isGitRepository: true)

        let recipes = VerificationRecipeBuilder.make(facts: facts, repository: repository)

        #expect(recipes.map(\.command) == ["swift test", "swift build -c release"])
        #expect(recipes.map(\.kind) == [.test, .build])
        #expect(recipes.allSatisfy { $0.workingDirectory == "/workspace/project" })
    }

    @Test func recipesRejectControlCharactersAndUnknownCommands() {
        #expect(VerificationRecipeBuilder.normalizedCommand("swift test\nrm -rf .") == nil)
        #expect(VerificationRecipeBuilder.normalizedCommand("swift test; rm -rf .") == nil)
        #expect(VerificationRecipeBuilder.normalizedCommand("curl https://example.com") == nil)
        #expect(VerificationRecipeBuilder.normalizedCommand("npm run deploy") == nil)
        #expect(VerificationRecipeBuilder.normalizedCommand("make test integration") == nil)
        #expect(VerificationRecipeBuilder.normalizedCommand("swift test") == "swift test")
        #expect(VerificationRecipeBuilder.normalizedCommand("npm run test -- --watch") == "npm run test -- --watch")
    }

    @Test func recipeRunsBecomeStaleWhenRepositoryIdentityOrFingerprintChanges() {
        let run = VerificationRun(id: UUID(), recipeID: "test:swift test", repositoryID: "/repo", repositoryFingerprint: "abc", command: "swift test", startedAt: .now, finishedAt: .now, exitCode: 0, outputSummary: "passed")

        #expect(run.isCurrent(repositoryFingerprint: "abc", repositoryID: "/repo"))
        #expect(!run.isCurrent(repositoryFingerprint: "def", repositoryID: "/repo"))
        #expect(!run.isCurrent(repositoryFingerprint: "abc", repositoryID: "/other"))
    }

    @Test func verificationRunReportsBoundedDurationLabel() {
        let start = Date(timeIntervalSince1970: 100)
        let complete = VerificationRun(id: UUID(), recipeID: "test:swift test", repositoryID: "repo", repositoryFingerprint: "fp", command: "swift test", startedAt: start, finishedAt: start.addingTimeInterval(2.26), exitCode: 0, outputSummary: "ok")
        #expect(abs((complete.duration ?? 0) - 2.26) < 0.001)
        #expect(complete.durationLabel == "2.3s")
    }
}
