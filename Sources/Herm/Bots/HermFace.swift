import SwiftUI

/// What a Herm face shows. Each case is something Hermes reports, except
/// `happy` (hovered) and `sleepy` (hidden Bot), which Herm knows locally.
enum BotMood: String, CaseIterable, Sendable {
    case idle, happy, sleepy
    case thinking, tool, replying, done, failed, stopped
    case approval, clarify, queued, handoff, subagent
    case listening, compressing, offline

    /// States with ongoing motion; the rest hold a still pose without a clock.
    var moves: Bool {
        switch self {
        case .thinking, .tool, .replying, .approval, .clarify, .handoff, .subagent, .listening, .compressing: true
        default: false
        }
    }

    init(activity: BotActivityState) {
        switch activity {
        case .queued: self = .queued
        case .working: self = .tool
        case .waiting: self = .clarify
        case .completed: self = .done
        case .failed: self = .failed
        case .canceled: self = .stopped
        }
    }
}

extension BotMood {
    /// A live session ask that changes the face. Approval outranks clarify,
    /// which outranks compressing; nil keeps the busy or idle face.
    init?(ask: DockActivityState?, compacting: Bool = false) {
        switch ask {
        case .approval: self = .approval
        case .clarification: self = .clarify
        default:
            guard compacting else { return nil }
            self = .compressing
        }
    }

    init?(status: HermesStatus, compacting: Bool) {
        let ask: DockActivityState? = switch status {
        case .needsApproval: .approval
        case .needsClarification: .clarification
        default: nil
        }
        self.init(ask: ask, compacting: compacting)
    }
}

/// splitmix64 over a Bot's seed: the same profile ID always draws the same traits.
struct BotSeededRandom {
    var state: UInt64

    init(id: String) { state = BotAvatarPresentation.seed(for: id) }

    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

/// The seeded traits of a Herm face, drawn in a 100-unit box.
struct HermFaceGenes: Equatable {
    enum Body: CaseIterable { case pebble, orb, drop, bean, tile }
    enum Eyes: CaseIterable { case pill, dot, visor, slit }

    static let palettes = [("#8fe3c8", "#2a957a"), ("#ffd27f", "#dd8429"), ("#ad9fff", "#5640dc"), ("#ff9f94", "#d03f37"),
                           ("#8fc8ff", "#2b69dc"), ("#ffb47f", "#dc5c2a"), ("#f8a9e5", "#b93fa2"), ("#c9ea74", "#679a1a"),
                           ("#80e2f1", "#1a8eac"), ("#ffdb70", "#c4940f")]
    static let grays = [("#f2f2f2", "#8a8a8a"), ("#e0e0e0", "#666666"), ("#fafafa", "#9c9c9c"), ("#d6d6d6", "#555555")]

    let palette: Int
    let gray: Int
    let body: Body
    let eyes: Eyes
    /// Resting lean in degrees, ±7.
    let tilt: Double
    let sparkle: Bool

    init(id: String) {
        var random = BotSeededRandom(id: id)
        func pick(_ n: Int) -> Int { min(n - 1, Int(random.next() * Double(n))) }
        palette = pick(Self.palettes.count)
        gray = pick(Self.grays.count)
        body = Body.allCases[pick(Body.allCases.count)]
        eyes = Eyes.allCases[pick(Eyes.allCases.count)]
        tilt = (random.next() * 2 - 1) * 7
        sparkle = random.next() < 0.35
    }
}

/// How a skin colors the faces: hued bodies by default, grays on paper-like
/// skins, the accent on screen skins. Ink outlines follow sticker-style skins.
enum HermFaceTone: Equatable {
    case hue, gray, accent

    init(theme: DockThemeID?) {
        switch theme {
        case .eInk, .mono: self = .gray
        case .terminal, .hud: self = .accent
        default: self = .hue
        }
    }

    /// Skins whose surfaces are glossy keep the face's sheen, rim light,
    /// highlight and sparkle; every other skin draws it matte.
    static func glossy(_ theme: DockThemeID?) -> Bool {
        theme == .glass || theme == .clay
    }

    static func outline(_ theme: DockThemeID?) -> CGFloat? {
        switch theme {
        case .cartoon: 3.4
        case .brutalist: 4
        case .eInk: 3
        default: nil
        }
    }
}

/// Tiny absolute-command SVG path reader (M L H V C Q Z) for the face's fixed shapes.
enum HermFacePath {
    static func parse(_ d: String) -> Path {
        var tokens: [String] = [], current = ""
        func flush() { if !current.isEmpty { tokens.append(current); current = "" } }
        for ch in d {
            if ch.isLetter { flush(); tokens.append(String(ch)) }
            else if ch == " " || ch == "," { flush() }
            else if ch == "-" { flush(); current = "-" }
            else { current.append(ch) }
        }
        flush()
        var path = Path(), i = 0, command = "M", last = CGPoint.zero
        func number() -> CGFloat { defer { i += 1 }; return i < tokens.count ? CGFloat(Double(tokens[i]) ?? 0) : 0 }
        func point() -> CGPoint { let x = number(); return CGPoint(x: x, y: number()) }
        while i < tokens.count {
            if Double(tokens[i]) == nil {
                command = tokens[i]; i += 1
                if command == "Z" { path.closeSubpath(); continue }
            }
            switch command {
            case "M": last = point(); path.move(to: last); command = "L"
            case "L": last = point(); path.addLine(to: last)
            case "H": last.x = number(); path.addLine(to: last)
            case "V": last.y = number(); path.addLine(to: last)
            case "C": let a = point(), b = point(); last = point(); path.addCurve(to: last, control1: a, control2: b)
            case "Q": let c = point(); last = point(); path.addQuadCurve(to: last, control: c)
            default: i += 1
            }
        }
        return path
    }

    static let bodies: [HermFaceGenes.Body: Path] = [
        .pebble: parse("M48 7 C72 5 93 24 92 51 C91 76 74 94 49 93 C24 92 7 75 8 50 C9 25 25 9 48 7Z"),
        .orb: parse("M50 8 C76 8 92 26 92 52 C92 77 75 92 50 92 C25 92 8 77 8 52 C8 26 24 8 50 8Z"),
        .drop: parse("M54 6 C70 18 92 34 92 58 C92 79 74 93 50 93 C26 93 9 78 9 57 C9 33 34 20 54 6Z"),
        .bean: parse("M30 12 C46 4 60 16 72 12 C88 8 95 30 92 52 C89 78 70 93 47 92 C22 91 6 75 8 51 C10 33 16 19 30 12Z"),
        .tile: parse("M30 9 H70 C84 9 91 16 91 30 V70 C91 84 84 91 70 91 H30 C16 91 9 84 9 70 V30 C9 16 16 9 30 9Z"),
    ]
    static let sheen = parse("M0 38 C28 18 72 18 100 38 V0 H0Z")
    static let happy = parse("M-7 3 Q0 -7 7 3")
    static let closed = parse("M-6.5 0 Q0 4 6.5 0")
    static let flat = parse("M-6 0 H6")
    static let cross = parse("M-5 -5 L5 5 M5 -5 L-5 5")
    static let squint = [parse("M-5 -5 L4 0 L-5 5"), parse("M5 -5 L-4 0 L5 5")]
    static let smile = parse("M43 66 Q50 72 57 66")
    static let frown = parse("M43 70 Q50 64 57 70")
    static let flatMouth = parse("M44 68 H56")
    static let check = parse("M-5 0 L-1.5 4 L5.5 -4")
    static let clockHand = parse("M0 -3 V0 L2.5 1.5")
}

extension BotFaceMark {
    private static let ink = hex("#15121c")

    private static func hex(_ value: String) -> Color {
        let rgb = UInt32(value.dropFirst(), radix: 16) ?? 0
        return Color(.sRGB, red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    /// Draws a Herm face into a `size` square at the context origin. Rings and
    /// hints reach 20% past the square, so give the canvas that margin.
    /// `theme` nil is the neutral face saved to Hermes as a PNG.
    static func draw(in ctx: inout GraphicsContext, id: String, size: CGFloat, mood: BotMood,
                     pose: BotFacePose, theme: DockThemeID?, originalColors: Bool = false) {
        let genes = HermFaceGenes(id: id)
        let colors = DockThemePalette(theme: theme ?? .glass)
        let tone = HermFaceTone(theme: theme)
        // Unskinned exports retain their original colors so previously saved faces remain recognizable.
        let (lite, deep) = theme != nil && tone == .hue && !originalColors
            ? (colors.fill(DockAccentColor.identity(for: id)), colors.fill(DockAccentColor.identity(for: id)).opacity(0.78))
            : bodyColors(genes, tone: tone, colors: colors)
        let t = pose.t, moves = pose.t != 0
        ctx.scaleBy(x: size / 100, y: size / 100)
        if mood == .offline { ctx.addFilter(.grayscale(1)); ctx.opacity = 0.5 }
        if mood == .queued { ctx.opacity = 0.8 }

        // Gaze points at what the state is about: the thought, the other Bot, the subagents.
        var gaze = CGSize(width: pose.look.width * 200, height: pose.look.height * 200)
        switch mood {
        case .thinking: gaze = CGSize(width: 5, height: -7)
        case .tool: gaze = CGSize(width: sin(t * 2.6) * 6, height: 1)
        case .handoff: gaze = CGSize(width: 7, height: 0)
        case .subagent: gaze = CGSize(width: 6, height: 5)
        case .approval, .clarify: gaze = CGSize(width: 0, height: 2)
        case .replying: gaze = CGSize(width: sin(t * 0.8) * 2, height: 0)
        case .sleepy, .offline, .done, .happy, .failed, .stopped: gaze = .zero
        default: break
        }

        var bob = 0.0, tilt = genes.tilt, dx = 0.0, sx = 1.0, sy = 1.0, breath = 1 + sin(t * 2.2) * 0.016
        switch mood {
        case .tool, .replying: bob = -abs(sin(t * 4)) * 2.2
        case .approval:
            let p = t.truncatingRemainder(dividingBy: 1.8) / 1.8
            bob = p < 0.25 ? -sin(p / 0.25 * .pi) * 8 : 0
        case .clarify: tilt += 10 + sin(t * 1.6) * 3
        case .handoff: dx = 3 + sin(t * 3) * 1.2
        case .compressing:
            let p = (sin(t * 3) + 1) / 2
            sx = 1 - 0.1 * p; sy = 1 + 0.05 * p
        case .listening: breath = 1.03 + sin(t * 3) * 0.012
        case .queued, .offline, .stopped, .sleepy: breath = 1
        default: break
        }

        let pulse = t.truncatingRemainder(dividingBy: 1.6) / 1.6
        func ring(_ r: Double, _ opacity: Double, _ width: Double, _ color: Color, dash: [CGFloat] = [], rotation: Double = 0) {
            let circle = Path(ellipseIn: CGRect(x: 50 - r, y: 50 - r, width: r * 2, height: r * 2))
                .applying(CGAffineTransform(translationX: 50, y: 50).rotated(by: rotation * .pi / 180).translatedBy(x: -50, y: -50))
            var layer = ctx
            layer.opacity *= opacity
            layer.stroke(circle, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
        }
        func dot(_ x: Double, _ y: Double, _ r: Double, _ color: Color, opacity: Double = 1, stroke: Bool = false) {
            var layer = ctx
            layer.opacity *= opacity
            let shape = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            layer.fill(shape, with: .color(color))
            if stroke { layer.stroke(shape, with: .color(colors.primaryText.opacity(0.2)), lineWidth: 1.5) }
        }
        // Behind the body: the far half of the thinking dots and subagent orbits.
        func orbiters(front: Bool) {
            if mood == .thinking {
                for i in 0..<3 {
                    let a = t * 2.4 + Double(i) * 2.1
                    guard (sin(a) >= 0) == front else { continue }
                    dot(50 + cos(a) * 34, 2 + sin(a) * 6, 4 * (1 + sin(a) * 0.25), colors.accent, opacity: 0.55 + sin(a) * 0.35)
                }
            }
            if mood == .subagent {
                for i in 0..<2 {
                    let a = t * 1.8 + Double(i) * .pi
                    guard (sin(a) >= 0) == front else { continue }
                    dot(50 + cos(a) * 52, 62 + sin(a) * 12, 9, lite, stroke: true)
                }
            }
        }
        orbiters(front: false)

        let lift = min(1, -bob / 30)
        var shadow = ctx
        shadow.opacity *= 0.18 * (1 - lift * 0.5)
        let rx = 30 * (1 - lift * 0.4)
        shadow.fill(Path(ellipseIn: CGRect(x: 50 - rx, y: 93.4, width: rx * 2, height: 7.2)), with: .color(.black))

        var body = ctx
        body.translateBy(x: 50 + dx, y: 92 + bob)
        body.rotate(by: .degrees(tilt))
        body.scaleBy(x: sx * breath, y: sy * breath)
        body.translateBy(x: -50, y: -92)
        let shape = HermFacePath.bodies[genes.body]!
        if tone == .gray {
            body.fill(shape, with: .color(lite))
        } else {
            body.fill(shape, with: .radialGradient(Gradient(stops: [.init(color: lite, location: 0), .init(color: deep, location: 0.62),
                                                                    .init(color: deep, location: 1)]),
                                                   center: CGPoint(x: 34, y: 26), startRadius: 0, endRadius: 80))
        }
        var inside = body
        inside.clip(to: shape)
        let glossy = tone != .gray && HermFaceTone.glossy(theme)
        if glossy { inside.fill(HermFacePath.sheen, with: .color(.white.opacity(0.14))) }
        if tone != .gray {
            inside.fill(Path(ellipseIn: CGRect(x: -8, y: 82, width: 116, height: 48)), with: .color(deep.opacity(0.6)))
        }
        if mood == .failed { inside.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 100)), with: .color(colors.destructive.opacity(0.2))) }
        if let outline = HermFaceTone.outline(theme) {
            body.stroke(shape, with: .color(colors.primaryText), lineWidth: outline)
        } else if glossy {
            body.stroke(shape, with: .linearGradient(Gradient(stops: [.init(color: .white.opacity(0.7), location: 0),
                                                                      .init(color: .white.opacity(0), location: 0.45),
                                                                      .init(color: lite.opacity(0), location: 0.85),
                                                                      .init(color: lite.opacity(0.8), location: 1)]),
                                                     startPoint: CGPoint(x: 50, y: 0), endPoint: CGPoint(x: 50, y: 100)), lineWidth: 2.4)
        }
        if glossy {
            let highlight = Path(ellipseIn: CGRect(x: -11, y: -6, width: 22, height: 12))
                .applying(CGAffineTransform(translationX: 33, y: 24).rotated(by: -24 * .pi / 180))
            body.fill(highlight, with: .color(.white.opacity(0.55)))
            if genes.sparkle {
                var spark = body
                spark.opacity *= moves ? 0.5 + sin(t * 3) * 0.35 : 0.85
                spark.fill(BotOrbitStar().path(in: CGRect(x: 66.5, y: 20, width: 15, height: 15)), with: .color(.white))
            }
        }

        // Eyes and mouth.
        let expression: Path? = switch mood {
        case .done, .happy: HermFacePath.happy
        case .stopped: HermFacePath.flat
        case .offline, .sleepy: HermFacePath.closed
        case .failed: HermFacePath.cross
        default: nil
        }
        let squints = mood == .compressing
        let lid = mood == .queued ? 0.5 : pose.blink
        let wide: CGFloat = [BotMood.listening, .approval, .clarify].contains(mood) ? 1.12 : 1
        var face = body
        face.translateBy(x: 50 + gaze.width, y: 49 + gaze.height)
        let inkStroke = StrokeStyle(lineWidth: 4.4, lineCap: .round, lineJoin: .round)
        if genes.eyes == .visor && expression == nil && !squints {
            var visor = face
            visor.scaleBy(x: 1, y: lid)
            visor.fill(Path(roundedRect: CGRect(x: -20, y: -7.5, width: 40, height: 15), cornerRadius: 7.5), with: .color(ink))
        }
        for (index, side) in [-1.0, 1.0].enumerated() {
            var eye = face
            eye.translateBy(x: side * (genes.eyes == .visor ? 9 : 13), y: 0)
            if squints {
                eye.stroke(HermFacePath.squint[index], with: .color(ink), style: inkStroke)
            } else if let expression {
                eye.stroke(expression, with: .color(ink), style: mood == .failed ? StrokeStyle(lineWidth: 3.6, lineCap: .round) : inkStroke)
            } else {
                eye.scaleBy(x: wide, y: wide * lid)
                switch genes.eyes {
                case .pill:
                    eye.fill(Path(roundedRect: CGRect(x: -3.8, y: -8.5, width: 7.6, height: 17), cornerRadius: 3.8), with: .color(ink))
                    eye.fill(Path(ellipseIn: CGRect(x: -0.5, y: -6, width: 3, height: 3)), with: .color(.white))
                case .dot:
                    eye.fill(Path(ellipseIn: CGRect(x: -6.2, y: -6.2, width: 12.4, height: 12.4)), with: .color(ink))
                    eye.fill(Path(ellipseIn: CGRect(x: 0.1, y: -4.1, width: 3.8, height: 3.8)), with: .color(.white))
                case .visor:
                    eye.fill(Path(ellipseIn: CGRect(x: -3.3, y: -3.3, width: 6.6, height: 6.6)), with: .color(.white))
                case .slit:
                    eye.rotate(by: .degrees(side * -12))
                    eye.fill(Path(roundedRect: CGRect(x: -6.5, y: -2.7, width: 13, height: 5.4), cornerRadius: 2.7), with: .color(ink))
                }
            }
        }
        let mouthStroke = StrokeStyle(lineWidth: 3.6, lineCap: .round)
        switch mood {
        case .replying:
            let ry = moves ? 1.5 + abs(sin(t * 11) * sin(t * 3.3)) * 4.5 : 3
            body.fill(Path(ellipseIn: CGRect(x: 45, y: 68 - ry, width: 10, height: ry * 2)), with: .color(ink))
        case .done, .happy: body.stroke(HermFacePath.smile, with: .color(ink), style: mouthStroke)
        case .listening, .clarify: body.fill(Path(ellipseIn: CGRect(x: 47, y: 64.6, width: 6, height: 6.8)), with: .color(ink))
        case .failed: body.stroke(HermFacePath.frown, with: .color(ink), style: mouthStroke)
        case .stopped: body.stroke(HermFacePath.flatMouth, with: .color(ink), style: mouthStroke)
        default: break
        }

        // In front: rings, waves, hints and the status badge, all in theme tokens.
        orbiters(front: true)
        switch mood {
        case .tool:
            let rotation = (t * 300).truncatingRemainder(dividingBy: 360)
            ring(55, 0.9, 3, colors.accent, dash: [26, 320], rotation: rotation)
            ring(55, 0.35, 3, colors.accent, dash: [6, 340], rotation: rotation + 44)
        case .listening:
            for side in [-1.0, 1.0] {
                for i in 0..<2 {
                    let p = moves ? (t * 1.4 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1) : Double(i) * 0.5
                    let x = 50 + side * (54 + p * 12)
                    var wave = Path()
                    wave.move(to: CGPoint(x: x, y: 38))
                    wave.addQuadCurve(to: CGPoint(x: x, y: 62), control: CGPoint(x: x + side * 7, y: 50))
                    var layer = ctx
                    layer.opacity *= (1 - p) * 0.85
                    layer.stroke(wave, with: .color(colors.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            }
        case .compressing:
            for side in [-1.0, 1.0] {
                let x = 50 + side * (60 - (moves ? (sin(t * 3) + 1) * 3 : 0))
                var chevron = Path()
                chevron.addLines([CGPoint(x: x, y: 40), CGPoint(x: x - side * 7, y: 50), CGPoint(x: x, y: 60)])
                ctx.stroke(chevron, with: .color(colors.accent), style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round))
            }
        case .approval, .clarify:
            if moves { ring(50 + pulse * 16, (1 - pulse) * 0.6, 3, colors.warning) }
        case .queued:
            ring(55, 0.5, 2.5, colors.metadataText, dash: [4, 8])
        case .handoff:
            let p = moves ? t.truncatingRemainder(dividingBy: 1.4) / 1.4 : 0.5
            var arc = Path()
            arc.move(to: CGPoint(x: 72, y: 30))
            arc.addQuadCurve(to: CGPoint(x: 112, y: 30), control: CGPoint(x: 92, y: -14))
            var layer = ctx
            layer.opacity *= 0.5
            layer.stroke(arc, with: .color(colors.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))
            dot(72 + p * 40, 30 - sin(p * .pi) * 22, 4.5, colors.accent)
        default: break
        }

        let badge: Color? = switch mood {
        case .approval, .clarify: colors.warning
        case .failed: colors.destructive
        case .done: colors.success
        case .stopped, .queued: colors.metadataText
        default: nil
        }
        guard let badge else { return }
        var mark = ctx
        mark.translateBy(x: 84, y: 16)
        let disc = Path(ellipseIn: CGRect(x: -11, y: -11, width: 22, height: 22))
        mark.fill(disc, with: .color(badge))
        mark.stroke(disc, with: .color(theme == nil ? .white : colors.surface), lineWidth: 3)
        // Glyphs are unreadable below this; the colored badge still carries the state.
        guard size >= 24 else { return }
        let glyph = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        switch mood {
        case .approval, .clarify, .failed:
            mark.draw(Text(mood == .clarify ? "?" : "!").font(.system(size: 15, weight: .heavy)).foregroundColor(.white), at: .zero)
        case .done: mark.stroke(HermFacePath.check, with: .color(.white), style: glyph)
        case .stopped: mark.fill(Path(roundedRect: CGRect(x: -4, y: -4, width: 8, height: 8), cornerRadius: 1.5), with: .color(.white))
        case .queued:
            mark.stroke(Path(ellipseIn: CGRect(x: -5.5, y: -5.5, width: 11, height: 11)), with: .color(.white), lineWidth: 2)
            mark.stroke(HermFacePath.clockHand, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        default: break
        }
    }

    private static func bodyColors(_ genes: HermFaceGenes, tone: HermFaceTone, colors: DockThemePalette) -> (Color, Color) {
        switch tone {
        case .hue: return (hex(HermFaceGenes.palettes[genes.palette].0), hex(HermFaceGenes.palettes[genes.palette].1))
        case .gray: return (hex(HermFaceGenes.grays[genes.gray].0), hex(HermFaceGenes.grays[genes.gray].1))
        case .accent:
            func mix(_ a: Color, _ b: NSColor, _ amount: CGFloat) -> Color {
                let base = NSColor(a).usingColorSpace(.sRGB) ?? .gray
                return Color(nsColor: base.blended(withFraction: amount, of: b) ?? base)
            }
            return (mix(colors.accent, .white, 0.3), mix(colors.accent, NSColor(colors.background).usingColorSpace(.sRGB) ?? .black, 0.5))
        }
    }
}
