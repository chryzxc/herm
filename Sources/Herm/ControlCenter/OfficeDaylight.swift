import AppKit
import simd

/// The office sky for a moment in local time. The sun's position comes from
/// the date and clock (solar declination and hour angle at a fixed mid
/// latitude), so sunrise and sunset drift with the seasons. Everything else,
/// from sky colors to light intensities, follows the sun's elevation.
///
/// Scene axes: +x is east, -z is north, so the midday sun sits over the
/// forecourt, behind the default camera.
struct OfficeDaylight: Equatable {
    /// Degrees above the horizon; negative after sunset.
    let sunElevation: Float
    /// Unit vector toward the sun.
    let sunDirection: SIMD3<Float>

    static let latitude: Float = 35

    init(date: Date, calendar: Calendar = .current) {
        let zone = calendar.timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let day = Float(calendar.ordinality(of: .day, in: .year, for: date) ?? 172)
        // Solar time ignores daylight saving; the zone's standard meridian
        // stands in for longitude, so solar noon is near 12:00 standard time.
        let dst = Float(zone.daylightSavingTimeOffset(for: date)) / 3600
        let hours = Float(parts.hour ?? 12) + Float(parts.minute ?? 0) / 60 + Float(parts.second ?? 0) / 3600 - dst
        self.init(dayOfYear: day, solarHour: hours)
    }

    init(dayOfYear: Float, solarHour: Float) {
        let declination = -23.44 * Float.pi / 180 * cos(2 * .pi / 365 * (dayOfYear + 10))
        let hourAngle = (solarHour - 12) * 15 * .pi / 180
        let phi = Self.latitude * .pi / 180
        let east = -cos(declination) * sin(hourAngle)
        let north = sin(declination) * cos(phi) - cos(declination) * cos(hourAngle) * sin(phi)
        let up = sin(declination) * sin(phi) + cos(declination) * cos(hourAngle) * cos(phi)
        sunDirection = simd_normalize([east, up, -north])
        sunElevation = asin(max(-1, min(1, up))) * 180 / .pi
    }

    /// Two moments look the same when the sun has moved less than a quarter degree.
    static func == (a: Self, b: Self) -> Bool {
        abs(a.sunElevation - b.sunElevation) < 0.25 && simd_distance(a.sunDirection, b.sunDirection) < 0.005
    }

    // MARK: Phases

    /// 0 in daylight, 1 once civil twilight has ended.
    var night: Float { 1 - ramp(-9, 2, sunElevation) }
    /// Peaks while the sun is low: sunrise and sunset colors.
    var golden: Float { ramp(-7, -1, sunElevation) * (1 - ramp(5, 18, sunElevation)) }
    /// Stars fade in during nautical twilight.
    var stars: Float { 1 - ramp(-12, -4, sunElevation) }
    var isDark: Bool { night > 0.5 }

    // MARK: Sky

    var zenith: NSColor { color(day: [0.16, 0.44, 0.93], golden: [0.34, 0.40, 0.74], night: [0.02, 0.035, 0.09]) }
    var horizon: NSColor { color(day: [0.60, 0.80, 1.0], golden: [1.0, 0.64, 0.38], night: [0.13, 0.18, 0.32]) }
    /// Below the horizon, behind the hills: a darker haze.
    var haze: NSColor { color(day: [0.60, 0.74, 0.86], golden: [0.78, 0.56, 0.50], night: [0.09, 0.12, 0.21]) }
    var cloudTop: NSColor { color(day: [0.99, 0.99, 1.0], golden: [1.0, 0.84, 0.74], night: [0.15, 0.18, 0.27]) }
    var cloudBase: NSColor { color(day: [0.84, 0.87, 0.93], golden: [0.86, 0.66, 0.66], night: [0.10, 0.12, 0.20]) }
    var sunDisc: NSColor { color(day: [1.0, 0.98, 0.90], golden: [1.0, 0.70, 0.40], night: [1.0, 0.70, 0.40]) }
    var moonDisc: NSColor { mixColor([0.62, 0.66, 0.74], [0.93, 0.94, 0.98], stars) }
    var starColor: NSColor { mixColor(rgb(zenith), [0.92, 0.94, 1.0], stars) }

    // MARK: Light

    /// Sunlight fades in from just below the horizon; moonlight takes over
    /// only once the sun is gone, so the key light never jumps direction while lit.
    var sunStrength: Float { ramp(-2, 10, sunElevation) }
    var moonStrength: Float { 1 - ramp(-8, -2, sunElevation) }
    var keyDirection: SIMD3<Float> {
        if sunElevation > -2 {
            // Clamp to a low sun so shadows stay on the site at dawn and dusk.
            let flat = simd_normalize(SIMD3(sunDirection.x, 0, sunDirection.z) + [0, 0, 0.0001])
            let elevation = max(sunElevation, 7) * .pi / 180
            return flat * cos(elevation) + [0, sin(elevation), 0]
        }
        return Self.moonDirection(opposite: sunDirection)
    }
    var keyColor: NSColor {
        sunElevation > -2 ? mixColor([1.0, 0.95, 0.87], [1.0, 0.62, 0.36], golden) : rgbColor([0.70, 0.78, 1.0])
    }
    var keyIntensity: Float { sunElevation > -2 ? 3400 * sunStrength : 2600 * moonStrength }
    var fillColor: NSColor { color(day: [0.80, 0.86, 1.0], golden: [0.92, 0.72, 0.92], night: [0.45, 0.52, 0.95]) }
    var fillIntensity: Float { 700 - 100 * night }
    /// Image-based light exponent. Night ambient comes from a lifted moonlit
    /// sky (see `OfficeSceneLighting`), so the countryside stays readable.
    var environmentExponent: Float { -0.45 + 0.65 * night }

    /// The moon rides high and opposite the sun.
    static func moonDirection(opposite sun: SIMD3<Float>) -> SIMD3<Float> {
        let flat = simd_normalize(SIMD3(-sun.x, 0, -sun.z) + [0, 0, 0.0001])
        let elevation: Float = 42 * .pi / 180
        return flat * cos(elevation) + [0, sin(elevation), 0]
    }

    // MARK: Helpers

    private func color(day: SIMD3<Float>, golden goldenTone: SIMD3<Float>, night nightTone: SIMD3<Float>) -> NSColor {
        let base = simd_mix(day, nightTone, SIMD3(repeating: night))
        return rgbColor(simd_mix(base, goldenTone, SIMD3(repeating: golden * 0.85)))
    }

    private func mixColor(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> NSColor {
        rgbColor(simd_mix(a, b, SIMD3(repeating: t)))
    }

    private func rgb(_ color: NSColor) -> SIMD3<Float> {
        let c = color.usingColorSpace(.sRGB) ?? color
        return [Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)]
    }

    private func rgbColor(_ v: SIMD3<Float>) -> NSColor {
        NSColor(srgbRed: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: 1)
    }
}

private func ramp(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}
