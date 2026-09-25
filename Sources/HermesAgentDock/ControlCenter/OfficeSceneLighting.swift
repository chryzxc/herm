import AppKit
import RealityKit

/// The office's light rig: a key light that is the sun by day and the moon at
/// night, a sky-tinted fill from the opposite side, and the sky gradient as
/// image-based light. `OfficeDaylight` sets every value from the local clock.
@MainActor
struct OfficeSceneLighting {
    let key: DirectionalLight
    let fill: DirectionalLight

    init(root: Entity, daylight: OfficeDaylight) {
        key = DirectionalLight()
        key.name = "office-key-light"
        fill = DirectionalLight()
        fill.name = "office-fill-light"
        root.addChild(key)
        root.addChild(fill)
        apply(daylight)
    }

    func apply(_ daylight: OfficeDaylight) {
        let direction = daylight.keyDirection
        key.look(at: .zero, from: direction * 30, relativeTo: nil)
        // The fill comes from the other side at a steady mid height.
        let across = simd_normalize(SIMD3(-direction.x, 0, -direction.z) + [0, 0, -0.0001])
        fill.look(at: .zero, from: (across * 0.85 + [0, 0.5, 0]) * 30, relativeTo: nil)
        key.light.color = daylight.keyColor
        key.light.intensity = daylight.keyIntensity
        fill.light.color = daylight.fillColor
        fill.light.intensity = daylight.fillIntensity
    }

    /// Shadow reach follows the camera so near views keep crisp shadows and
    /// the whole-office view still grounds every wall and desk.
    func updateShadow(cameraDistance: Float) {
        // Stepped, so a zoom swaps the shadow map a handful of times instead
        // of rebuilding it every frame.
        let reach = min(90, max(24, ((cameraDistance * 1.9 + 8) / 8).rounded(.up) * 8))
        if key.shadow?.maximumDistance != reach {
            key.shadow = DirectionalLightComponent.Shadow(maximumDistance: reach, depthBias: 4)
        }
    }

    /// Applies the sky as image-based light. The background colour matches
    /// the horizon; on macOS 15 the sky dome covers it.
    static func applyEnvironment(to view: ARView, daylight: OfficeDaylight) {
        view.environment.background = .color(daylight.horizon)
        guard let resource = environment(for: daylight) else { return }
        view.environment.lighting.resource = resource
        view.environment.lighting.intensityExponent = daylight.environmentExponent
    }

    /// Resources are cached per two degrees of sun elevation, so a day
    /// generates each lighting step once.
    private static var cache: [Int: EnvironmentResource] = [:]

    /// macOS 14 keeps RealityKit's default light.
    private static func environment(for daylight: OfficeDaylight) -> EnvironmentResource? {
        guard #available(macOS 15.0, *) else { return nil }
        let step = Int((daylight.sunElevation / 2).rounded())
        if let cached = cache[step] { return cached }
        guard let image = skyImage(daylight), let resource = try? EnvironmentResource(equirectangular: image) else { return nil }
        cache[step] = resource
        return resource
    }

    /// A vertical gradient: zenith, horizon, then haze toward the ground. The
    /// visible sky is saturated to survive tone mapping; ambient light takes a
    /// softened copy so daylight does not turn the office blue, and a lifted
    /// moonlit copy at night so the surroundings stay readable.
    private static func skyImage(_ daylight: OfficeDaylight) -> CGImage? {
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let moonlit = NSColor(srgbRed: 0.46, green: 0.54, blue: 0.74, alpha: 1)
        func soft(_ color: NSColor) -> NSColor {
            let day = color.blended(withFraction: CGFloat(0.5 * (1 - daylight.night)), of: white) ?? color
            return day.blended(withFraction: CGFloat(0.7 * daylight.night), of: moonlit) ?? day
        }
        let width = 128, height = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [daylight.zenith, daylight.horizon, daylight.haze, daylight.haze].map { soft($0).cgColor } as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 0.6, 1]) else { return nil }
        // CoreGraphics' origin is bottom-left; the equirect's first row is the zenith.
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
        return context.makeImage()
    }
}
