import AppKit
import RealityKit
import simd

/// Collapses static scenery into one mesh per material.
///
/// The authored office is thousands of small boxes. RealityKit updates every
/// mesh entity on the main thread each frame, so leaving them separate kept
/// the main thread saturated and made the whole Dock stutter. Navigation and
/// obstacles are captured from the hierarchy before this runs.
@MainActor
enum OfficeStaticMeshBatcher {
    private struct MaterialKey: Hashable {
        let unlit: Bool
        let color: NSColor
        let roughness: Float
        let metallic: Float
    }

    /// A reference type so appends grow the arrays in place instead of
    /// copying an ever-larger batch out of the dictionary for every entity.
    private final class Batch {
        let material: any RealityKit.Material
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        init(material: any RealityKit.Material) { self.material = material }
    }

    /// Geometry read once per shared mesh; `MeshResource.contents` copies buffers.
    private struct Geometry {
        let materialIndex: Int
        let transform: simd_float4x4
        let positions: [SIMD3<Float>]
        let normals: [SIMD3<Float>]
        let indices: [UInt32]
    }

    /// Entities the scene updates or hit-tests after the build stay separate.
    static func isDynamic(_ entity: Entity) -> Bool {
        entity.name.hasPrefix("work-screen-") || entity.name == "main-office-extended-screen"
            || entity.name == "office-kanban-board" || entity.components.has(CollisionComponent.self)
            || !entity.isEnabled
    }

    static func flatten(_ root: Entity) {
        var batches: [MaterialKey: Batch] = [:]
        var geometry: [ObjectIdentifier: CachedMesh] = [:]
        var merged: [Entity] = []

        func visit(_ entity: Entity) {
            if isDynamic(entity) { return }
            if let model = entity as? ModelEntity, append(model, relativeTo: root, into: &batches, geometry: &geometry)
            {
                merged.append(model)
            }
            for child in entity.children { visit(child) }
        }
        for child in root.children { visit(child) }
        guard !merged.isEmpty else { return }

        let batched = Entity()
        batched.name = "static-scenery"
        for batch in batches.values where !batch.indices.isEmpty {
            var descriptor = MeshDescriptor(name: "static-scenery")
            descriptor.positions = MeshBuffers.Positions(batch.positions)
            descriptor.normals = MeshBuffers.Normals(batch.normals)
            descriptor.primitives = .triangles(batch.indices)
            guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return }
            batched.addChild(ModelEntity(mesh: mesh, materials: [batch.material]))
        }
        // Detach children first so their subtrees are not merged twice.
        for model in merged {
            for child in Array(model.children) {
                let transform = child.transformMatrix(relativeTo: root)
                model.parent?.addChild(child)
                child.setTransformMatrix(transform, relativeTo: root)
            }
            model.removeFromParent()
        }
        prune(root)
        root.addChild(batched)
    }

    /// Returns false when the entity cannot be merged and must stay as-is.
    private static func append(
        _ entity: ModelEntity, relativeTo root: Entity, into batches: inout [MaterialKey: Batch],
        geometry cache: inout [ObjectIdentifier: CachedMesh]
    ) -> Bool {
        guard let model = entity.model else { return false }
        let mesh = model.mesh
        let id = ObjectIdentifier(mesh)
        let cached = cache[id] ?? CachedMesh(mesh: mesh, pieces: extract(mesh))
        cache[id] = cached
        guard let pieces = cached.pieces else { return false }
        var keyed: [(MaterialKey, any RealityKit.Material)] = []
        for piece in pieces {
            guard model.materials.indices.contains(piece.materialIndex),
                let key = key(for: model.materials[piece.materialIndex])
            else { return false }
            keyed.append((key, model.materials[piece.materialIndex]))
        }
        let world = entity.transformMatrix(relativeTo: root)
        for (piece, (key, material)) in zip(pieces, keyed) {
            let batch: Batch
            if let existing = batches[key] {
                batch = existing
            } else {
                batch = Batch(material: material)
                batches[key] = batch
            }
            let transform = world * piece.transform
            let normalMatrix = simd_float3x3(
                columns: (
                    SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                    SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                    SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
                )
            ).inverse.transpose
            let base = UInt32(batch.positions.count)
            batch.positions += transformed(piece.positions, by: transform, translate: true)
            batch.normals += transformed(
                piece.normals,
                by: simd_float4x4(
                    SIMD4(normalMatrix.columns.0, 0), SIMD4(normalMatrix.columns.1, 0),
                    SIMD4(normalMatrix.columns.2, 0), SIMD4(0, 0, 0, 1)), translate: false)
            batch.indices += piece.indices.withUnsafeBufferPointer { source in
                [UInt32](unsafeUninitializedCapacity: source.count) { out, count in
                    var i = 0
                    while i < source.count {
                        out[i] = source[i] &+ base
                        i &+= 1
                    }
                    count = source.count
                }
            }
        }
        return true
    }

    /// Scalar math and `while` loops over raw floats: generic SIMD operators
    /// and range iteration are unspecialized in debug builds and made
    /// flattening the office's vertices take many seconds.
    /// Normals (translate == false) are renormalized.
    private static func transformed(_ vectors: [SIMD3<Float>], by m: simd_float4x4, translate: Bool) -> [SIMD3<Float>] {
        let c0 = m.columns.0
        let c1 = m.columns.1
        let c2 = m.columns.2
        let c3 = m.columns.3
        let m00 = c0.x
        let m10 = c0.y
        let m20 = c0.z
        let m01 = c1.x
        let m11 = c1.y
        let m21 = c1.z
        let m02 = c2.x
        let m12 = c2.y
        let m22 = c2.z
        let tx: Float = translate ? c3.x : 0
        let ty: Float = translate ? c3.y : 0
        let tz: Float = translate ? c3.z : 0
        // SIMD3<Float> is laid out as four floats; the fourth is padding.
        precondition(MemoryLayout<SIMD3<Float>>.stride == 4 * MemoryLayout<Float>.stride)
        return vectors.withUnsafeBufferPointer { source in
            [SIMD3<Float>](unsafeUninitializedCapacity: source.count) { buffer, count in
                guard let input = source.baseAddress, let output = buffer.baseAddress else {
                    count = 0
                    return
                }
                let from = UnsafeRawPointer(input).assumingMemoryBound(to: Float.self)
                let to = UnsafeMutableRawPointer(output).assumingMemoryBound(to: Float.self)
                var o = 0
                let end = source.count &* 4
                while o < end {
                    let x = from[o]
                    let y = from[o + 1]
                    let z = from[o + 2]
                    var rx = m00 * x + m01 * y + m02 * z + tx
                    var ry = m10 * x + m11 * y + m12 * z + ty
                    var rz = m20 * x + m21 * y + m22 * z + tz
                    if !translate {
                        let length = (rx * rx + ry * ry + rz * rz).squareRoot()
                        if length > 0 {
                            rx /= length
                            ry /= length
                            rz /= length
                        }
                    }
                    to[o] = rx
                    to[o + 1] = ry
                    to[o + 2] = rz
                    to[o + 3] = 0
                    o &+= 4
                }
                count = source.count
            }
        }
    }

    /// Holds the mesh so its identifier cannot be reused by a later mesh.
    private struct CachedMesh {
        let mesh: MeshResource
        let pieces: [Geometry]?
    }

    private static func extract(_ mesh: MeshResource) -> [Geometry]? {
        let contents = mesh.contents
        let instances: [(model: String, transform: simd_float4x4)] =
            contents.instances.isEmpty
            ? contents.models.map { ($0.id, matrix_identity_float4x4) }
            : contents.instances.map { ($0.model, $0.transform) }
        var pieces: [Geometry] = []
        for instance in instances {
            guard let meshModel = contents.models[instance.model] else { return nil }
            for part in meshModel.parts {
                guard let normals = part.normals?.elements, let indices = part.triangleIndices?.elements else {
                    return nil
                }
                pieces.append(
                    Geometry(
                        materialIndex: part.materialIndex, transform: instance.transform,
                        positions: part.positions.elements, normals: normals, indices: indices))
            }
        }
        return pieces
    }

    /// Only flat, opaque colors merge; translucent glass keeps per-entity sorting.
    private static func key(for material: any RealityKit.Material) -> MaterialKey? {
        if let simple = material as? SimpleMaterial, simple.color.texture == nil, simple.color.tint.alphaComponent >= 1
        {
            return MaterialKey(
                unlit: false, color: simple.color.tint, roughness: scalar(simple.roughness),
                metallic: scalar(simple.metallic))
        }
        // Light pools are unlit with an opacity texture; merged meshes carry
        // no UVs, so they must stay separate or they render invisible.
        if let unlit = material as? UnlitMaterial, unlit.color.texture == nil, unlit.color.tint.alphaComponent >= 1,
            case .opaque = unlit.blending
        {
            return MaterialKey(unlit: true, color: unlit.color.tint, roughness: 0, metallic: 0)
        }
        return nil
    }

    private static func scalar(_ parameter: MaterialScalarParameter) -> Float {
        if case .float(let value) = parameter { return value }
        return .nan
    }

    private static func prune(_ entity: Entity) {
        for child in Array(entity.children) {
            prune(child)
            if type(of: child) == Entity.self, child.children.isEmpty, !isDynamic(child) { child.removeFromParent() }
        }
    }
}
