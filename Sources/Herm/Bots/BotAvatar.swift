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
        profileID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8.reduce(
            UInt64(14_695_981_039_346_656_037)
        ) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }

    static func hue(for profileID: String) -> Double {
        profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? 0.68 : Double(seed(for: profileID) % 360) / 360
    }

    static func palette(for profileID: String) -> [Color] {
        let color = DockAccentColor.identity(for: profileID).fill
        return [color, color.opacity(0.75)]
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
    /// Overrides the Bot's live busy state; a busy Herm face shows the tool ring.
    var orbits: Bool?
    @Environment(\.dockBotIndicatorFrame) private var indicatorFrame
    @Environment(\.dockBotIndicatorLive) private var indicatorLive
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    @State private var hovering = false

    /// Follows the interface scale like text and icons.
    private var points: CGFloat { DockWorkspaceScale.points(size, scale: workspaceScale) }

    var body: some View {
        let herm = Self.showsHermFace(imageData, id: bot.id)
        let greets = animated && hovering
        let face = mood ?? (greets ? .happy : bot.isHidden ? .sleepy : (orbits ?? bot.isWorkingNow) ? .tool : .idle)
        Group {
            if let indicatorFrame {
                canvas(herm: herm, mood: face, frame: indicatorFrame)
            } else if indicatorLive {
                DockBotFrameClock { canvas(herm: herm, mood: face, frame: $0) }
            } else {
                standalone(herm: herm, mood: face)
            }
        }
        .scaleEffect(greets ? 1.08 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: greets)
        .onHover { hovering = $0 }
        .opacity(bot.isHidden ? 0.45 : 1)
    }

    private func canvas(herm: Bool, mood: BotMood, frame: DockBotIndicatorFrame) -> some View {
        DockBotOrbitCanvas(
            id: bot.id, image: herm ? nil : imageData.flatMap(Self.decoded), size: points, mood: mood,
            pose: frame.face(id: bot.id, busy: mood.moves, animated: animated))
    }

    @ViewBuilder private func standalone(herm: Bool, mood: BotMood) -> some View {
        if !herm, let imageData, let image = Self.decoded(imageData) {
            BotLiveImage(image: image, id: bot.id, size: points, busy: mood.moves, animated: animated)
                .frame(width: points, height: points)
                .clipShape(RoundedRectangle(cornerRadius: points * 0.28, style: .continuous))
        } else {
            BotFaceMark(id: bot.id, size: points, animated: animated, mood: mood)
        }
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

    /// Recognize matte and older glossy saves before falling back to the legacy blob.
    @MainActor static func matchesHermFace(_ data: Data, id: String) -> Bool {
        guard let stored = NSBitmapImageRep(data: data), stored.pixelsWide == 160, stored.pixelsHigh == 160 else {
            return false
        }
        if [DockThemeID?.none, .glass].contains(where: { theme in
            BotFaceMark.still(id: id, theme: theme).cgImage.map { matches(stored, NSBitmapImageRep(cgImage: $0)) }
                ?? false
        }) {
            return true
        }
        if let previous = BotFaceMark.still(id: id, theme: .glass, originalColors: true).cgImage,
            matches(stored, NSBitmapImageRep(cgImage: previous))
        {
            return true
        }
        return BotFaceMark.still(id: id, legacy: true).cgImage.map { matches(stored, NSBitmapImageRep(cgImage: $0)) }
            ?? false
    }

    private static func matches(_ stored: NSBitmapImageRep, _ fresh: NSBitmapImageRep) -> Bool {
        // Sparse grid with an edge-pixel allowance: antialiasing and color
        // management differ slightly between the saved PNG and a fresh render.
        var misses = 0
        for y in stride(from: 4, to: 160, by: 8) {
            for x in stride(from: 4, to: 160, by: 8) {
                guard let a = stored.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    let b = fresh.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { return false }
                let delta = max(
                    abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
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
        return BotWorkingPose(
            lift: wave * 0.4, rotation: sin(beat * .pi * 2 / 1.2) * wave * 4,
            scaleX: 1 - wave * 0.025, scaleY: 1 + wave * 0.025)
    }

    /// A bounded one-shot: adjacent activity changes always choose a different gesture.
    static func reaction(at elapsed: TimeInterval, variation: Int, from start: BotWorkingPose = .rest) -> BotWorkingPose
    {
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
            pose = BotWorkingPose(
                lift: arc, reach: -arc * 0.14, rotation: -14 * arc,
                scaleX: 1 - arc * 0.07, scaleY: 1 + arc * 0.07)
        case 1:
            pose = BotWorkingPose(
                lift: arc * 0.7, reach: sway * 0.15, rotation: sway * 18,
                scaleX: 1 + arc * 0.06, scaleY: 1 - arc * 0.06)
        default:
            pose = BotWorkingPose(
                lift: arc * 0.9, reach: arc * 0.14, rotation: 16 * arc,
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
        DockBotFrameClock { frame in
            let age = reactionAt.map { frame.date.timeIntervalSince($0) } ?? BotWorkingPose.reactionDuration
            let reacting = frame.moves && age >= 0 && age < BotWorkingPose.reactionDuration
            let pose = frame.moves ? currentPose(at: frame.date) : .rest
            ZStack {
                BotAvatarView(
                    bot: bot, imageData: imageData, size: size, animated: frame.moves,
                    orbits: true
                )
                .scaleEffect(x: pose.scaleX, y: pose.scaleY)
                .rotationEffect(.degrees(pose.rotation))
                .offset(x: size * pose.reach, y: -size * 0.2 * pose.lift)
                // Echo the real activity glyph as the Bot reaches toward the rows above.
                DockIcon(activityIcon, size: 12, color: .dockAccent)
                    .dockPadding(3)
                    .background(
                        Circle().fill(Color.dockSurface).shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    )
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
        .onChange(of: moves) { _, engaged in
            // Do not replay a one-shot when decoration resumes.
            if !engaged {
                reactionAt = nil
                reactionStart = .rest
            }
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

    static func at(_ t: Double, busy: Bool) -> BotFacePose {
        let blinkPeriod = busy ? 2.7 : 4.3
        let tb = t.truncatingRemainder(dividingBy: blinkPeriod)
        let blink = tb < 0.16 ? max(0.1, CGFloat(abs(tb - 0.08) / 0.08)) : 1
        let bob = CGFloat(sin(t * (busy ? 7 : 1.8))) * (busy ? 0.03 : 0.018)
        let look =
            busy
            ? CGSize(width: sin(t * 2.4) >= 0 ? 0.028 : -0.028, height: -0.012)
            : CGSize(width: CGFloat(sin(t * 0.6)) * 0.025, height: CGFloat(sin(t * 0.43)) * 0.012)
        return BotFacePose(bob: bob, blink: blink, look: look, t: t)
    }
}

/// Drives a pose from the clock while the Bot is busy. Idle faces stay still:
/// one 15fps timeline per visible avatar made every list scroll heavy. Busy
/// faces take every other tick of the shared clock. Paused under Reduce Motion.
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
            TimelineView(.dockMotion(rate: 15)) { context in
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

/// The Bots working together in one row: they take turns, the one whose
/// turn it is bobs with a typing bubble, and a star arcs to the next. A
/// finished lead stays in the row, dimmed and out of the rotation.
struct BotHuddle: View {
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

    /// What each Bot is doing, keyed by Bot id, shown in its thought bubble.
    var lines: [String: String] = [:]

    private static let gap: CGFloat = 8
    /// Room above the avatars for the thought bubble.
    private static let headroom: CGFloat = 18
    /// Centers the lead in the same 56pt slot `SignalTrace` uses.
    private var inset: CGFloat { (SignalTrace.size - leadSize) / 2 }
    private var height: CGFloat { SignalTrace.size }
    private var headroom: CGFloat { partners.isEmpty ? 0 : Self.headroom }

    /// Space left of the lead, so text stacked under the huddle lines up with it.
    static let leadInset: CGFloat = (SignalTrace.size - 40) / 2

    var body: some View {
        let moves = !reduceMotion && DockThemeStyle.current.animates && focus.engaged
        let layout = DockBotHuddleLayout(
            partnerCount: partners.count, leadDone: leadDone, leadSize: leadSize, partnerSize: size)
        let members = members(layout: layout)
        DockBotFrameClock { frame in
            let turn = layout.turn(at: frame)
            members
                .environment(\.dockBotIndicatorFrame, frame)
                .overlay(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        sparks(ctx, active: turn.active, next: turn.next, phase: turn.phase, centers: layout.centers)
                    }
                    .frame(height: height + headroom)
                    .allowsHitTesting(false)
                }
        }
        .animation(moves ? .spring(response: 0.45, dampingFraction: 0.7) : nil, value: partners.map(\.id))
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func members(layout: DockBotHuddleLayout) -> some View {
        HStack(alignment: .bottom, spacing: Self.gap) {
            DockBotFrameReader { frame in
                let turn = layout.turn(at: frame)
                member(lead, index: 0, size: leadSize, active: turn.active, phase: turn.phase)
            }
            ForEach(Array(partners.enumerated()), id: \.element.id) { index, bot in
                DockBotFrameReader { frame in
                    let turn = layout.turn(at: frame)
                    member(bot, index: index + 1, size: size, active: turn.active, phase: turn.phase)
                }
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.2, anchor: .bottom).combined(with: .opacity).combined(
                            with: .offset(y: 8)),
                        removal: .scale(scale: 0.1).combined(with: .opacity).combined(with: .offset(y: -10))))
            }
        }
        .dockPadding(.leading, inset)
        .dockPadding(.trailing, inset)
        .dockPadding(.bottom, inset)
        .frame(height: height, alignment: .bottom)
        .dockPadding(.top, headroom)
    }

    /// Top of a member's avatar, in the huddle's coordinates.
    private func top(_ index: Int) -> CGFloat {
        headroom + height - inset - (index == 0 ? leadSize : size) + 3
    }

    /// The bubble bursts into three sparks that drift to the next speaker.
    private func sparks(_ ctx: GraphicsContext, active: Int, next: Int, phase: Double, centers xs: [CGFloat]) {
        guard active >= 0, active != next, phase > ThoughtBubbleTiming.burst else { return }
        let t = (phase - ThoughtBubbleTiming.burst) / (1 - ThoughtBubbleTiming.burst)
        let accent = DockAccentColor.identity(for: (next == 0 ? lead : partners[next - 1]).id).fill
        for k in 0..<3 {
            let e = 1 - pow(1 - max(0, min(1, t * 1.25 - Double(k) * 0.12)), 2)
            let flight = arc(
                from: CGPoint(x: xs[active], y: top(active)), to: CGPoint(x: xs[next], y: top(next)),
                lift: 6 + CGFloat(k) * 5)
            let p = flight.point(e)
            let d: CGFloat = 4.5 - CGFloat(k) * 0.8
            var dot = ctx
            dot.opacity = e < 1 ? 1 - e * 0.4 : 0
            dot.fill(
                Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                with: .color(accent))
        }
    }

    private func member(_ bot: BotSummary, index: Int, size: CGFloat, active: Int, phase: Double) -> some View {
        let talking = index == active
        let dimmed = index == 0 && leadDone
        // A quick hop as the bubble appears.
        let bob = talking && phase < 0.3 ? -3 * sin(.pi * phase / 0.3) : 0
        let scale = talking ? ThoughtBubbleTiming.scale(phase) : 0
        return Group {
            if index == 0, !leadDone, let leadSignature {
                BotWorkingAvatarView(
                    bot: bot, imageData: avatars[bot.id], size: size,
                    activitySignature: leadSignature, activityIcon: leadIcon)
            } else {
                BotAvatarView(
                    bot: bot, imageData: avatars[bot.id], size: size, animated: !dimmed,
                    mood: dimmed ? .idle : talking ? .replying : .tool, orbits: false)
            }
        }
        .opacity(dimmed ? 0.45 : 1)
        .saturation(dimmed ? 0.5 : 1)
        .offset(y: bob)
        .overlay(alignment: .top) {
            if scale > 0 {
                // Every bubble floats at the same height, above the lead's head;
                // a shorter Bot gets a longer tail.
                ThoughtBubble(
                    text: ThoughtBubbleTiming.typed(lines[bot.id].map(ThoughtBubbleTiming.short), phase: phase),
                    tail: (index == 0 ? 0 : leadSize - size) + 4
                )
                .fixedSize()
                .scaleEffect(scale, anchor: .bottomLeading)
                .opacity(min(1, scale * 1.5))
                .frame(width: 0, height: 0, alignment: .bottomLeading)
                .offset(x: -9, y: -2)
                .frame(width: 0, height: 0)
            }
        }
        .zIndex(talking ? 1 : 0)
    }

    private func arc(from a: CGPoint, to b: CGPoint, lift: CGFloat = 10) -> (path: Path, point: (Double) -> CGPoint) {
        let control = CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - lift - abs(b.x - a.x) * 0.15)
        var path = Path()
        path.move(to: a)
        path.addQuadCurve(to: b, control: control)
        return (
            path,
            { t in
                let u = 1 - t
                return CGPoint(
                    x: u * u * a.x + 2 * u * t * control.x + t * t * b.x,
                    y: u * u * a.y + 2 * u * t * control.y + t * t * b.y)
            }
        )
    }
}

/// A Bot's thought: a small bubble trailing two dots down to its head.
private struct ThoughtBubble: View {
    let text: String
    let tail: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text)
                .dockFont(.compactStatus, weight: .medium)
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
                .dockPadding(.horizontal, 7).dockPadding(.vertical, 3)
                .background(Capsule().fill(Color.dockSurface).shadow(color: .black.opacity(0.18), radius: 2, y: 1))
                .overlay(Capsule().stroke(Color.dockBorderStrong, lineWidth: 0.75))
            // The tail's dots shrink toward the Bot it belongs to.
            ForEach([3.5, 2.2].prefix(tail > 10 ? 2 : 1), id: \.self) { d in
                Circle().fill(Color.dockSurface)
                    .overlay(Circle().stroke(Color.dockBorderStrong, lineWidth: 0.6))
                    .frame(width: d, height: d)
                    .dockPadding(.leading, d == 3.5 ? 5 : 8)
                    .dockPadding(.top, tail > 10 ? 2.5 : 1)
            }
        }
        .frame(height: 16 + tail, alignment: .top)
    }
}

/// Timing of one 2.6s huddle turn: the bubble pops in, types, holds, then
/// bursts into sparks bound for the next speaker.
enum ThoughtBubbleTiming {
    static let burst = 0.86

    static func scale(_ phase: Double) -> Double {
        if phase < 0.06 || phase > 0.9 { return 0 }
        if phase > 0.82 { return (0.9 - phase) / 0.08 }
        let t = min(1, (phase - 0.06) / 0.12)
        // Ease out with a small overshoot, like a spring.
        return 1 + 2.7 * pow(t - 1, 3) + 1.7 * pow(t - 1, 2)
    }

    /// `text` typed out over the turn; a Bot with no known step shows
    /// "thinking" dots instead.
    static func typed(_ text: String?, phase: Double) -> String {
        guard let text, !text.isEmpty else {
            return String(repeating: "•", count: 1 + Int(phase * 9) % 3).padding(
                toLength: 3, withPad: " ", startingAt: 0)
        }
        let shown = Int(max(0, phase - 0.1) * DockBotHuddleLayout.turnLength / 0.03)
        return String(text.prefix(max(1, shown)))
    }

    /// The step's headline: "Running a command · git status" thinks "Running a command".
    static func short(_ step: String) -> String {
        let head = step.components(separatedBy: " · ").first ?? step
        return head.count > 30 ? head.prefix(29) + "…" : head
    }
}

/// A Herm face: a seeded body, eyes and expression for every state Hermes
/// reports (see `HermFace.swift`). `animated` runs the clock while the state
/// moves; leave it off for still renders.
struct BotFaceMark: View {
    let id: String
    var size: CGFloat = 160
    var animated = false
    var busy = false
    /// Overrides the busy/idle state.
    var mood: BotMood?
    /// Live faces follow the app skin; previews pass the skin they show.
    var theme: DockThemeID?
    @ObservedObject private var themeStore = DockThemeStore.shared

    var body: some View {
        let theme = theme ?? themeStore.selectedThemeID
        let mood = self.mood ?? (busy ? .tool : .idle)
        BotMotion(id: id, animated: animated, busy: mood.moves) { pose in
            Canvas { ctx, _ in
                ctx.translateBy(x: size * 0.2, y: size * 0.2)
                Self.draw(in: &ctx, id: id, size: size, mood: mood, pose: pose, theme: theme)
            }
            .frame(width: size * 1.4, height: size * 1.4)
        }
        .frame(width: size, height: size)
    }

    /// The still, skin-neutral 160px PNG saved to Hermes; `matchesHermFace` recognizes it.
    @MainActor static func png(id: String) -> Data? {
        guard let tiff = still(id: id).nsImage?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    @MainActor static func still(
        id: String, legacy: Bool = false, theme: DockThemeID? = nil, originalColors: Bool = false
    ) -> ImageRenderer<some View> {
        let renderer = ImageRenderer(
            content: Canvas { ctx, _ in
                if legacy {
                    drawLegacyBlob(in: &ctx, id: id, size: 160)
                } else {
                    draw(
                        in: &ctx, id: id, size: 160, mood: .idle, pose: .rest, theme: theme,
                        originalColors: originalColors)
                }
            }.frame(width: 160, height: 160))
        renderer.scale = 1
        return renderer
    }
}

/// The seeded traits of the legacy blob, kept to recognize its saved PNGs.
struct BotBlobGenes {
    struct Lobe {
        var amp: Double
        var phase: Double
        var speed: Double
    }

    var lobes: [Lobe]
    var squash: Double
    var eyeSize: CGFloat
    var eyeTall: CGFloat
    var eyeGap: CGFloat
    var eyeY: CGFloat
    var cheeks: Bool
    var mouth: Int

    init(id: String) {
        var random = BotSeededRandom(id: id)
        func next() -> Double { random.next() }
        lobes = (2...4).map { k in
            Lobe(
                amp: (0.025 + next() * 0.035) / Double(k - 1).squareRoot(),
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

/// The legacy body outline: a circle bent by three seeded lobes, smoothed
/// with quad curves through the sample midpoints.
struct BotBlobShape: Shape {
    let genes: BotBlobGenes

    func path(in rect: CGRect) -> Path {
        let n = 72
        let points = (0..<n).map { i -> CGPoint in
            let a = Double(i) / Double(n) * 2 * .pi
            var r = 1.0
            for (k, lobe) in genes.lobes.enumerated() {
                r += lobe.amp * cos(Double(k + 2) * a + lobe.phase)
            }
            let ry = 0.4 * r * (sin(a) > 0 ? 0.94 : 1) / genes.squash
            return CGPoint(
                x: rect.midX + rect.width * 0.4 * r * genes.squash * cos(a),
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
struct BotBlobMouth: Shape {
    let open: Bool

    func path(in r: CGRect) -> Path {
        if open { return Ellipse().path(in: r.insetBy(dx: r.width * 0.2, dy: -r.height * 0.1)) }
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 1.6 - r.minY * 0.6))
        return p
    }
}

/// A four-point sparkle on a Herm face.
struct BotOrbitStar: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let w = r.width / 2
        let k = w * 0.22
        p.move(to: CGPoint(x: c.x, y: c.y - w))
        p.addQuadCurve(to: CGPoint(x: c.x + w, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + w), control: CGPoint(x: c.x + k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x - w, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - w), control: CGPoint(x: c.x - k, y: c.y - k))
        p.closeSubpath()
        return p
    }
}
