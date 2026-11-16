import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
struct NavigationPublicationCoalescingTests {
    @Test func navigationBurstsCoalesceAndCancellationDropsPendingWork() async throws {
        let suite = "NavigationPublicationCoalescing.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults)
        defer { model.shutdown() }
        let control = ControlCenterModel()
        var workspaceStates: [String?] = []
        var inspectorStates: [String?] = []
        var controlStates: [String?] = []
        let workspace = model.workspacePresentationChanges.sink { workspaceStates.append(model.currentSessionTitle) }
        let inspector = model.inspectorPresentationChanges.sink { inspectorStates.append(model.currentSessionTitle) }
        let navigation = control.workspacePresentationChanges.sink {
            controlStates.append(control.requestedAutomationJobID)
        }
        model.sessionID = "first"
        model.currentSessionTitle = "First"
        model.status = .idle
        control.requestedAutomationJobID = "job"
        control.requestedAutomationOwner = CronOwner(profileID: "profile")
        control.requestedAutomationDidNavigate = true
        try await Task.sleep(for: .milliseconds(50))
        #expect(workspaceStates == ["First"])
        #expect(inspectorStates == ["First"])
        #expect(controlStates == ["job"])
        model.currentSessionTitle = "Second"
        control.requestedAutomationJobID = "next"
        try await Task.sleep(for: .milliseconds(50))
        #expect(workspaceStates == ["First", "Second"])
        #expect(inspectorStates == ["First", "Second"])
        #expect(controlStates == ["job", "next"])
        model.currentSessionTitle = "Cancelled"
        control.requestedAutomationJobID = "cancelled"
        workspace.cancel()
        inspector.cancel()
        navigation.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(workspaceStates == ["First", "Second"])
        #expect(inspectorStates == ["First", "Second"])
        #expect(controlStates == ["job", "next"])
    }

    @Test func composerModelReceivesUnrelatedPublications() async throws {
        let suite = "ComposerPublicationCount.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults)
        defer { model.shutdown() }
        var composerPublications = 0
        var workspacePublications = 0
        let composer = model.objectWillChange.sink { composerPublications += 1 }
        let workspace = model.workspacePresentationChanges.sink { workspacePublications += 1 }
        model.messagePinError = "first"
        model.messagePinError = "second"
        model.messagePinError = "third"
        try await Task.sleep(for: .milliseconds(50))
        #expect(composerPublications == 3)
        #expect(workspacePublications == 0)
        withExtendedLifetime((composer, workspace)) {}
    }
}
