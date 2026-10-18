import Foundation
import Testing
@testable import Herm

struct OfficePlacementTests {
    @Test func placementsSurviveNewStoreAndRejectInvalidData() throws {
        let suite = "OfficePlacementTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OfficePlacementStore(defaults: defaults)
        let nodes: [String: OfficePreviewLayout.Node] = [
            "idle": .init(slot: 2, index: 0, isStation: true, leisureIndex: 4),
            "walking": .init(slot: -1, index: 0, isStation: false, connectorPosition: [1, 0, 2]),
            "invalid": .init(slot: 0, index: -1, isStation: true)
        ]
        store.save(nodes)
        let restored = OfficePlacementStore(defaults: defaults).load()
        #expect(restored["idle"] == nodes["idle"])
        #expect(restored["walking"] == nodes["walking"])
        #expect(restored["invalid"] == nil)
        defaults.set(Data("invalid".utf8), forKey: "office.placements.v1")
        #expect(store.load().isEmpty)
    }

    @MainActor @Test func firstFrameSpreadsIdleBotsAndRestoresTheirPlaces() throws {
        let suite = "OfficePlacementTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OfficePlacementStore(defaults: defaults)
        let agents = (0..<8).map { OfficePreviewAgentPresentation(id: "idle-\($0)", name: "Bot", tasks: []) }
        let view = OfficePreviewARView(frame: .zero)
        let coordinator = OfficePreviewSceneView.Coordinator(placementStore: store, onSelectAgent: { _ in })
        coordinator.install(in: view, agents: agents)
        let initial = store.load()
        #expect(initial.count == agents.count)
        #expect(initial.values.allSatisfy { $0.leisureIndex != nil })
        #expect(Set(initial.values.compactMap(\.leisureIndex)).count == agents.count)
        coordinator.stop()
        let reopened = OfficePreviewSceneView.Coordinator(placementStore: store, onSelectAgent: { _ in })
        reopened.install(in: view, agents: agents.reversed())
        #expect(store.load() == initial)
        reopened.stop()
        let reduced = OfficePreviewSceneView.Coordinator(placementStore: store, onSelectAgent: { _ in })
        reduced.install(in: view, agents: agents, reduceMotion: true)
        #expect(store.load().values.allSatisfy { $0.isStation && $0.leisureIndex == nil })
        reduced.stop()
    }
}
