import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
struct ChatRailActivityModelTests {
    @Test func transcriptChurnDoesNotRecalculateOrPublishTheBadge() async throws {
        let defaults = UserDefaults(suiteName: "ChatRailActivityTests.\(UUID())")!
        let model = DockModel(defaults: defaults)
        let source = ChatRailActivityModel(
            model: model, control: ControlCenterModel(),
            store: WorkspaceStore(fileURL: URL(fileURLWithPath: "/tmp/\(UUID()).json")),
            seenStore: SidebarSessionSeenStore(defaults: defaults))
        try await Task.sleep(for: .milliseconds(30))
        let initialProjections = source.projectionCount
        var publications = 0
        let subscription = source.$activity.dropFirst().sink { _ in publications += 1 }
        for index in 0..<1_000 {
            model.composerFocusRequest = index
            model.messages = [ChatMessage(role: .hermes, text: "Streaming \(index)")]
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(source.projectionCount == initialProjections)
        #expect(publications == 0)
        withExtendedLifetime(subscription) {}
    }

    @Test func realStatusChangesUpdateOnceAndEqualAggregatesStayQuiet() async throws {
        let defaults = UserDefaults(suiteName: "ChatRailActivityTests.\(UUID())")!
        let model = DockModel(defaults: defaults)
        model.isHermesConnected = true
        let source = ChatRailActivityModel(
            model: model, control: ControlCenterModel(),
            store: WorkspaceStore(fileURL: URL(fileURLWithPath: "/tmp/\(UUID()).json")),
            seenStore: SidebarSessionSeenStore(defaults: defaults))
        var publications = 0
        let subscription = source.$activity.dropFirst().sink { _ in publications += 1 }
        model.status = .working
        try await waitUntil { source.activity.isWorking }
        #expect(publications == 1)
        // Sidebar loading changes do not change the badge aggregate.
        model.isCreatingSession = true
        try await Task.sleep(for: .milliseconds(30))
        #expect(publications == 1)
        model.isHermesConnected = false
        try await waitUntil { !source.activity.isWorking }
        #expect(publications == 2)
        withExtendedLifetime(subscription) {}
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}
