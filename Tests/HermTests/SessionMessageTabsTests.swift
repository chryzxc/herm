import Foundation
import Observation
import Testing

@testable import Herm

@MainActor
struct SessionMessageTabsTests {
    @MainActor private final class Changes {
        var own = 0
        var other = 0
    }

    @Test func previewChangesNotifyOnlyTheirWorkspace() {
        let tabs = SessionMessageTabs()
        let message = ChatMessage(role: .user, text: "One")
        let changes = Changes()
        let own = tabs.workspace("own")
        let other = tabs.workspace("other")
        withObservationTracking {
            _ = (own.tabs, own.selection)
        } onChange: {
            MainActor.assumeIsolated { changes.own += 1 }
        }
        withObservationTracking {
            _ = (other.tabs, other.selection)
        } onChange: {
            MainActor.assumeIsolated { changes.other += 1 }
        }
        tabs.open(message, in: "own")
        #expect(changes.own == 1)
        #expect(changes.other == 0)

        withObservationTracking {
            _ = own.selection
        } onChange: {
            MainActor.assumeIsolated { changes.own += 1 }
        }
        tabs.select(message.id, in: "own")
        #expect(changes.own == 1)
        tabs.close(message.id, in: "own")
        #expect(changes.own == 2)
        #expect(changes.other == 0)
    }

    @Test func confirmedDeletionReleasesPreviewsOnlyForThatWorkspace() {
        let tabs = SessionMessageTabs()
        let deleted = tabs.workspace("profile-a/session")
        let kept = tabs.workspace("profile-b/session")
        tabs.open(ChatMessage(role: .user, text: "Delete"), in: "profile-a/session")
        tabs.open(ChatMessage(role: .user, text: "Keep"), in: "profile-b/session")

        tabs.forget("profile-a/session")

        #expect(deleted.tabs.isEmpty)
        #expect(deleted.selection == nil)
        #expect(tabs.workspace("profile-a/session") !== deleted)
        #expect(kept.tabs.count == 1)
    }

    @Test func openingSelectsAndDeduplicatesMessages() {
        let tabs = SessionMessageTabs()
        let first = ChatMessage(role: .hermes, text: "First message")
        let second = ChatMessage(role: .user, text: "Second message")
        let workspace = tabs.workspace("workspace")
        var opens = 0
        var unrelatedOpens = 0
        let own = workspace.openRequests.sink { opens += 1 }
        let other = tabs.workspace("other").openRequests.sink { unrelatedOpens += 1 }
        defer {
            own.cancel()
            other.cancel()
        }
        tabs.open(first, in: "workspace")
        tabs.open(second, in: "workspace")
        tabs.open(first, in: "workspace")
        #expect(tabs.workspace("workspace").tabs.map(\.id) == [first.id, second.id])
        #expect(tabs.workspace("workspace").selection == first.id)
        #expect(opens == 3)
        #expect(unrelatedOpens == 0)
    }

    @Test func messageTabTitlesKeepTheWholeFirstLine() {
        let title = "PR #5564 is mergeable and targets the correct release branch"
        let message = ChatMessage(role: .hermes, text: title + "\nFurther details")
        #expect(SessionPreviewContent.message(message).title == title)
        #expect(SessionPreviewContent.message(ChatMessage(role: .user, text: "")).title == "Message")
    }

    @Test func workspacesKeepIndependentMessagesAndSelections() {
        let tabs = SessionMessageTabs()
        let message = ChatMessage(role: .hermes, text: "Reference")
        for workspace in ["backend-a:profile-a:session", "backend-a:profile-b:session", "backend-b:profile-a:session"] {
            tabs.open(message, in: workspace)
        }
        tabs.close(message.id, in: "backend-a:profile-a:session")
        #expect(tabs.workspace("backend-a:profile-a:session").tabs.isEmpty)
        #expect(tabs.workspace("backend-a:profile-a:session").selection == nil)
        #expect(tabs.workspace("backend-a:profile-b:session").tabs.count == 1)
        #expect(tabs.workspace("backend-b:profile-a:session").selection == message.id)
    }

    @Test func closingSelectedTabFallsBackAndClosingBackgroundTabKeepsSelection() {
        let tabs = SessionMessageTabs()
        let first = ChatMessage(role: .user, text: "One")
        let second = ChatMessage(role: .hermes, text: "Two")
        tabs.open(first, in: "workspace")
        tabs.open(second, in: "workspace")
        tabs.close(first.id, in: "workspace")
        #expect(tabs.workspace("workspace").selection == second.id)
        tabs.open(first, in: "workspace")
        tabs.close(first.id, in: "workspace")
        #expect(tabs.workspace("workspace").selection == second.id)
        tabs.select(nil, in: "workspace")
        #expect(tabs.workspace("workspace").selection == nil)
        #expect(tabs.workspace("workspace").tabs.count == 1)
        tabs.close(second.id, in: "workspace")
        #expect(tabs.workspace("workspace").tabs.isEmpty)
    }
    @Test func typedPreviewsDeduplicateRefreshAndKeepKindsSeparate() throws {
        let tabs = SessionMessageTabs()
        var call = ActiveToolCall(
            id: "same-id", name: "terminal", input: "pwd", context: "Project", startedAt: .now, isComplete: false)
        let message = ChatMessage(role: .hermes, text: "Response")
        tabs.open(.tool(call), in: "workspace")
        let toolID = try #require(tabs.workspace("workspace").selection)
        call.isComplete = true
        call.result = "/project"
        tabs.open(.tool(call), in: "workspace")
        #expect(tabs.workspace("workspace").selection == toolID)
        #expect(tabs.workspace("workspace").tabs.count == 1)
        if case .tool(let refreshed) = tabs.workspace("workspace").tabs.first?.content {
            #expect(refreshed.result == "/project")
        } else {
            Issue.record("Expected refreshed tool preview")
        }
        tabs.open(.activity(message, [call]), in: "workspace")
        tabs.open(message, in: "workspace")
        #expect(tabs.workspace("workspace").tabs.count == 3)
        tabs.close(message.id, in: "workspace")
        #expect(tabs.workspace("workspace").tabs.count == 2)
        tabs.close(toolID, in: "workspace")
        #expect(tabs.workspace("workspace").tabs.count == 1)
    }

    @Test func pullRequestsDeduplicateWithinIndependentWorkspaces() throws {
        let tabs = SessionMessageTabs()
        let firstRepository = GitHubRepositoryReference(
            owner: "owner", name: "first", webURL: URL(string: "https://github.com/owner/first")!)
        let secondRepository = GitHubRepositoryReference(
            owner: "owner", name: "second", webURL: URL(string: "https://github.com/owner/second")!)
        let first = GitHubItemReference(repository: firstRepository, number: 42, kind: .pullRequest)
        let second = GitHubItemReference(repository: secondRepository, number: 42, kind: .pullRequest)
        tabs.open(.pullRequest(first), in: "workspace-a")
        let firstID = try #require(tabs.workspace("workspace-a").selection)
        tabs.open(.pullRequest(second), in: "workspace-a")
        let secondID = try #require(tabs.workspace("workspace-a").selection)
        #expect(firstID != secondID)
        tabs.open(.pullRequest(first), in: "workspace-a")
        #expect(tabs.workspace("workspace-a").tabs.count == 2)
        #expect(tabs.workspace("workspace-a").selection == firstID)
        tabs.open(.pullRequest(first), in: "workspace-b")
        tabs.close(firstID, in: "workspace-a")
        #expect(tabs.workspace("workspace-a").selection == secondID)
        #expect(tabs.workspace("workspace-b").tabs.count == 1)
    }

}
