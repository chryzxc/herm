import SwiftUI

/// One member's face anywhere in a room: the bot's avatar, or its initial for a
/// member Herm has no roster bot for. Inside a `DockBotFrameClock` every face
/// shares that clock instead of ticking its own.
struct GroupMemberFace: View {
    let member: GroupRoom.Member
    let bot: BotSummary?
    let imageData: Data?
    var size: CGFloat = 24
    /// nil keeps the avatar's own idle/hover behavior.
    var mood: BotMood?

    var body: some View {
        if let bot {
            BotAvatarView(bot: bot, imageData: imageData, size: size, mood: mood, orbits: false)
        } else {
            Text(member.displayName.prefix(1).uppercased())
                .dockFont(size >= 24 ? .body : .metadata, weight: .semibold)
                .foregroundStyle(Color.dockSecondaryText)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.dockSurface4))
                .opacity(mood == .offline || mood == .queued ? 0.5 : 1)
        }
    }
}

/// Word-shaped tiles that type themselves out in the repliers' colors, so a
/// reply reads as being written rather than loading. Re-seeded every cycle;
/// still under Reduce Motion, unfocused Herm or a static skin.
struct GroupChatterRibbon: View {
    /// Identity colors of the members writing, in order.
    let colors: [Color]
    static let width: CGFloat = 72
    private static let cycle = 2.4
    private static let tileHeight: CGFloat = 4

    var body: some View {
        DockBotFrameReader { frame in
            Canvas { ctx, size in Self.draw(in: &ctx, size: size, colors: colors, frame: frame) }
        }
        .frame(width: Self.width, height: 12)
        .accessibilityHidden(true)
    }

    private static func draw(
        in ctx: inout GraphicsContext, size: CGSize, colors: [Color], frame: DockBotIndicatorFrame
    ) {
        let palette = colors.isEmpty ? [Color.dockSecondaryText] : colors
        let clock = frame.moves ? frame.date.timeIntervalSinceReferenceDate / cycle : 0
        let round = Int(clock.rounded(.down))
        let phase = frame.moves ? clock - Double(round) : 0.6
        let tiles = layout(seed: UInt64(truncatingIfNeeded: round), width: size.width - 6)
        // Tiles type in over the first 80% of the cycle, then the line fades for the next.
        let typed = min(1, phase / 0.8) * Double(tiles.count)
        let fade = phase > 0.85 ? max(0, 1 - (phase - 0.85) / 0.15) : 1
        let y = (size.height - tileHeight) / 2
        var caretX: CGFloat = 0
        for (index, tile) in tiles.enumerated() {
            let reveal = min(1, max(0, typed - Double(index)))
            guard reveal > 0 else { break }
            let width = tile.width * CGFloat(reveal)
            let rect = CGRect(x: tile.x, y: y, width: width, height: tileHeight)
            let color = palette[index % palette.count]
            ctx.fill(Capsule().path(in: rect), with: .color(color.opacity(0.85 * fade)))
            caretX = tile.x + width + 2
        }
        let blink = frame.moves ? (frame.date.timeIntervalSinceReferenceDate * 2).truncatingRemainder(dividingBy: 1) : 0
        guard blink < 0.6 else { return }
        let caret = CGRect(x: caretX, y: 1, width: 1.5, height: size.height - 2)
        ctx.fill(Capsule().path(in: caret), with: .color(palette[0].opacity(0.9)))
    }

    /// Deterministic word widths for one cycle.
    static func layout(seed: UInt64, width: CGFloat) -> [(x: CGFloat, width: CGFloat)] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var x: CGFloat = 0
        var result: [(x: CGFloat, width: CGFloat)] = []
        while true {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let word = CGFloat(5 + Int((state >> 33) % 12))
            guard x + word <= width else { break }
            result.append((x, word))
            x += word + 3
        }
        return result
    }
}

/// The stage's words, kept out of the per-frame closure so a tick never re-lays out text.
private struct GroupReplyCaption: View, Equatable {
    let title: String
    let detail: String?
    let tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .dockFont(.metadata)
                    .foregroundStyle(tint ?? Color.dockMetadataText)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
    }
}

/// Everyone answering in the thread on one line: live faces that think, use
/// tools, doze when stalled, the chatter ribbon while words are being written,
/// and who is up next. One clock drives every face here.
struct GroupReplyStage: View {
    struct Face: Equatable, Identifiable {
        let member: GroupRoom.Member
        let mood: BotMood
        var id: String { member.memberID }
    }

    let replying: [Face]
    let queued: [Face]
    let title: String
    let detail: String?
    /// A stalled turn offers Stop; nil hides it.
    let onStop: (() async -> Void)?
    let bot: (GroupRoom.Member) -> (BotSummary?, Data?)
    let onTapFace: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let faceLimit = 4

    private var lead: [Face] { replying.isEmpty ? queued : replying }
    private var upNext: [Face] { replying.isEmpty ? [] : queued }
    private var writers: [Face] { replying.filter { $0.mood == .thinking || $0.mood == .tool } }

    var body: some View {
        HStack(spacing: 10) {
            if writers.isEmpty {
                content
            } else {
                DockBotFrameClock { _ in content }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 34)
        .animation(
            DockMotion.isEnabled(reduceMotion: reduceMotion) ? .spring(duration: 0.4, bounce: 0.3) : nil,
            value: replying.map(\.id) + ["|"] + queued.map(\.id)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ". "))
    }

    private var content: some View {
        HStack(spacing: 10) {
            faces(lead, size: 28, dim: replying.isEmpty)
            GroupReplyCaption(title: title, detail: detail, tint: nil).equatable()
            if !writers.isEmpty {
                GroupChatterRibbon(
                    colors: writers.prefix(3).map { DockAccentColor.identity(for: $0.member.profile).fill }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
            }
            if !upNext.isEmpty {
                HStack(spacing: 4) {
                    DockIcon(.arrowRight, size: 10, color: Color.dockMetadataText)
                    faces(upNext, size: 20, dim: true)
                }
                .help("Up next: \(upNext.map(\.member.displayName).joined(separator: ", "))")
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            if let onStop {
                DockAsyncButton("Stop") { await onStop() }
                    .buttonStyle(.dockSecondary)
                    .transition(.opacity)
            }
        }
        .dockButtonSize(.compact)
    }

    private func faces(_ faces: [Face], size: CGFloat, dim: Bool) -> some View {
        let shown = faces.prefix(Self.faceLimit)
        let overflow = faces.count - shown.count
        return HStack(spacing: -4) {
            ForEach(Array(shown)) { face in
                let (bot, image) = bot(face.member)
                Button {
                    onTapFace(face.member.memberID)
                } label: {
                    GroupMemberFace(member: face.member, bot: bot, imageData: image, size: size, mood: face.mood)
                        .frame(width: size + 2, height: size + 2)
                        .opacity(dim ? 0.55 : 1)
                }
                .buttonStyle(.dockHover)
                .help(face.member.displayName)
                .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.dockSurface4))
                    .frame(width: size + 2, height: size + 2)
                    .help(faces.dropFirst(shown.count).map(\.member.displayName).joined(separator: ", "))
            }
        }
    }
}

/// A header face: live mood, a hop when its reply lands, a hover card, a click
/// that jumps to its last reply, and a drag that drops `@handle` in the composer.
struct GroupHeaderFace: View {
    let member: GroupRoom.Member
    let bot: BotSummary?
    let imageData: Data?
    let mood: BotMood?
    /// Bumped when this member's reply lands.
    let bounce: Int
    let state: String?
    let lastReply: GroupRoomEvent?
    let onMention: () -> Void
    let onMessage: (() -> Void)?
    let onJump: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingCard = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        let motion = DockMotion.isEnabled(reduceMotion: reduceMotion)
        Button {
            hoverTask?.cancel()
            if let lastReply {
                showingCard = false
                onJump(lastReply.id)
            } else {
                showingCard.toggle()
            }
        } label: {
            GroupMemberFace(member: member, bot: bot, imageData: imageData, size: 24, mood: mood)
                .frame(width: 26, height: 26)
                .keyframeAnimator(initialValue: CGFloat(0), trigger: motion ? bounce : 0) { content, lift in
                    content.offset(y: -lift).scaleEffect(x: 1 + lift * 0.012, y: 1 - lift * 0.008, anchor: .bottom)
                } keyframes: { _ in
                    SpringKeyframe(7, duration: 0.16, spring: .snappy)
                    SpringKeyframe(-1, duration: 0.18, spring: .bouncy)
                    SpringKeyframe(0, duration: 0.3, spring: .smooth)
                }
        }
        .buttonStyle(.dockHover)
        .onHover { inside in
            hoverTask?.cancel()
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(inside ? 450 : 250))
                guard !Task.isCancelled else { return }
                if inside || !cardHovered { showingCard = inside }
            }
        }
        .onDrag { NSItemProvider(object: "@\(member.handle) " as NSString) }
        .dockPopover(isPresented: $showingCard, arrowEdge: .bottom) { card }
        .accessibilityLabel([member.displayName, state].compactMap { $0 }.joined(separator: ", "))
        .help(lastReply == nil ? member.displayName : "\(member.displayName) — click to jump to the last reply")
    }

    @State private var cardHovered = false

    private var card: some View {
        GroupMemberPopover(
            member: member, bot: bot, imageData: imageData, mood: mood, state: state, lastReply: lastReply,
            onDismiss: { showingCard = false }, onMention: onMention, onMessage: onMessage, onJump: onJump
        )
        .onHover { inside in
            cardHovered = inside
            hoverTask?.cancel()
            if !inside {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    if !Task.isCancelled { showingCard = false }
                }
            }
        }
    }
}

struct GroupMemberPopover: View {
    let member: GroupRoom.Member
    let bot: BotSummary?
    let imageData: Data?
    let mood: BotMood?
    let state: String?
    let lastReply: GroupRoomEvent?
    let onDismiss: () -> Void
    let onMention: () -> Void
    let onMessage: (() -> Void)?
    let onJump: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DockSpacing.control) {
            HStack(spacing: 10) {
                GroupMemberFace(member: member, bot: bot, imageData: imageData, size: 40, mood: mood)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.displayName)
                        .dockFont(.navigation, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(2)
                    Text(([("@" + member.handle)] + [bot?.title].compactMap { $0 }).joined(separator: " · "))
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(2)
                }
            }
            if let description = bot?.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                !description.isEmpty
            {
                Text(description)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(4)
                    .help(description)
            }
            let facts = [state, bot?.model, member.isRemote ? "On another Mac" : nil].compactMap { $0 }
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(2)
            }
            if let lastReply {
                VStack(alignment: .leading, spacing: DockSpacing.tight) {
                    HStack(spacing: DockSpacing.tight) {
                        Button("Jump to reply", icon: .arrowBendDownRight) {
                            onDismiss()
                            onJump(lastReply.id)
                        }
                        .buttonStyle(.dockLink)
                        .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        Text(lastReply.createdAt.formatted(.relative(presentation: .named)))
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockMetadataText)
                            .lineLimit(1)
                    }
                    let line = GroupReplyNotifier.firstLine(GenerativeUIIntegration.plainText(lastReply.text))
                    if !line.isEmpty {
                        Text(String(MarkdownInlineParser.parse(line).characters))
                            .dockFont(.body)
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .dockPadding(DockSpacing.control)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dockWell(radius: 8)
            }
            HStack(spacing: DockSpacing.tight) {
                Button("Mention") {
                    onDismiss()
                    onMention()
                }
                .buttonStyle(.dockPrimary)
                if let onMessage {
                    Button("Message") {
                        onDismiss()
                        onMessage()
                    }
                    .buttonStyle(.dockSecondary)
                }
            }
            .dockButtonSize(.compact)
        }
        .dockPadding(DockSpacing.section)
        .frame(width: 284, alignment: .leading)
    }
}

/// Under a finished message: who passed, the round's tally and time, and
/// Continue when Hermes paused the discussion at its round cap.
struct GroupRoundFooter: View {
    let summary: GroupRoundSummary
    let passed: [GroupRoom.Member]
    let bot: (GroupRoom.Member) -> (BotSummary?, Data?)
    let onContinue: (() async -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.dockBorderLight).frame(height: DockLayout.hairline)
            if !passed.isEmpty {
                HStack(spacing: 4) {
                    HStack(spacing: -3) {
                        ForEach(passed, id: \.memberID) { member in
                            let (bot, image) = bot(member)
                            GroupMemberFace(member: member, bot: bot, imageData: image, size: 14, mood: .idle)
                                .opacity(0.55)
                        }
                    }
                    Text("passed")
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                }
                .help("\(passed.map(\.displayName).joined(separator: ", ")) chose not to reply")
            }
            Text(summary.label)
                .dockFont(.metadata)
                .monospacedDigit()
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
                .fixedSize()
            if summary.bounded {
                Text(onContinue == nil ? "Round cap reached" : "Paused at the round cap")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    .dockPill(compact: true)
                    .fixedSize()
            }
            if let onContinue {
                DockAsyncButton("Continue") { await onContinue() }
                    .buttonStyle(.dockSecondary)
                    .help("Let the members take more rounds on this message")
            }
            Rectangle().fill(Color.dockBorderLight).frame(height: DockLayout.hairline)
        }
        .dockButtonSize(.compact)
        .accessibilityElement(children: .combine)
    }
}

/// Tiny faces of members whose last turn had read up to the row above.
struct GroupReadReceiptRow: View {
    let members: [GroupRoom.Member]
    let bot: (GroupRoom.Member) -> (BotSummary?, Data?)

    var body: some View {
        HStack(spacing: -3) {
            Spacer(minLength: 0)
            ForEach(members.prefix(6), id: \.memberID) { member in
                let (bot, image) = bot(member)
                GroupMemberFace(member: member, bot: bot, imageData: image, size: 14, mood: .idle)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(height: 14)
        .help("Seen by \(ListFormatter.localizedString(byJoining: members.map(\.displayName)))")
        .accessibilityLabel("Seen by \(ListFormatter.localizedString(byJoining: members.map(\.displayName)))")
    }
}

/// An empty room: the members wave hello in turn, each handle a chip that starts a mention.
struct GroupWelcome: View {
    let members: [GroupRoom.Member]
    let bot: (GroupRoom.Member) -> (BotSummary?, Data?)
    let onMention: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var waves = 0

    var body: some View {
        let motion = DockMotion.isEnabled(reduceMotion: reduceMotion)
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                ForEach(Array(members.prefix(6).enumerated()), id: \.element.memberID) { index, member in
                    let (bot, image) = bot(member)
                    GroupMemberFace(member: member, bot: bot, imageData: image, size: 36, mood: .happy)
                        .keyframeAnimator(initialValue: Double(0), trigger: motion ? waves : 0) { content, tilt in
                            content.rotationEffect(.degrees(tilt), anchor: .bottom).offset(y: -abs(tilt) * 0.3)
                        } keyframes: { _ in
                            LinearKeyframe(0, duration: 0.12 * Double(index) + 0.01)
                            SpringKeyframe(-12, duration: 0.14, spring: .snappy)
                            SpringKeyframe(10, duration: 0.16, spring: .snappy)
                            SpringKeyframe(-6, duration: 0.14, spring: .snappy)
                            SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                        }
                }
            }
            Text(
                "Mention a member with @handle, or address everyone with @all. With no mention, every member may reply."
            )
            .dockFont(.body)
            .foregroundStyle(Color.dockMetadataText)
            .multilineTextAlignment(.center)
            DockChipFlow(spacing: 6, hugsContent: true) {
                ForEach(members, id: \.memberID) { member in
                    Button("@\(member.handle)") { onMention(member.handle) }
                        .buttonStyle(.dockSecondary)
                }
                if members.count > 1 {
                    Button("@all") { onMention("all") }
                        .buttonStyle(.dockSecondary)
                }
            }
            .dockButtonSize(.compact)
        }
        .frame(maxWidth: .infinity)
        .dockPadding(.top, 40)
        .onAppear { waves += 1 }
    }
}
