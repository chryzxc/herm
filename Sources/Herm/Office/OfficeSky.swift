import AppKit
import RealityKit
import simd

/// The sky around the office: a gradient dome, sun, moon, stars and a layer of
/// low-poly clouds. Colors follow `OfficeDaylight`; the only motion is a slow
/// cloud drift, one transform per frame, which stops under Reduce Motion.
///
/// Sky geometry must not shadow the office, which needs
/// `DynamicLightShadowComponent` (macOS 15). macOS 14 keeps the flat
/// background colour and shows clouds only; their soft shadows are real.
@MainActor
final class OfficeSky {
    let root = Entity()
    private let cloudLayer = Entity()
    private var cloudTops: [ModelEntity] = []
    private var cloudBases: [ModelEntity] = []
    private var dome: ModelEntity?
    private var domeTexture: TextureResource?
    private var sun: ModelEntity?
    private var moon: ModelEntity?
    private var stars: ModelEntity?
    private var applied: OfficeDaylight?

    private static let domeRadius: Float = 520

    init() {
        root.name = "office-sky"
        cloudLayer.name = "cloud-layer"
        root.addChild(cloudLayer)
        buildClouds()
        if #available(macOS 15.0, *) {
            buildDome()
            let disc = OfficeLowPolyMesh.sphere(radius: 0.5)
            sun = celestial(disc, name: "sun", size: 26)
            moon = celestial(disc, name: "moon", size: 16)
            stars = starField()
            for entity in [sun, moon, stars].compactMap({ $0 }) { root.addChild(entity) }
            castsNoShadow(root)
        }
    }

    func apply(_ daylight: OfficeDaylight) {
        guard daylight != applied else { return }
        applied = daylight
        let top = UnlitMaterial(color: daylight.cloudTop), base = UnlitMaterial(color: daylight.cloudBase)
        for cloud in cloudTops { cloud.model?.materials = [top] }
        for cloud in cloudBases { cloud.model?.materials = [base] }
        if let image = Self.gradient(daylight) {
            if let domeTexture { try? domeTexture.replace(withImage: image, options: .init(semantic: .color)) }
            else if let texture = try? TextureResource.generate(from: image, options: .init(semantic: .color)) {
                domeTexture = texture
                var material = UnlitMaterial()
                material.color = .init(tint: .white, texture: .init(texture))
                if #available(macOS 15.0, *) { material.faceCulling = .none }
                dome?.model?.materials = [material]
            }
        }
        let distance = Self.domeRadius - 30
        sun?.position = daylight.sunDirection * distance
        sun?.isEnabled = daylight.sunElevation > -3
        sun?.model?.materials = [UnlitMaterial(color: daylight.sunDisc)]
        moon?.position = OfficeDaylight.moonDirection(opposite: daylight.sunDirection) * distance
        moon?.isEnabled = daylight.night > 0.3
        moon?.model?.materials = [UnlitMaterial(color: daylight.moonDisc)]
        stars?.isEnabled = daylight.stars > 0.02
        var starMaterial = UnlitMaterial(color: daylight.starColor)
        if #available(macOS 15.0, *) { starMaterial.faceCulling = .none }
        stars?.model?.materials = [starMaterial]
    }

    /// Clouds circle the site about once every half hour.
    func drift(delta: TimeInterval) {
        let angle = Float(min(delta, 0.1)) * 0.0035
        cloudLayer.orientation = simd_quatf(angle: angle, axis: [0, 1, 0]) * cloudLayer.orientation
    }

    // MARK: Construction

    /// Deterministic, so clouds keep their shapes across theme rebuilds.
    private func buildClouds() {
        let puff = OfficeLowPolyMesh.sphere(radius: 0.5)
        var seed: UInt32 = 0x9E37_79B9
        func random() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24)
        }
        for index in 0..<22 {
            // Clouds keep clear of the site so they never hide the office from
            // the overhead camera; they gather over the fields and the horizon.
            let angle = Float(index) / 22 * 2 * .pi + random() * 0.25
            let radius: Float = 80 + random() * 170
            let cloud = Entity()
            cloud.name = "cloud"
            cloud.position = [cos(angle) * radius, 32 + random() * 22, sin(angle) * radius]
            cloud.orientation = simd_quatf(angle: random() * .pi, axis: [0, 1, 0])
            let scale: Float = 0.8 + random() * 0.8
            cloud.scale = SIMD3(repeating: scale)
            let length: Float = 14 + random() * 10
            let puffs = 4 + Int(random() * 3)
            for p in 0..<puffs {
                let t = Float(p) / Float(puffs - 1) - 0.5
                let size: Float = 6 + (1 - abs(t) * 1.6) * 6 + random() * 2
                let top = ModelEntity(mesh: puff, materials: [])
                top.scale = [size * 1.3, size * 0.85, size]
                top.position = [t * length, size * 0.22, (random() - 0.5) * 3]
                cloud.addChild(top)
                cloudTops.append(top)
            }
            // A flat, slightly darker base gives each cloud a readable underside.
            let base = ModelEntity(mesh: puff, materials: [])
            base.scale = [length + 7, 3, 8]
            base.position = [0, -1.2, 0]
            cloud.addChild(base)
            cloudBases.append(base)
            cloudLayer.addChild(cloud)
        }
    }

    @available(macOS 15.0, *)
    private func buildDome() {
        // Latitude rings from zenith to nadir; v runs down the gradient texture.
        let rings = 48, segments = 48
        var positions: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        for ring in 0...rings {
            let v = Float(ring) / Float(rings)
            let polar = v * .pi
            for segment in 0...segments {
                let u = Float(segment) / Float(segments)
                let azimuth = u * 2 * .pi
                positions.append([sin(polar) * cos(azimuth), cos(polar), sin(polar) * sin(azimuth)] * Self.domeRadius)
                uvs.append([u, 1 - v])
            }
        }
        let row = UInt32(segments + 1)
        for ring in 0..<UInt32(rings) {
            for segment in 0..<UInt32(segments) {
                let a = ring * row + segment, b = a + 1, c = a + row + 1, d = a + row
                indices += [a, b, c, a, c, d]
            }
        }
        var descriptor = MeshDescriptor(name: "sky-dome")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(positions.map { -simd_normalize($0) })
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return }
        let dome = ModelEntity(mesh: mesh, materials: [])
        dome.name = "sky-dome"
        root.addChild(dome)
        self.dome = dome
    }

    private func celestial(_ mesh: MeshResource, name: String, size: Float) -> ModelEntity {
        let entity = ModelEntity(mesh: mesh, materials: [])
        entity.name = name
        entity.scale = SIMD3(repeating: size)
        return entity
    }

    /// Several hundred small quads merged into one mesh, facing the site.
    private func starField() -> ModelEntity? {
        var seed: UInt32 = 0x2545_F491
        func random() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24)
        }
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        let radius = Self.domeRadius - 10
        for _ in 0..<420 {
            let azimuth = random() * 2 * .pi
            let elevation = asin(0.08 + random() * 0.92)
            let direction = SIMD3<Float>(cos(elevation) * cos(azimuth), sin(elevation), cos(elevation) * sin(azimuth))
            let center = direction * radius
            let right = simd_normalize(simd_cross(direction, [0, 1, 0.001]))
            let up = simd_cross(right, direction)
            let size: Float = 0.35 + random() * random() * 1.1
            let base = UInt32(positions.count)
            for corner in [SIMD2<Float>(-1, -1), [1, -1], [1, 1], [-1, 1]] {
                positions.append(center + (right * corner.x + up * corner.y) * size)
                normals.append(-direction)
            }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        var descriptor = MeshDescriptor(name: "star-field")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }
        let entity = ModelEntity(mesh: mesh, materials: [])
        entity.name = "stars"
        return entity
    }

    @available(macOS 15.0, *)
    private func castsNoShadow(_ entity: Entity) {
        if entity is ModelEntity { entity.components.set(DynamicLightShadowComponent(castsShadow: false)) }
        for child in entity.children { castsNoShadow(child) }
    }

    /// Zenith to nadir: deep sky, a bright band at the horizon, then haze.
    private static func gradient(_ daylight: OfficeDaylight) -> CGImage? {
        let height = 128
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [daylight.zenith, daylight.zenith, daylight.horizon, daylight.horizon, daylight.haze, daylight.haze].map(\.cgColor) as CFArray
        let locations: [CGFloat] = [0, 0.12, 0.47, 0.5, 0.53, 1]
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) else { return nil }
        // CoreGraphics draws bottom-up; row 0 of the image is the zenith.
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
        return context.makeImage()
    }
}
