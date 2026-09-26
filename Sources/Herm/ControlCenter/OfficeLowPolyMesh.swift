import RealityKit
import simd

/// Low-poly stand-ins for RealityKit's rounded box and sphere.
///
/// `generateBox(size:cornerRadius:)` emits ~6,900 vertices for any non-zero
/// radius and `generateSphere` ~4,200. Across thousands of office props that
/// made a ~9-million-vertex scene. These keep the silhouette at office zoom
/// with a few hundred vertices.
@MainActor
enum OfficeLowPolyMesh {
    private static var cache: [String: MeshResource] = [:]

    static func box(size: SIMD3<Float>, cornerRadius: Float) -> MeshResource {
        let radius = min(max(0, cornerRadius), size.min() / 2)
        guard radius > 0 else { return .generateBox(size: size) }
        return rounded(halfExtents: size / 2, radius: radius, cornerSegments: 2)
    }

    /// A sphere as a cube whose corners round fully.
    static func sphere(radius: Float) -> MeshResource {
        rounded(halfExtents: SIMD3(repeating: radius), radius: radius, cornerSegments: 3)
    }

    /// A flat, double-sided ring of outer radius 0.5 in the XY plane, facing +Z.
    static func ring(thickness: Float) -> MeshResource {
        let key = "ring-\(thickness)"
        if let cached = cache[key] { return cached }
        let segments = 40
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for i in 0..<segments {
            let a = Float(i) / Float(segments) * 2 * .pi
            let dir = SIMD3<Float>(cos(a), sin(a), 0)
            positions += [dir * 0.5, dir * (0.5 - thickness)]
            let (o0, i0) = (UInt32(i * 2), UInt32(i * 2 + 1))
            let (o1, i1) = (UInt32((i + 1) % segments * 2), UInt32((i + 1) % segments * 2 + 1))
            indices += [o0, o1, i0, i0, o1, i1, o0, i0, o1, i0, i1, o1]
        }
        var descriptor = MeshDescriptor(name: key)
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        let mesh = (try? MeshResource.generate(from: [descriptor])) ?? .generatePlane(width: 1, height: 1)
        cache[key] = mesh
        return mesh
    }

    /// Rounded box built from six face grids: points in the corner band are
    /// pushed onto a sphere of `radius` around the clamped inner box.
    private static func rounded(halfExtents h: SIMD3<Float>, radius r: Float, cornerSegments s: Int) -> MeshResource {
        let key = "\(h)-\(r)-\(s)"
        if let cached = cache[key] { return cached }
        let inner = h - SIMD3(repeating: r)
        // Band offsets spaced by angle, so the arc is evenly faceted.
        let band = (1...s).map { r * tan(Float($0) / Float(s) * .pi / 4) }
        func coordinates(_ axis: Int) -> [Float] {
            let e = inner[axis]
            return band.reversed().map { -e - $0 } + [-e, e] + band.map { e + $0 }
        }
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        // (normal axis, sign, u axis, v axis) with u × v pointing outward.
        let faces: [(Int, Float, Int, Int)] = [(0, 1, 1, 2), (0, -1, 2, 1), (1, 1, 2, 0), (1, -1, 0, 2), (2, 1, 0, 1), (2, -1, 1, 0)]
        for (axis, sign, uAxis, vAxis) in faces {
            let us = coordinates(uAxis), vs = coordinates(vAxis)
            let base = UInt32(positions.count)
            for (j, v) in vs.enumerated() {
                for (i, u) in us.enumerated() {
                    var point = SIMD3<Float>(repeating: 0)
                    point[axis] = sign * (inner[axis] + r)
                    point[uAxis] = u
                    point[vAxis] = v
                    let core = simd_clamp(point, -inner, inner)
                    let normal = simd_normalize(point - core)
                    positions.append(core + normal * r)
                    normals.append(normal)
                    uvs.append([Float(i) / Float(us.count - 1), Float(j) / Float(vs.count - 1)])
                }
            }
            let row = UInt32(us.count)
            for j in 0..<UInt32(vs.count - 1) {
                for i in 0..<UInt32(us.count - 1) {
                    let a = base + j * row + i, b = a + 1, c = a + row + 1, d = a + row
                    indices += [a, b, c, a, c, d]
                }
            }
        }
        var descriptor = MeshDescriptor(name: "office-low-poly")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        let mesh = (try? MeshResource.generate(from: [descriptor])) ?? .generateBox(size: h * 2, cornerRadius: r)
        cache[key] = mesh
        return mesh
    }
}
