import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
struct ActivityPresentationIsolationTests {
    @Test func coalescedActivityDoesNotNotifyUnrelatedModelObservers() async throws {
        let model = DockModel(initialSessionID: "activity-isolation")
        defer { model.shutdown() }
        var modelUpdates = 0
        var revisions: [Int] = []
        var phases: [ConversationActivityPhase] = []
        let modelSubscription = model.objectWillChange.sink { modelUpdates += 1 }
        let activitySubscription = model.activityPresentation.$revision.dropFirst().sink { revision in
            revisions.append(revision)
            phases.append(model.conversationActivityPhase)
        }

        model.conversationActivityPhase = .thinking
        model.conversationActivityPhase = .responding
        #expect(model.conversationActivityPhase == .responding)
        #expect(revisions.isEmpty)
        for _ in 0..<100 where revisions.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(revisions == [1])
        #expect(phases == [.responding])
        #expect(model.activityPresentationTask == nil)
        #expect(modelUpdates == 0)

        withExtendedLifetime((modelSubscription, activitySubscription)) {}
    }

    @Test func activitySignalsAreIndependentAcrossModelsAndBursts() async throws {
        let models = (0..<4).map { DockModel(initialSessionID: "activity-isolation-\($0)") }
        defer {
            for model in models { model.shutdown() }
        }
        var revisions = Array(repeating: [Int](), count: models.count)
        var parentUpdates = Array(repeating: 0, count: models.count)
        let subscriptions = models.enumerated().map { index, model in
            model.activityPresentation.$revision.dropFirst().sink { revisions[index].append($0) }
        }
        let parentSubscriptions = models.enumerated().map { index, model in
            model.objectWillChange.sink { parentUpdates[index] += 1 }
        }
        for model in models {
            model.conversationActivityPhase = .thinking
            model.conversationActivityPhase = .responding
            #expect(model.conversationActivityPhase == .responding)
        }
        for _ in 0..<100 where revisions.contains(where: { $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(revisions == Array(repeating: [1], count: models.count))
        #expect(parentUpdates == Array(repeating: 0, count: models.count))
        models[0].conversationActivityPhase = .responding
        #expect(models[0].activityPresentationTask == nil)
        models[0].conversationActivityPhase = .thinking
        for _ in 0..<100 where revisions[0].count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(revisions[0] == [1, 2])
        #expect(revisions.dropFirst().allSatisfy { $0 == [1] })
        #expect(models[0].activityPresentationTask == nil)
        #expect(parentUpdates == Array(repeating: 0, count: models.count))
        withExtendedLifetime((subscriptions, parentSubscriptions)) {}
    }

    @Test func activityConsumersSubscribeLocally() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Herm")
        let explicit = [
            "Conversation/ConversationTranscriptSource.swift", "Conversation/DockPopover.swift",
            "Appearance/HermesPetModel.swift", "EdgeDock/EdgeDockController.swift",
            "SessionWorkspace/SessionTraceModel.swift",
        ]
        let views = [
            "Agents/AgentBoardView.swift", "ControlCenter/WorkspaceActivitySidebar.swift",
            "SessionWorkspace/SessionDataPreviewView.swift", "SessionWorkspace/SessionPullRequestRail.swift",
            "Voice/VoiceActivityPills.swift", "Voice/VoiceHUD.swift",
        ]
        for path in explicit + views {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(source.contains("model.activityPresentation.$revision"), "Missing activity subscription: \(path)")
            #expect(!source.contains("model.$activityPresentationRevision"), "Parent subscription remains: \(path)")
            if views.contains(path) {
                #expect(source.contains("let _ = activityRevision"), "Missing state read: \(path)")
                #expect(source.contains("activityRevision &+= 1"), "Missing local invalidation: \(path)")
            }
        }
    }
}
