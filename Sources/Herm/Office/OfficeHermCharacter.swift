import RealityKit
import SwiftUI

/// The same seeded silhouette and eyes as a Herm face, with depth for the office camera.
@MainActor
enum OfficeHermCharacter {
    private static var meshes: [HermFaceGenes.Body: MeshResource] = [:]

    static func makeFace(id: String, theme: DockThemeID, ink: NSColor) -> (head: Entity, eyes: [ModelEntity]) {
        let genes = HermFaceGenes(id: id)
        let head = Entity()
        head.name = "herm-character"
        let face = Entity()
        face.orientation = simd_quatf(angle: Float(genes.tilt * .pi / 180), axis: [0, 0, 1])
        head.addChild(face)
        let body = ModelEntity(
            mesh: bodyMesh(genes.body),
            materials: [
                SimpleMaterial(
                    color: NSColor(BotFaceMark.bodyColor(id: id, theme: theme)), roughness: 0.85,
                    isMetallic: false)
            ])
        body.name = "herm-body"
        face.addChild(body)

        let size: SIMD3<Float> =
            switch genes.eyes {
            case .pill: [0.091, 0.204, 0.025]
            case .dot: [0.149, 0.149, 0.025]
            case .visor: [0.48, 0.18, 0.025]
            case .slit: [0.156, 0.065, 0.025]
            }
        var eyes: [ModelEntity] = []
        for side: Float in genes.eyes == .visor ? [0] : [-1, 1] {
            let depth = min(size.x, size.y)
            let eye = ModelEntity(
                mesh: OfficeLowPolyMesh.box(size: [size.x, size.y, depth], cornerRadius: depth / 2),
                materials: [UnlitMaterial(color: ink)])
            eye.name = "herm-eye"
            eye.scale.z = size.z / depth
            eye.position = [side * 0.156, 0.012, 0.29]
            if genes.eyes == .slit {
                eye.orientation = simd_quatf(angle: side * .pi / 15, axis: [0, 0, 1])
            }
            face.addChild(eye)
            eyes.append(eye)
            if genes.eyes != .slit {
                for x: Float in genes.eyes == .visor ? [-0.108, 0.108] : [0.018] {
                    let glint = ModelEntity(
                        mesh: OfficeLowPolyMesh.sphere(radius: genes.eyes == .visor ? 0.04 : 0.02),
                        materials: [UnlitMaterial(color: .white)])
                    glint.name = "herm-eye-glint"
                    glint.scale.z = 0.3 / eye.scale.z
                    glint.position = [x, genes.eyes == .visor ? 0 : 0.04, 0.018 / eye.scale.z]
                    eye.addChild(glint)
                }
            }
        }
        return (head, eyes)
    }

    /// Inflate the shared 2D outline into a rounded, low-poly solid. Five cached meshes serve the entire roster.
    static func bodyMesh(_ body: HermFaceGenes.Body) -> MeshResource {
        if let mesh = meshes[body] { return mesh }
        let outline = HermFacePath.bodies[body]!
        let segments = 48
        let rings = 12
        let contour: [SIMD2<Float>] = (0...segments).map { index in
            let angle = Float(index) / Float(segments) * 2 * .pi
            let direction = SIMD2<Float>(cos(angle), sin(angle))
            var low: Float = 0
            var high: Float = 70
            for _ in 0..<12 {
                let radius = (low + high) / 2
                let point = CGPoint(x: CGFloat(50 + direction.x * radius), y: CGFloat(50 - direction.y * radius))
                if outline.contains(point) { low = radius } else { high = radius }
            }
            return direction * low * 0.012
        }
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for ring in 0...rings {
            let latitude = Float(ring) / Float(rings) * .pi - .pi / 2
            for point in contour {
                positions.append([point.x * cos(latitude), point.y * cos(latitude), 0.28 * sin(latitude)])
                normals.append(
                    simd_normalize(
                        SIMD3(
                            point.x * cos(latitude), point.y * cos(latitude),
                            sin(latitude) * 0.9)))
            }
        }
        let row = UInt32(segments + 1)
        for ring in 0..<UInt32(rings) {
            for segment in 0..<UInt32(segments) {
                let a = ring * row + segment
                let b = a + 1
                let c = b + row
                let d = a + row
                indices += [a, b, c, a, c, d]
            }
        }
        var descriptor = MeshDescriptor(name: "herm-\(body)")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        let mesh = (try? MeshResource.generate(from: [descriptor])) ?? OfficeLowPolyMesh.sphere(radius: 0.5)
        meshes[body] = mesh
        return mesh
    }
}
