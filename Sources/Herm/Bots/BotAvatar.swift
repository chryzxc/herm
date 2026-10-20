import SwiftUI

/// Whether the user is engaged with Herm: the app is active, or one of its
/// non-activating panels is key. Decorative Bot motion pauses otherwise, since
/// every animated frame re-renders and re-lays out the whole hosting window.
/// Spinners and the notch indicator keep running; they carry real status.
@MainActor
final class HermFocus: ObservableObject {
    static let shared = HermFocus()
    @Published private(set) var engaged = true
    private var observers: [NSObjectProtocol] = []

    private init() {
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Key changes hand off through a nil key window; read the settled state next turn.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
            }
        }
        refresh()
    }

    private func refresh() {
        // NSApp is nil in unit tests that render a Bot before any app exists.
        let next = NSApp?.isActive == true || NSApp?.keyWindow != nil
        if engaged != next { engaged = next }
    }
}

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

    static func hue(for profileID: String) -> Double {
        profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.68 : Double(seed(for: profileID) % 360) / 360
    }

    static func palette(for profileID: String) -> [Color] {
        let hue = hue(for: profileID)
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
    var mood: BotMood?
    /// Show the working star orbit; defaults to the Bot's live busy state.
    var orbits: Bool?
    @State private var hovering = false

    var body: some View {
        let herm = Self.showsHermFace(imageData, id: bot.id)
        let busy = orbits ?? bot.isWorkingNow
        let orbit = animated && herm && busy && size >= 16
        let greets = animated && hovering
        ZStack {
            if !herm, let imageData, let image = Self.decoded(imageData) {
                BotLiveImage(image: image, id: bot.id, size: size, busy: busy, animated: animated)
            } else {
                BotFaceMark(id: bot.id, size: size, animated: animated, busy: busy,
                            mood: mood ?? (greets ? .happy : bot.isHidden ? .sleepy : nil))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .background { if orbit { BotSwirlRing(id: bot.id, size: size) } }
        .overlay { if orbit { BotSwirlRing(id: bot.id, size: size, front: true) } }
        .scaleEffect(greets ? 1.08 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: greets)
        .onHover { hovering = $0 }
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

    /// Last verdict per Bot. Animated views ask every frame, so this must stay
    /// a dictionary lookup plus a byte compare, not a pixel match.
    @MainActor private static var hermFaces: [String: (data: Data, match: Bool)] = [:]

    /// Herm faces are recognized by content, not Hermes' `custom` flag, so an
    /// upload replaced by Generate Avatars animates immediately.
    @MainActor static func showsHermFace(_ data: Data?, id: String) -> Bool {
        data.map { isHermFace($0, id: id) } ?? true
    }

    /// "Populate avatars" saved frozen `BotFaceMark` PNGs to Hermes; draw those
    /// live instead. Anything else (uploads, generated art) stays an image.
    @MainActor private static func isHermFace(_ data: Data, id: String) -> Bool {
        if let memo = hermFaces[id], memo.data == data { return memo.match }
        let match = matchesHermFace(data, id: id)
        hermFaces[id] = (data, match)
        return match
    }

    @MainActor static func matchesHermFace(_ data: Data, id: String) -> Bool {
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
    static let reactionDuration: TimeInterval = 1.2

    static func at(_ elapsed: TimeInterval) -> BotWorkingPose {
        let beat = max(0, elapsed).truncatingRemainder(dividingBy: 2.8)
        let wave = pow(sin(min(beat / 1.2, 1) * .pi), 2)
        return BotWorkingPose(lift: wave * 0.4, rotation: sin(beat * .pi * 2 / 1.2) * wave * 4,
                              scaleX: 1 - wave * 0.025, scaleY: 1 + wave * 0.025)
    }

    /// A bounded one-shot: adjacent activity changes always choose a different gesture.
    static func reaction(at elapsed: TimeInterval, variation: Int, from start: BotWorkingPose = .rest) -> BotWorkingPose {
        guard elapsed >= 0, elapsed < reactionDuration else { return .rest }
        let anticipation = pow(sin(min(elapsed / 0.16, 1) * .pi), 2)
        let flight = min(max((elapsed - 0.16) / 0.68, 0), 1)
        let arc = pow(sin(flight * .pi), 2)
        let landing = pow(sin(min(max((elapsed - 0.84) / 0.36, 0), 1) * .pi), 2)
        let squash = anticipation * 0.1 + landing * 0.08
        let sway = sin(flight * .pi * 2) * arc
        var pose: BotWorkingPose
        switch variation % 3 {
        case 0:
            pose = BotWorkingPose(lift: arc, reach: -arc * 0.14, rotation: -14 * arc,
                                  scaleX: 1 - arc * 0.07, scaleY: 1 + arc * 0.07)
        case 1:
            pose = BotWorkingPose(lift: arc * 0.7, reach: sway * 0.15, rotation: sway * 18,
                                  scaleX: 1 + arc * 0.06, scaleY: 1 - arc * 0.06)
        default:
            pose = BotWorkingPose(lift: arc * 0.9, reach: arc * 0.14, rotation: 16 * arc,
                                  scaleX: 1 - sway * 0.08, scaleY: 1 + sway * 0.08)
        }
        pose.scaleX += squash
        pose.scaleY -= squash
        // A new event can interrupt a hop; blend from the pose already on screen.
        let p = min(elapsed / 0.16, 1)
        let blend = p * p * (3 - 2 * p)
        return BotWorkingPose(
            lift: start.lift + (pose.lift - start.lift) * blend,
            reach: start.reach + (pose.reach - start.reach) * blend,
            rotation: start.rotation + (pose.rotation - start.rotation) * blend,
            scaleX: start.scaleX + (pose.scaleX - start.scaleX) * blend,
            scaleY: start.scaleY + (pose.scaleY - start.scaleY) * blend
        )
    }
}

/// Animate the whole avatar so uploaded art and generated faces move alike.
struct BotWorkingAvatarView: View {
    let bot: BotSummary
    let imageData: Data?
    var size: CGFloat = 40
    var activitySignature: [String] = []
    var activityIcon: Ph = .brain
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()
    @State private var reactionAt: Date?
    @State private var reactionStart = BotWorkingPose.rest
    @State private var variation = 0
    @ObservedObject private var focus = HermFocus.shared

    var body: some View {
        let moves = !reduceMotion && DockThemeStyle.current.animates && focus.engaged
        TimelineView(.dockMotion(paused: !moves)) { context in
            let age = reactionAt.map { context.date.timeIntervalSince($0) } ?? BotWorkingPose.reactionDuration
            let reacting = moves && age < BotWorkingPose.reactionDuration
            let pose = moves ? currentPose(at: context.date) : .rest
            ZStack {
                BotAvatarView(bot: bot, imageData: imageData, size: size, animated: moves,
                              mood: reacting ? .surprised : nil, orbits: true)
                    .scaleEffect(x: pose.scaleX, y: pose.scaleY)
                    .rotationEffect(.degrees(pose.rotation))
                    .offset(x: size * pose.reach, y: -size * 0.2 * pose.lift)
                // Echo the real activity glyph as the Bot reaches toward the rows above.
                DockIcon(activityIcon, size: 12, color: .dockAccent)
                    .padding(3)
                    .background(Circle().fill(Color.dockSurface).shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5))
                    .overlay(Circle().stroke(Color.dockBorderStrong, lineWidth: 0.75))
                    .scaleEffect(reacting ? 0.7 + pose.lift * 0.3 : 0.7)
                    .offset(x: size * 0.3 - pose.reach * size, y: -size * 0.3 - pose.lift * size * 0.24)
                    .opacity(reacting && !activitySignature.isEmpty ? Double(pose.lift) : 0)
            }
            .transaction { $0.animation = nil }
        }
        .onChange(of: activitySignature) { _, _ in
            guard moves else { return }
            let now = Date()
            reactionStart = currentPose(at: now)
            variation = (variation + 1) % 3
            reactionAt = now
            startedAt = now.addingTimeInterval(BotWorkingPose.reactionDuration)
        }
    }

    private func currentPose(at date: Date) -> BotWorkingPose {
        if let reactionAt, date.timeIntervalSince(reactionAt) < BotWorkingPose.reactionDuration {
            return .reaction(at: date.timeIntervalSince(reactionAt), variation: variation, from: reactionStart)
        }
        return .at(date.timeIntervalSince(startedAt))
    }
}

/// Idle motion for a Bot mascot, as fractions of the avatar size. Each Bot gets
/// its own phase so a roster never blinks in unison; busy Bots bounce faster
/// and dart their eyes like they are reading.
struct BotFacePose {
    var bob: CGFloat = 0
    var blink: CGFloat = 1
    var look: CGSize = .zero
    /// Clock for the blob's body wobble; 0 is the still pose saved as a PNG.
    var t: Double = 0

    static let rest = BotFacePose()
    static let swirlSegment = 3.2

    static func at(_ t: Double, busy: Bool) -> BotFacePose {
        let blinkPeriod = busy ? 2.7 : 4.3
        let tb = t.truncatingRemainder(dividingBy: blinkPeriod)
        let blink = tb < 0.16 ? max(0.1, CGFloat(abs(tb - 0.08) / 0.08)) : 1
        let bob = CGFloat(sin(t * (busy ? 7 : 1.8))) * (busy ? 0.03 : 0.018)
        let look = busy
            ? CGSize(width: sin(t * 2.4) >= 0 ? 0.028 : -0.028, height: -0.012)
            : CGSize(width: CGFloat(sin(t * 0.6)) * 0.025, height: CGFloat(sin(t * 0.43)) * 0.012)
        return BotFacePose(bob: bob, blink: blink, look: look, t: t)
    }

    /// Each segment picks a fresh move from the Bot's seed, so a Bot never
    /// loops one gesture and two Bots rarely move alike. Some segments rest.
    static func swirl(at t: Double, seed: UInt64) -> (Double, CGFloat) {
        let segment = Int(max(0, t) / swirlSegment)
        let u = max(0, t).truncatingRemainder(dividingBy: swirlSegment) / swirlSegment
        var x = seed &+ UInt64(segment) &* 0x9E3779B97F4A7C15
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x ^= x >> 27
        let dir: Double = x & 1 == 0 ? 1 : -1
        let ease = u * u * (3 - 2 * u)
        let alpha = CGFloat(min(1, sin(u * .pi) * 3))
        switch (x >> 1) % 5 {
        case 0: return (dir * ease * 360, alpha)                  // full spin
        case 1: return (dir * ease * 720, alpha)                  // double spin
        case 2: return (sin(u * .pi * 4) * 35, alpha)             // rock side to side
        case 3: return (dir * sin(u * .pi) * 200, alpha)          // spin out and back
        default: return (0, 0)                                    // breather
        }
    }
}

/// Drives a pose from the clock while the Bot is busy. Idle faces stay still:
/// one 15fps timeline per visible avatar made every list scroll heavy.
/// Paused under Reduce Motion.
private struct BotMotion<Content: View>: View {
    let id: String
    let animated: Bool
    let busy: Bool
    @ViewBuilder let content: (BotFacePose) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var focus = HermFocus.shared

    var body: some View {
        if animated && busy && !reduceMotion && DockThemeStyle.current.animates && focus.engaged {
            let phase = Double(BotAvatarPresentation.seed(for: id) % 1000) / 100
            TimelineView(.dockMotion()) { context in
                content(.at(context.date.timeIntervalSinceReferenceDate + phase, busy: true))
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

/// A star orbiting a working Bot, drawn outside the avatar's clip. Only
/// for Hermes default faces; uploaded art is left alone.
struct BotSwirlRing: View {
    private static let gold = Color(hue: 0.12, saturation: 0.72, brightness: 0.97)
    let id: String
    var size: CGFloat
    /// The orbit passes behind and in front of the Bot: put one ring under the
    /// avatar and a `front` one over it, and each draws only its half.
    var front = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var focus = HermFocus.shared

    var body: some View {
        if !reduceMotion && DockThemeStyle.current.animates {
            let seed = BotAvatarPresentation.seed(for: id)
            let phase = Double(seed % 1000) / 100
            // Paused, the star holds its last spot rather than vanishing.
            TimelineView(.dockMotion(paused: !focus.engaged)) { context in
                let t = context.date.timeIntervalSinceReferenceDate + phase
                let alpha = BotFacePose.swirl(at: t, seed: seed).1
                // A star on a tilted orbit: dips low and grows in front, rides
                // high and shrinks behind.
                Canvas { ctx, box in
                    guard alpha > 0 else { return }
                    ctx.opacity = alpha
                    ctx.translateBy(x: box.width / 2, y: box.height / 2)
                    ctx.rotate(by: .degrees(-12))
                    for i in (0..<4).reversed() {
                        // Trail dots sit where the star was a moment ago, so they bunch up as it slows.
                        let theta = BotFacePose.swirl(at: t - Double(i) * 0.05, seed: seed).0 * .pi / 180
                        let depth = sin(theta)
                        guard (depth > 0) == front else { continue }
                        let d = (i == 0 ? size * 0.26 : size * 0.07) * (0.8 + 0.3 * depth)
                        let rect = CGRect(x: size * 0.62 * cos(theta) - d / 2, y: size * 0.18 * depth - d / 2, width: d, height: d)
                        let shape = i == 0 ? BotOrbitStar().path(in: rect) : Path(ellipseIn: rect)
                        var dot = ctx
                        dot.opacity *= (front ? 1 : 0.7) * (1 - Double(i) * 0.25)
                        dot.fill(shape, with: .color(Self.gold))
                        dot.stroke(shape, with: .color(.black.opacity(0.45)), lineWidth: i == 0 ? 0.75 : 0.5)
                    }
                }
                .frame(width: size * 1.4, height: size * 1.4)
            }
            .allowsHitTesting(false)
        }
    }
}

/// The Bots working together in one row: they take turns, the one whose
/// turn it is bobs with a typing bubble, and a star arcs to the next. A
/// finished lead stays in the row, dimmed and out of the rotation.
struct BotHuddle: View {
    private static let gold = Color(hue: 0.12, saturation: 0.72, brightness: 0.97)
    /// One member's turn, in seconds.
    private static let turn = 0.8
    let lead: BotSummary
    let partners: [BotSummary]
    var avatars: [String: Data] = [:]
    var leadDone = false
    /// Matches `BotWorkingAvatarView`, so the lead keeps its size and spot
    /// whether or not other Bots are working.
    var leadSize: CGFloat = 40
    var size: CGFloat = 26
    /// Set while the lead is the one running the turn: it then reacts to
    /// each new step exactly like the solo loading avatar.
    var leadSignature: [String]? = nil
    var leadIcon: Ph = .brain
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var focus = HermFocus.shared

    private static let gap: CGFloat = 8
    /// Centers the lead in the same 56pt slot `SignalTrace` uses.
    private var inset: CGFloat { (SignalTrace.size - leadSize) / 2 }
    private var height: CGFloat { SignalTrace.size }

    private var centers: [CGFloat] {
        let first: CGFloat = inset + leadSize + Self.gap + size / 2
        let stride: CGFloat = size + Self.gap
        return [inset + leadSize / 2] + partners.indices.map { first + CGFloat($0) * stride }
    }

    var body: some View {
        let moves = !reduceMotion && DockThemeStyle.current.animates && focus.engaged
        // Members that take turns; a finished lead only watches.
        let rotation = leadDone ? Array(1...max(1, partners.count)) : Array(0...partners.count)
        TimelineView(.dockMotion(paused: !moves)) { context in
            let clock = context.date.timeIntervalSinceReferenceDate / Self.turn
            let step = Int(clock)
            let phase = clock - Double(step)
            // A lone lead has nobody to hand the turn to.
            let active = moves && rotation.count > 1 ? rotation[step % rotation.count] : -1
            let next = rotation[(step + 1) % rotation.count]
            frame(active: active, next: next, phase: phase, rotation: rotation, moves: moves)
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func frame(active: Int, next: Int, phase: Double, rotation: [Int], moves: Bool) -> some View {
        HStack(alignment: .bottom, spacing: Self.gap) {
            member(lead, index: 0, size: leadSize, active: active, phase: phase)
            ForEach(Array(partners.enumerated()), id: \.element.id) { index, bot in
                member(bot, index: index + 1, size: size, active: active, phase: phase)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.2, anchor: .bottom).combined(with: .opacity).combined(with: .offset(y: 8)),
                        removal: .scale(scale: 0.1).combined(with: .opacity).combined(with: .offset(y: -10))))
            }
        }
        .padding(.leading, inset)
        .padding(.trailing, inset)
        .padding(.bottom, inset)
        .frame(height: height, alignment: .bottom)
        // Bots pop in as they start and shrink away when they finish.
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: partners.map(\.id))
        .overlay(alignment: .topLeading) {
            Canvas { ctx, _ in trail(ctx, active: active, next: next, phase: phase, rotation: rotation, moves: moves) }
                .frame(height: height)
                .allowsHitTesting(false)
        }
    }

    private func top(_ index: Int) -> CGFloat {
        height - inset - (index == 0 ? leadSize : size) + 3
    }

    private func trail(_ ctx: GraphicsContext, active: Int, next: Int, phase: Double, rotation: [Int], moves: Bool) {
        let xs = centers
        // Faint dotted arcs between neighbours in the rotation.
        for (a, b) in zip(rotation, rotation.dropFirst()) {
            let path = arc(from: CGPoint(x: xs[a], y: top(a)), to: CGPoint(x: xs[b], y: top(b))).path
            ctx.stroke(path, with: .color(Color.dockSecondaryText.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2, 3]))
        }
        guard moves, rotation.count > 1, phase < 0.6 else { return }
        let flight = arc(from: CGPoint(x: xs[active], y: top(active)), to: CGPoint(x: xs[next], y: top(next)))
        let e = 1 - pow(1 - phase / 0.6, 2)
        let p = flight.point(e)
        let d: CGFloat = 9
        let star = BotOrbitStar().path(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
        var dot = ctx
        dot.opacity = phase < 0.08 ? phase / 0.08 : phase > 0.5 ? (0.6 - phase) / 0.1 : 1
        dot.fill(star, with: .color(Self.gold))
        dot.stroke(star, with: .color(.black.opacity(0.45)), lineWidth: 0.7)
    }

    private func member(_ bot: BotSummary, index: Int, size: CGFloat, active: Int, phase: Double) -> some View {
        let talking = index == active
        let dimmed = index == 0 && leadDone
        // A quick hop at the start of the turn.
        let bob = talking && phase < 0.3 ? -3 * sin(.pi * phase / 0.3) : 0
        return Group {
            if index == 0, !leadDone, let leadSignature {
                BotWorkingAvatarView(bot: bot, imageData: avatars[bot.id], size: size,
                                     activitySignature: leadSignature, activityIcon: leadIcon)
            } else {
                BotAvatarView(bot: bot, imageData: avatars[bot.id], size: size, animated: !dimmed,
                              mood: dimmed ? .idle : talking ? .happy : .work, orbits: false)
            }
        }
            .opacity(dimmed ? 0.45 : 1)
            .saturation(dimmed ? 0.5 : 1)
            .offset(y: bob)
            .overlay(alignment: .topTrailing) {
                if talking && phase < 0.75 {
                    Text("•••")
                        .font(.system(size: 6, weight: .heavy))
                        .foregroundStyle(Color.dockPrimaryText.opacity(0.75))
                        .padding(.horizontal, 3).padding(.vertical, 2)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 1, bottomTrailingRadius: 5, topTrailingRadius: 5)
                            .fill(Color.dockSurface)
                            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5))
                        .overlay(UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 1, bottomTrailingRadius: 5, topTrailingRadius: 5)
                            .stroke(Color.dockBorderStrong, lineWidth: 0.75))
                        .offset(x: 9, y: -8)
                        .transition(.opacity)
                }
            }
    }

    private func arc(from a: CGPoint, to b: CGPoint) -> (path: Path, point: (Double) -> CGPoint) {
        let control = CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - 10 - abs(b.x - a.x) * 0.15)
        var path = Path()
        path.move(to: a)
        path.addQuadCurve(to: b, control: control)
        return (path, { t in
            let u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * control.x + t * t * b.x,
                           y: u * u * a.y + 2 * u * t * control.y + t * t * b.y)
        })
    }
}

/// Herm's own blob face: a soft seeded body with eyes, cheeks and a mouth.
/// Everything is derived from the profile ID, so a Bot always gets the same
/// blob. `animated` wobbles the body, blinks and glances while `busy`; leave it off for
/// still renders (`ImageRenderer` uploads).
struct BotFaceMark: View {
    let id: String
    var size: CGFloat = 160
    var animated = false
    var busy = false
    /// Overrides the busy/idle expression.
    var mood: BotMood?

    var body: some View {
        BotMotion(id: id, animated: animated, busy: busy) { face($0) }
            .frame(width: size, height: size)
    }

    /// The still 160px PNG saved to Hermes; `matchesHermFace` recognizes it.
    @MainActor static func png(id: String) -> Data? {
        let renderer = ImageRenderer(content: BotFaceMark(id: id, size: 160))
        renderer.scale = 1
        guard let tiff = renderer.nsImage?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private func face(_ pose: BotFacePose) -> some View {
        let genes = BotBlobGenes(id: id)
        let mood = self.mood ?? (busy ? .work : .idle)
        let hue = BotAvatarPresentation.hue(for: id)
        let size = size
        return Canvas { ctx, _ in
            let s = size
            let ink = GraphicsContext.Shading.color(Color(white: 0.08, opacity: 0.88))
            let eye = s * genes.eyeSize * (mood == .surprised ? 1.25 : 1)
            let gap = s * genes.eyeGap
            let look = mood == .sleepy ? .zero : pose.look
            // Working Bots glow: a slow warm pulse over the body color.
            let glow = mood == .work ? (1 + sin(pose.t * 2.6)) / 2 : 0
            ctx.translateBy(x: 0, y: pose.bob * s * (mood == .sleepy ? 0.5 : 1))

            let body = BotBlobShape(genes: genes, t: pose.t, busy: busy).path(in: CGRect(x: 0, y: 0, width: s, height: s))
            ctx.fill(body, with: .color(Color(hue: (hue - 0.04 * glow + 1).truncatingRemainder(dividingBy: 1),
                                              saturation: 0.58, brightness: 0.82 + 0.07 * glow)))
            ctx.fill(body, with: .linearGradient(Gradient(colors: [.white.opacity(0.22), .clear]),
                                                 startPoint: .zero, endPoint: CGPoint(x: s / 2, y: s / 2)))

            if genes.cheeks || mood == .happy {
                let w = eye * 1.25, h = eye * 0.7, dx = (gap + eye * 1.2 + w) / 2
                let blush = Color(hue: 0.97, saturation: 0.55, brightness: 1).opacity(mood == .happy ? 0.6 : 0.45)
                for side in [-1.0, 1.0] {
                    ctx.fill(Path(ellipseIn: CGRect(x: s / 2 + side * dx - w / 2, y: s * (genes.eyeY + 0.075) - h / 2, width: w, height: h)),
                             with: .color(blush))
                }
            }

            let eyeY = s * genes.eyeY + look.height * s
            for side in [-1.0, 1.0] {
                switch mood {
                case .happy, .sleepy:
                    // "^ ^" when happy, closed "‿ ‿" when dozing.
                    let w = eye * 0.85, h = eye * 0.4
                    var arch = BotBlobArch().path(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                    if mood == .sleepy { arch = arch.applying(CGAffineTransform(scaleX: 1, y: -1)) }
                    let x = s / 2 + side * (gap + w) / 2 + look.width * s
                    ctx.stroke(arch.applying(CGAffineTransform(translationX: x, y: eyeY)), with: ink,
                               style: StrokeStyle(lineWidth: max(1, eye * 0.26), lineCap: .round))
                default:
                    let blink = mood == .surprised ? 1 : pose.blink
                    let h = eye * genes.eyeTall
                    let x = s / 2 + side * (gap + eye) / 2 + look.width * s
                    ctx.fill(Path(ellipseIn: CGRect(x: x - eye / 2, y: eyeY - h * blink / 2, width: eye, height: h * blink)), with: ink)
                    let d = eye * 0.36
                    ctx.fill(Path(ellipseIn: CGRect(x: x - eye / 2 + eye * 0.16, y: eyeY + (eye * 0.14 - h / 2) * blink,
                                                    width: d, height: d * blink)),
                             with: .color(.white.opacity(0.9)))
                }
            }

            if genes.mouth > 0 || mood != .idle, mood != .sleepy {
                let w = s * (mood == .happy ? 0.12 : 0.09), h = s * (mood == .happy ? 0.06 : 0.045)
                let mouth = BotBlobMouth(open: mood == .work || mood == .surprised || (mood == .idle && genes.mouth == 2))
                    .path(in: CGRect(x: s / 2 + look.width * s * 0.5 - w / 2, y: s * (genes.eyeY + 0.1) - h / 2, width: w, height: h))
                ctx.stroke(mouth, with: ink, style: StrokeStyle(lineWidth: max(1, s * 0.028), lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Expressions a Herm face can wear. Idle and work follow the Bot's activity;
/// the rest are set by the view showing the face.
enum BotMood {
    case idle, work, happy, sleepy, surprised
}

/// The seeded traits of a blob. Ranges are tuned so the body always stays
/// inside its frame and the eyes inside the body.
struct BotBlobGenes {
    struct Lobe { var amp: Double; var phase: Double; var speed: Double }

    var lobes: [Lobe]
    var squash: Double
    var eyeSize: CGFloat
    var eyeTall: CGFloat
    var eyeGap: CGFloat
    var eyeY: CGFloat
    var cheeks: Bool
    var mouth: Int

    init(id: String) {
        var state = BotAvatarPresentation.seed(for: id)
        func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        lobes = (2...4).map { k in
            Lobe(amp: (0.025 + next() * 0.035) / Double(k - 1).squareRoot(),
                 phase: next() * 2 * .pi,
                 speed: (next() < 0.5 ? -1 : 1) * (0.5 + next() * 0.7))
        }
        squash = 0.92 + next() * 0.14
        eyeSize = 0.1 + next() * 0.035
        eyeTall = 1 + next() * 0.35
        eyeGap = 0.1 + next() * 0.08
        eyeY = 0.46 + next() * 0.06
        cheeks = next() < 0.6
        mouth = Int(next() * 3)
    }
}

/// The body outline: a circle bent by three seeded lobes that drift over time,
/// smoothed with quad curves through the sample midpoints.
private struct BotBlobShape: Shape {
    let genes: BotBlobGenes
    let t: Double
    let busy: Bool

    func path(in rect: CGRect) -> Path {
        let n = 72
        let rate = busy ? 2.2 : 1
        let breath = 1 + 0.2 * sin(t * (busy ? 2.6 : 1.1))
        let points = (0..<n).map { i -> CGPoint in
            let a = Double(i) / Double(n) * 2 * .pi
            var r = 1.0
            for (k, lobe) in genes.lobes.enumerated() {
                r += lobe.amp * breath * cos(Double(k + 2) * a + lobe.phase + t * lobe.speed * rate)
            }
            let ry = 0.4 * r * (sin(a) > 0 ? 0.94 : 1) / genes.squash
            return CGPoint(x: rect.midX + rect.width * 0.4 * r * genes.squash * cos(a),
                           y: rect.minY + rect.height * (0.54 + ry * sin(a)))
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var path = Path()
        path.move(to: mid(points[n - 1], points[0]))
        for i in 0..<n {
            path.addQuadCurve(to: mid(points[i], points[(i + 1) % n]), control: points[i])
        }
        path.closeSubpath()
        return path
    }
}

/// A small smile, or an "o" while the Bot is working.
private struct BotBlobMouth: Shape {
    let open: Bool

    func path(in r: CGRect) -> Path {
        if open { return Ellipse().path(in: r.insetBy(dx: r.width * 0.2, dy: -r.height * 0.1)) }
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 1.6 - r.minY * 0.6))
        return p
    }
}

/// An upward arch: a happy squint, or flipped, a closed sleeping eye.
private struct BotBlobArch: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.6))
        return p
    }
}

/// A four-point sparkle for the working orbit.
private struct BotOrbitStar: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), w = r.width / 2, k = w * 0.22
        p.move(to: CGPoint(x: c.x, y: c.y - w))
        p.addQuadCurve(to: CGPoint(x: c.x + w, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + w), control: CGPoint(x: c.x + k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x - w, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - w), control: CGPoint(x: c.x - k, y: c.y - k))
        p.closeSubpath()
        return p
    }
}
