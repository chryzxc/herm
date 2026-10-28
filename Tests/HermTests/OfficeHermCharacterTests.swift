import AppKit
import RealityKit
import Testing

@testable import Herm

struct OfficeHermCharacterTests {
    @MainActor @Test func avatarChangesKeepPlacementSelectionAndWorldEntity() throws {
        let suite = "OfficeHermCharacterTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = OfficePreviewARView(frame: .zero)
        let coordinator = OfficePreviewSceneView.Coordinator(
            placementStore: OfficePlacementStore(defaults: defaults), onSelectAgent: { _ in })
        defer { coordinator.stop() }
        let agent = OfficePreviewAgentPresentation(id: "cypher", name: "Cypher", tasks: [])
        coordinator.install(in: view, agents: [agent], reduceMotion: true)
        coordinator.select(agent.id)
        let anchor = try #require(view.scene.anchors.first)
        let root = try #require(anchor.findEntity(named: "office-agent-cypher"))
        let originalTransform = root.transform
        #expect(root.findEntity(named: "herm-body") != nil)
        #expect(root.findEntity(named: "robot-head-shell") == nil)

        coordinator.avatarImages = [agent.id: try #require(BotFaceMark.png(id: agent.id))]
        coordinator.update(agents: [agent], reduceMotion: true)
        #expect(root.findEntity(named: "herm-body") != nil)

        // Another profile's artwork is a custom image for this bot.
        coordinator.avatarImages = [agent.id: try #require(BotFaceMark.png(id: "nexus"))]
        coordinator.update(agents: [agent], reduceMotion: true)
        #expect(anchor.findEntity(named: root.name) === root)
        #expect(root.transform == originalTransform)
        #expect(root.findEntity(named: "herm-body") == nil)
        #expect(root.findEntity(named: "robot-head-shell") != nil)
        #expect(root.findEntity(named: "selection-ring")?.isEnabled == true)

        coordinator.avatarImages = [:]
        coordinator.update(agents: [agent], reduceMotion: true)
        #expect(root.findEntity(named: "herm-body") != nil)
        #expect(root.transform == originalTransform)
        #expect(root.findEntity(named: "selection-ring")?.isEnabled == true)
        let body = root.findEntity(named: "herm-body")
        coordinator.apply(palette: OfficeScenePalette(theme: .mono, isDark: false))
        coordinator.update(agents: [agent], reduceMotion: true)
        #expect(root.findEntity(named: "herm-body") !== body)
        #expect(root.transform == originalTransform)
    }

    @MainActor @Test func everySeededBodyHasDepthAndMatchingEyes() throws {
        var seen = Set<HermFaceGenes.Body>()
        for index in 0..<40 {
            let id = "bot-\(index)"
            let genes = HermFaceGenes(id: id)
            let face = OfficeHermCharacter.makeFace(id: id, theme: .glass, ink: .black)
            let body = try #require(face.head.findEntity(named: "herm-body") as? ModelEntity)
            let bounds = try #require(body.model?.mesh.bounds)
            #expect(bounds.extents.x > 0.9 && bounds.extents.x < 1.2)
            #expect(bounds.extents.y > 0.9 && bounds.extents.y < 1.2)
            #expect(abs(bounds.extents.z - 0.56) < 0.001)
            #expect(face.eyes.count == (genes.eyes == .visor ? 1 : 2))
            #expect(face.eyes.allSatisfy { $0.position.z > bounds.max.z })
            seen.insert(genes.body)
        }
        #expect(seen.count == HermFaceGenes.Body.allCases.count)
    }
}
