import Foundation
import RealityKit
import Testing
@testable import HermesAgentDock

@MainActor
struct OfficeStaticMeshBatcherTests {
    private func modelEntities(in entity: Entity) -> [ModelEntity] {
        (entity as? ModelEntity).map { [$0] } ?? [] + entity.children.flatMap { modelEntities(in: $0) }
    }

    @Test func staticSceneryCollapsesWhileDynamicEntitiesSurvive() {
        let root = Entity()
        OfficeDesignSceneBuilder().build(in: root, capacity: 24)
        let before = modelEntities(in: root).count
        let bounds = root.visualBounds(relativeTo: root)

        OfficeStaticMeshBatcher.flatten(root)

        let after = modelEntities(in: root).count
        #expect(after * 10 < before)
        #expect(root.findEntity(named: "work-screen-0") is ModelEntity)
        #expect(root.findEntity(named: "work-screen-22") is ModelEntity)
        #expect(root.findEntity(named: "main-office-extended-screen") is ModelEntity)
        #expect(root.findEntity(named: "exterior-ground")?.components.has(CollisionComponent.self) == true)
        let flattened = root.visualBounds(relativeTo: root)
        #expect(simd_distance(bounds.min, flattened.min) < 0.01)
        #expect(simd_distance(bounds.max, flattened.max) < 0.01)
    }

    @Test func lowPolyMeshesFaceOutwardAndKeepTheirSize() {
        for (mesh, size) in [(OfficeLowPolyMesh.box(size: [1.2, 0.4, 0.8], cornerRadius: 0.1), SIMD3<Float>(1.2, 0.4, 0.8)),
                             (OfficeLowPolyMesh.sphere(radius: 0.5), SIMD3<Float>(repeating: 1))] {
            #expect(simd_distance(mesh.bounds.extents, size) < 0.001)
            var vertices = 0
            for part in mesh.contents.models.flatMap(\.parts) {
                let positions = part.positions.elements, normals = part.normals!.elements
                let indices = part.triangleIndices!.elements
                vertices += positions.count
                for t in stride(from: 0, to: indices.count, by: 3) {
                    let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
                    let face = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
                    guard simd_length(face) > 1e-6 else { continue }
                    #expect(simd_dot(face, normals[a] + normals[b] + normals[c]) > 0)
                }
            }
            #expect(vertices < 1_000)
        }
    }
}
