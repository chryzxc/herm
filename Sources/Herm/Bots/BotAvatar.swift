import SwiftUI

/// Deterministic visual identity for built-in Bot roles. Stored Hermes assets
/// still take precedence; this only improves the local fallback avatar.
enum BotAvatarPresentation {
    // Profile IDs are Hermes-owned and can be added or renamed. FNV-1a is
    // stable across launches, unlike Swift's randomized Hasher, so every
    // dynamic bot keeps the same fallback identity without a role table.
    static func seed(for profileID: String) -> UInt64 {
        profileID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8.reduce(UInt64(14695981039346656037)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
    }

    static func palette(for profileID: String) -> [Color] {
        let isEmpty = profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hue = isEmpty ? 0.68 : Double(seed(for: profileID) % 360) / 360
        return [
            Color(hue: hue, saturation: 0.58, brightness: 0.82),
            Color(hue: hue, saturation: 0.72, brightness: 0.42)
        ]
    }
}

/// Avatar rendering with Bot Mode's fallback behavior: the profile's stored
/// asset when Hermes has one, otherwise a deterministic role mark derived from
/// the Bot's profile ID so the same Bot always looks the same.
struct BotAvatarView: View {
    let bot: BotSummary
    let imageData: Data?
    var size: CGFloat = 28
    var animated = true

    var body: some View {
        ZStack {
            if let imageData, (bot.hasCustomAvatar || !Self.isHermFace(imageData, id: bot.id)), let image = Self.decoded(imageData) {
                BotLiveImage(image: image, id: bot.id, size: size, busy: bot.isWorkingNow, animated: animated)
            } else {
                BotFaceMark(id: bot.id, size: size, animated: animated, busy: bot.isWorkingNow)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(Color.dockBorderLight.opacity(0.6), lineWidth: 0.5)
        )
        .opacity(bot.isHidden ? 0.45 : 1)
    }

    /// Rows re-render on every scroll frame; decode each avatar once.
    private static let images = NSCache<NSData, NSImage>()

    private static func decoded(_ data: Data) -> NSImage? {
        let key = data as NSData
        if let cached = images.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    private static let hermFaces = NSCache<NSString, NSNumber>()

    /// "Populate avatars" saved frozen `BotFaceMark` PNGs to Hermes; draw those
    /// live instead. Anything else (uploads, generated art) stays an image.
    private static func isHermFace(_ data: Data, id: String) -> Bool {
        let key = (id + ":" + data.base64EncodedString()) as NSString
        if let cached = hermFaces.object(forKey: key) { return cached.boolValue }
        let match = matchesHermFace(data, id: id)
        hermFaces.setObject(NSNumber(value: match), forKey: key)
        return match
    }

    static func matchesHermFace(_ data: Data, id: String) -> Bool {
        guard let stored = NSBitmapImageRep(data: data), stored.pixelsWide == 160, stored.pixelsHigh == 160 else { return false }
        let renderer = ImageRenderer(content: BotFaceMark(id: id, size: 160))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return false }
        let fresh = NSBitmapImageRep(cgImage: cg)
        // Sparse grid with an edge-pixel allowance: antialiasing and color
        // management differ slightly between the saved PNG and a fresh render.
        var misses = 0
        for y in stride(from: 4, to: 160, by: 8) {
            for x in stride(from: 4, to: 160, by: 8) {
                guard let a = stored.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let b = fresh.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                let delta = max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                                abs(a.blueComponent - b.blueComponent), abs(a.alphaComponent - b.alphaComponent))
                if delta > 0.08 { misses += 1 }
            }
        }
        return misses <= 12
    }
}

/// Gentle waiting motion and short reactions to canonical activity updates.
struct BotWorkingPose {
    var lift: CGFloat = 0
    var reach: CGFloat = 0
    var rotation: Double = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1

    static let rest = BotWorkingPose()

    static func at(_ elapsed: TimeInterval) -> BotWorkingPose {
        let beat = max(0, elapsed).truncatingRemainder(dividingBy: 2.8)
        let wave = pow(sin(min(beat / 1.2, 1) * .pi), 2)
        return BotWorkingPose(lift: wave * 0.4, rotation: sin(beat * .pi * 2 / 1.2) * wave * 4,
                              scaleX: 1 - wave * 0.025, scaleY: 1 + wave * 0.025)
    }

    /// A bounded one-shot: adjacent activity changes always choose a different gesture.
    static func reaction(at elapsed: TimeInterval, variation: Int) -> BotWorkingPose {
        guard elapsed >= 0, elapsed < 1.2 else { return .rest }
        let p = elapsed / 1.2
        let arc = pow(sin(p * .pi), 2)
        let sway = sin(p * .pi * 2) * arc
        switch variation % 3 {
        case 0:
            return BotWorkingPose(lift: arc, reach: -arc * 0.22, rotation: -18 * arc,
                                  scaleX: 1 - arc * 0.07, scaleY: 1 + arc * 0.07)
        case 1:
            return BotWorkingPose(lift: arc * 0.6, reach: sway * 0.3, rotation: sway * 25,
                                  scaleX: 1 + arc * 0.06, scaleY: 1 - arc * 0.06)
        default:
            return BotWorkingPose(lift: arc * 0.85, reach: arc * 0.22, rotation: 16 * arc,
                                  scaleX: 1 - sway * 0.08, scaleY: 1 + sway * 0.08)
        }
    }
}

/// Animate the whole avatar so uploaded art and generated faces move alike.
struct BotWorkingAvatarView: View {
    let bot: BotSummary
    let imageData: Data?
    var size: CGFloat = 24
    var activitySignature: [String] = []
    var activityIcon: Ph = .brain
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()
    @State private var reactionAt: Date?
    @State private var variation = 0

    var body: some View {
        let moves = !reduceMotion && DockThemeStyle.current.animates
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moves)) { context in
            let age = reactionAt.map { context.date.timeIntervalSince($0) } ?? 1.2
            let reacting = moves && age < 1.2
            let pose = !moves ? .rest : reacting
                ? BotWorkingPose.reaction(at: age, variation: variation)
                : BotWorkingPose.at(context.date.timeIntervalSince(startedAt))
            ZStack {
                BotAvatarView(bot: bot, imageData: imageData, size: size, animated: false)
                    .scaleEffect(x: pose.scaleX, y: pose.scaleY)
                    .rotationEffect(.degrees(pose.rotation))
                    .offset(x: size * pose.reach, y: -size * 0.18 * pose.lift)
                // Echo the real activity glyph as the Bot reaches toward the rows above.
                DockIcon(activityIcon, size: 10, color: .dockSecondaryText)
                    .padding(2)
                    .background(Circle().fill(Color.dockCanvas))
                    .scaleEffect(reacting ? 0.7 + pose.lift * 0.3 : 0.7)
                    .offset(x: 8 - pose.reach * size, y: -9 - pose.lift * 3)
                    .opacity(reacting ? Double(pose.lift) : 0)
            }
        }
        .onChange(of: activitySignature) { _, _ in
            variation = (variation + 1) % 3
            reactionAt = Date()
            startedAt = Date().addingTimeInterval(1.2)
        }
    }
}

/// Idle motion for a Bot mascot, as fractions of the avatar size. Each Bot gets
/// its own phase so a roster never blinks in unison; busy Bots bounce faster
/// and dart their eyes like they are reading.
struct BotFacePose {
    var bob: CGFloat = 0
    var blink: CGFloat = 1
    var look: CGSize = .zero

    static let rest = BotFacePose()

    static func at(_ t: Double, busy: Bool) -> BotFacePose {
        let blinkPeriod = busy ? 2.7 : 4.3
        let tb = t.truncatingRemainder(dividingBy: blinkPeriod)
        let blink = tb < 0.16 ? max(0.1, CGFloat(abs(tb - 0.08) / 0.08)) : 1
        let bob = CGFloat(sin(t * (busy ? 7 : 1.8))) * (busy ? 0.03 : 0.018)
        let look = busy
            ? CGSize(width: sin(t * 2.4) >= 0 ? 0.028 : -0.028, height: -0.012)
            : CGSize(width: CGFloat(sin(t * 0.6)) * 0.025, height: CGFloat(sin(t * 0.43)) * 0.012)
        return BotFacePose(bob: bob, blink: blink, look: look)
    }
}

/// Drives a pose from the clock. Paused under Reduce Motion.
private struct BotMotion<Content: View>: View {
    let id: String
    let animated: Bool
    let busy: Bool
    @ViewBuilder let content: (BotFacePose) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if animated && !reduceMotion && DockThemeStyle.current.animates {
            let phase = Double(BotAvatarPresentation.seed(for: id) % 1000) / 100
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                content(.at(context.date.timeIntervalSinceReferenceDate + phase, busy: busy))
            }
        } else {
            content(.rest)
        }
    }
}

/// An uploaded avatar can't blink, so it breathes: a slow zoom inside the
/// clip, quicker while the Bot is working.
private struct BotLiveImage: View {
    let image: NSImage
    let id: String
    let size: CGFloat
    let busy: Bool
    let animated: Bool

    var body: some View {
        BotMotion(id: id, animated: animated, busy: busy) { pose in
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .scaleEffect(1.03 + pose.bob)
                .clipped()
        }
    }
}

/// Hermes-style face: a flat colored shape with two eyes. Shape and color are
/// derived from the profile ID so a Bot always gets the same face.
/// `animated` blinks, glances and bobs; leave it off for still renders
/// (`ImageRenderer` uploads).
struct BotFaceMark: View {
    let id: String
    var size: CGFloat = 160
    var animated = false
    var busy = false

    var body: some View {
        BotMotion(id: id, animated: animated, busy: busy) { face($0) }
            .frame(width: size, height: size)
    }

    private func face(_ pose: BotFacePose) -> some View {
        let colors = BotAvatarPresentation.palette(for: id)
        let shape = BotFaceShape(kind: Int(BotAvatarPresentation.seed(for: id) / 360 % 5))
        let pupil = size * 0.045
        return ZStack {
            shape.fill(colors[0]).frame(width: size * 0.82, height: size * 0.82)
            HStack(spacing: size * 0.1) {
                ForEach(0..<2, id: \.self) { _ in
                    Circle().fill(Color(white: 0.96))
                        .frame(width: size * 0.15, height: size * 0.15)
                        .overlay(Circle().fill(colors[1]).frame(width: pupil * 2, height: pupil * 2)
                            .offset(x: pose.look.width * size, y: pose.look.height * size))
                        .scaleEffect(x: 1, y: pose.blink)
                }
            }
            .offset(y: size * 0.04)
        }
        .offset(y: pose.bob * size)
    }
}

private struct BotFaceShape: Shape {
    let kind: Int

    func path(in r: CGRect) -> Path {
        switch kind {
        case 0: return Circle().path(in: r)
        case 1: return RoundedRectangle(cornerRadius: r.width * 0.3, style: .continuous).path(in: r)
        case 2: return Capsule().path(in: r.insetBy(dx: r.width * 0.12, dy: 0))
        case 3: // drop
            var p = Path()
            let c = CGPoint(x: r.midX, y: r.maxY - r.width * 0.36), rad = r.width * 0.36
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: c.x + rad, y: c.y), control: CGPoint(x: c.x + rad, y: c.y - rad * 1.2))
            p.addArc(center: c, radius: rad, startAngle: .zero, endAngle: .degrees(180), clockwise: false)
            p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY), control: CGPoint(x: c.x - rad, y: c.y - rad * 1.2))
            return p
        default: // hexagon
            var p = Path()
            for i in 0..<6 {
                let a = Double(i) * .pi / 3 - .pi / 2
                let pt = CGPoint(x: r.midX + r.width / 2 * cos(a), y: r.midY + r.height / 2 * sin(a))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath()
            return p
        }
    }
}
