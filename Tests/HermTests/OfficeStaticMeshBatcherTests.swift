import AppKit
import Foundation
import RealityKit
import Testing

@testable import Herm

@MainActor
struct OfficeStaticMeshBatcherTests {
    private func modelEntities(in entity: Entity) -> [ModelEntity] {
        ((entity as? ModelEntity).map { [$0] } ?? [])
            + entity.children.flatMap { modelEntities(in: $0) }
    }

    private func batchableModels(in entity: Entity) -> Int {
        guard !OfficeStaticMeshBatcher.isDynamic(entity) else { return 0 }
        return (entity is ModelEntity ? 1 : 0)
            + entity.children.reduce(0) { $0 + batchableModels(in: $1) }
    }

    @Test func staticSceneryCollapsesWhileDynamicEntitiesSurvive() {
        let root = Entity()
        OfficeDesignSceneBuilder().build(in: root, capacity: 24)
        let before = batchableModels(in: root)
        let totalBefore = modelEntities(in: root).count
        let bounds = root.visualBounds(relativeTo: root)

        OfficeStaticMeshBatcher.flatten(root)

        let after = batchableModels(in: root)
        #expect(
            after < before, "The scene also contains translucent and textured models that must not merge")
        #expect(modelEntities(in: root).count < totalBefore)
        #expect(root.findEntity(named: "work-screen-0") is ModelEntity)
        #expect(root.findEntity(named: "work-screen-22") is ModelEntity)
        #expect(root.findEntity(named: "main-office-extended-screen") is ModelEntity)
        #expect(
            root.findEntity(named: "exterior-ground")?.components.has(CollisionComponent.self) == true)
        let flattened = root.visualBounds(relativeTo: root)
        #expect(simd_distance(bounds.min, flattened.min) < 0.01)
        #expect(simd_distance(bounds.max, flattened.max) < 0.01)
    }

    @Test func compatibleOpaqueModelsMergeAndTransparentModelsRemainSeparate() {
        let root = Entity()
        let mesh = OfficeLowPolyMesh.box(size: [1, 1, 1], cornerRadius: 0)
        let opaque = SimpleMaterial(color: .red, roughness: 0.5, isMetallic: false)
        for index in 0..<100 {
            let model = ModelEntity(mesh: mesh, materials: [opaque])
            model.position.x = Float(index)
            root.addChild(model)
        }
        let glass = ModelEntity(
            mesh: mesh,
            materials: [
                SimpleMaterial(
                    color: NSColor.white.withAlphaComponent(0.5), roughness: 0.5, isMetallic: false)
            ])
        glass.name = "transparent-fixture"
        root.addChild(glass)
        let screen = ModelEntity(mesh: mesh, materials: [opaque])
        screen.name = "work-screen-fixture"
        root.addChild(screen)
        OfficeStaticMeshBatcher.flatten(root)
        #expect(modelEntities(in: root).count == 3)
        #expect(root.findEntity(named: "transparent-fixture") === glass)
        #expect(root.findEntity(named: "work-screen-fixture") === screen)
    }

    @Test func lowPolyMeshesFaceOutwardAndKeepTheirSize() {
        for (mesh, size) in [
            (
                OfficeLowPolyMesh.box(size: [1.2, 0.4, 0.8], cornerRadius: 0.1), SIMD3<Float>(1.2, 0.4, 0.8)
            ),
            (OfficeLowPolyMesh.sphere(radius: 0.5), SIMD3<Float>(repeating: 1)),
        ] {
            #expect(simd_distance(mesh.bounds.extents, size) < 0.001)
            var vertices = 0
            for part in mesh.contents.models.flatMap(\.parts) {
                let positions = part.positions.elements
                let normals = part.normals!.elements
                let indices = part.triangleIndices!.elements
                vertices += positions.count
                for t in stride(from: 0, to: indices.count, by: 3) {
                    let a = Int(indices[t])
                    let b = Int(indices[t + 1])
                    let c = Int(indices[t + 2])
                    let face = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
                    guard simd_length(face) > 1e-6 else { continue }
                    #expect(simd_dot(face, normals[a] + normals[b] + normals[c]) > 0)
                }
            }
            #expect(vertices < 1_000)
        }
    }
}
