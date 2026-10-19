import Foundation
import AppKit
import SwiftUI

/// Reusable conversation-only presentation primitives. They render DockModel
/// state but deliberately do not own transport, session, or input state.
struct ThinkingDots: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if reduceMotion {
      dots(at: 0)
    } else {
      // This indicator is informative, not motion-critical. Eight updates a
      // second reads smoothly enough while avoiding a display-rate wakeup.
      TimelineView(.periodic(from: .now, by: 1.0 / 8.0)) { context in
        dots(at: context.date.timeIntervalSinceReferenceDate)
      }
    }
  }

  private func dots(at time: TimeInterval) -> some View {
    HStack(spacing: 4) {
      ForEach(0..<3) { i in
        let p = (time + Double(i) * 0.2).truncatingRemainder(dividingBy: 1.4) / 1.4
        let s = 0.6 + 0.4 * max(0, sin(p * .pi * 2))
        Circle().fill(Color.dockAccent).frame(width: 6, height: 6).scaleEffect(s).opacity(s)
      }
    }
  }
}

struct AgentAvatar: View {
  let identity: String
  let statusColor: Color

  var body: some View {
    ZStack {
      Circle()
        .fill(statusColor.opacity(0.12))
        .overlay {
          DockIcon(.user)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(statusColor)
        }
        .overlay {
          Circle().stroke(Color.dockBorder, lineWidth: 0.5)
        }
      Circle()
        .fill(statusColor)
        .frame(width: 6, height: 6)
        .overlay(Circle().stroke(Color.dockCanvas, lineWidth: 1))
        .offset(x: 8, y: -8)
    }
    .accessibilityLabel("Agent avatar")
  }
}

struct MessageBubbleShape: Shape {
  let isUser: Bool

  func path(in rect: CGRect) -> Path {
    let b: CGFloat = 18
    let s: CGFloat = 6
    let br = isUser ? s : b
    let bl = isUser ? b : s
    return Path { p in
      p.move(to: CGPoint(x: rect.minX + b, y: rect.minY))
      p.addLine(to: CGPoint(x: rect.maxX - b, y: rect.minY))
      p.addArc(
        center: CGPoint(x: rect.maxX - b, y: rect.minY + b), radius: b, startAngle: .degrees(-90),
        endAngle: .degrees(0), clockwise: false)
      p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
      p.addArc(
        center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0),
        endAngle: .degrees(90), clockwise: false)
      p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
      p.addArc(
        center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90),
        endAngle: .degrees(180), clockwise: false)
      p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + b))
      p.addArc(
        center: CGPoint(x: rect.minX + b, y: rect.minY + b), radius: b, startAngle: .degrees(180),
        endAngle: .degrees(270), clockwise: false)
      p.closeSubpath()
    }
  }
}

/// Long streaming messages use AppKit's text system to keep incremental
/// rendering responsive. Completed messages use one native text view below so
/// a selection can span every Markdown block.
enum CompletedMarkdownRendererPolicy {
  static let nativeThresholdBytes = 8_192

  static func usesNativeRenderer(for markdown: String) -> Bool {
    markdown.utf8.count >= nativeThresholdBytes
  }
}

@MainActor
struct NativeMarkdownMessageView: NSViewRepresentable, Equatable {
  let markdown: String
  let themeRevision: Int
  /// Hug the widest laid-out line instead of filling the proposed width, so a
  /// short message in a bubble doesn't stretch to the bubble's max width.
  var hugsContent = false

  init(
    markdown: String,
    themeRevision: Int = DockThemeRuntime.revision,
    hugsContent: Bool = false
  ) {
    self.markdown = markdown
    self.themeRevision = themeRevision
    self.hugsContent = hugsContent
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.markdown == rhs.markdown && lhs.themeRevision == rhs.themeRevision
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NativeMarkdownTextSectionView {
    let view = NativeMarkdownTextSectionView()
    view.update(markdown: markdown, kind: .prose)
    return view
  }

  func updateNSView(_ nsView: NativeMarkdownTextSectionView, context: Context) {
    nsView.update(markdown: markdown, kind: .prose)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: NativeMarkdownTextSectionView,
    context: Context
  ) -> CGSize? {
    let width: CGFloat
    if let proposed = proposal.width, proposed.isFinite, proposed > 1 {
      width = proposed
    } else if nsView.bounds.width > 1 {
      width = nsView.bounds.width
    } else {
      width = NativeMarkdownDocumentSizing.fallbackWidth
    }
    guard hugsContent else { return CGSize(width: width, height: nsView.measuredHeight(forWidth: width)) }
    // Measure height at the hugged width: SwiftUI lays the view out at the width
    // returned here, so a taller wrap at that width must be counted or it spills out of the bubble.
    let hugged = min(width, nsView.usedWidth(forWidth: width))
    return CGSize(width: hugged, height: nsView.measuredHeight(forWidth: hugged))
  }

  @MainActor
  final class Coordinator {
    static func attributedString(for markdown: String) -> NSAttributedString {
      NativeMarkdownAttributedTextBuilder.document(markdown, palette: NativeMarkdownPalette()).string
    }

    static func attributedString(for chunks: [StreamingPresentationChunk]) -> NSAttributedString {
      let result = NSMutableAttributedString()
      for (index, chunk) in chunks.enumerated() {
        if index > 0 { result.append(NSAttributedString(string: "\n")) }
        result.append(attributedString(for: source(for: chunk)))
      }
      return result
    }

    private static func source(for chunk: StreamingPresentationChunk) -> String {
      switch chunk.context {
      case .markdown, .paragraph, .list, .quote, .table, .inline:
        return chunk.text
      case .fencedCode(let marker, let length, let language):
        let fence = String(repeating: String(marker), count: length)
        return "\(fence)\(language.map { $0.isEmpty ? "" : "\($0)" } ?? "")\n\(chunk.text)\n\(fence)"
      }
    }


  }
}

final class NativeMarkdownTextView: NSTextView {
  init() {
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    let layout = NSLayoutManager()
    let storage = NSTextStorage()
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    super.init(frame: .zero, textContainer: container)
    isEditable = false
    isSelectable = true
    isRichText = true
    drawsBackground = false
    isVerticallyResizable = true
    isHorizontallyResizable = false
    maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textContainerInset = NSSize(width: 0, height: 0)
    textContainer?.widthTracksTextView = true
    textContainer?.lineFragmentPadding = 0
    allowsUndo = false
    isAutomaticSpellingCorrectionEnabled = false
    isAutomaticTextCompletionEnabled = false
    isAutomaticLinkDetectionEnabled = false
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    NotificationCenter.default.addObserver(self, selector: #selector(websiteIconLoaded), name: MarkdownWebsiteIcon.didLoad, object: nil)
  }

  @objc private func websiteIconLoaded() {
    guard let textStorage else { return }
    layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
    needsDisplay = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func clicked(onLink link: Any, at charIndex: Int) {
    guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return }
    MainActor.assumeIsolated { InAppBrowser.open(url) }
  }

  override var intrinsicContentSize: NSSize {
    guard let textContainer, let layoutManager else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
    layoutManager.ensureLayout(for: textContainer)
    let used = layoutManager.usedRect(for: textContainer)
    return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
  }

  override func setFrameSize(_ newSize: NSSize) {
    let widthChanged = abs(frame.width - newSize.width) > 0.5
    super.setFrameSize(newSize)
    if widthChanged {
      // TextKit must recompute wrapping after a transcript resize, but an
      // ordinary scroll/layout pass must not continuously invalidate the
      // intrinsic height.
      invalidateIntrinsicContentSize()
    }
  }
}

/// Content bounds from the restored SwiftUI transcript. This has one purpose:
/// determine whether the reader is at the real tail so streaming never steals
/// their position while they browse older messages.
struct ConversationContentBounds: Equatable {
    var topMinY: CGFloat
    var bottomMaxY: CGFloat
}

struct ConversationContentBoundsPreferenceKey: PreferenceKey {
    static let defaultValue = ConversationContentBounds(topMinY: 0, bottomMaxY: 0)

    static func reduce(value: inout ConversationContentBounds, nextValue: () -> ConversationContentBounds) {
        value = nextValue()
    }
}

/// Viewport geometry in top-origin document coordinates, matching the SwiftUI
/// "conversation-document" coordinate space used by row frames.
struct ConversationScrollGeometry: Equatable {
    var visibleTop: CGFloat
    var visibleHeight: CGFloat
    var documentHeight: CGFloat

    var distanceToBottom: CGFloat { max(0, documentHeight - visibleTop - visibleHeight) }
}

/// Direct, non-publishing access to the transcript's native clip view. Used
/// to hold the reader's position while history pages mount above them, in
/// the same layout pass, instead of a SwiftUI state round trip (a visible
/// jump followed by a correction).
@MainActor
final class ConversationScrollController {
    weak var clipView: NSClipView?
    private(set) var isAdjustingScroll = false

    var geometry: ConversationScrollGeometry? {
        guard let clipView, let documentView = clipView.documentView else { return nil }
        let visible = clipView.documentVisibleRect
        let documentHeight = documentView.bounds.height
        let top = documentView.isFlipped ? visible.minY : documentHeight - visible.maxY
        return ConversationScrollGeometry(
            visibleTop: top,
            visibleHeight: visible.height,
            documentHeight: documentHeight
        )
    }

    /// Moves the viewport by a document-space delta relative to wherever it
    /// is now, so in-flight momentum keeps its progress. If the hosting
    /// document has not adopted its new height yet, the clamped remainder is
    /// applied once on the next run-loop turn.
    func shiftVisibleTop(by delta: CGFloat) {
        let remaining = delta - applyShift(delta)
        guard abs(remaining) > 0.5 else { return }
        DispatchQueue.main.async { [weak self] in
            _ = self?.applyShift(remaining)
        }
    }

    private func applyShift(_ delta: CGFloat) -> CGFloat {
        guard abs(delta) > 0.5, let clipView, let documentView = clipView.documentView else { return delta }
        isAdjustingScroll = true
        defer { isAdjustingScroll = false }
        let sign: CGFloat = documentView.isFlipped ? 1 : -1
        let current = clipView.bounds.origin.y
        let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
        let target = min(max(0, current + sign * delta), maxY)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: target))
        (clipView.superview as? NSScrollView)?.reflectScrolledClipView(clipView)
        return (target - current) * sign
    }
}

/// Observes the native clip view without publishing its live bounds through
/// SwiftUI. Trackpad scrolling can produce dozens of bounds changes per frame;
/// `onScroll` receives them synchronously for cheap edge checks, and only the
/// settled transition is reported through `onScrollSettled`.
struct ConversationScrollEventObserver: NSViewRepresentable {
    var controller: ConversationScrollController
    var onScroll: (ConversationScrollGeometry, _ deltaTop: CGFloat) -> Void
    var onScrollSettled: (ConversationScrollGeometry) -> Void
    var onScrollAwayFromBottom: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onScroll: onScroll, onScrollSettled: onScrollSettled,
                    onScrollAwayFromBottom: onScrollAwayFromBottom)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onScroll = onScroll
        coordinator.onScrollSettled = onScrollSettled
        coordinator.onScrollAwayFromBottom = onScrollAwayFromBottom
        guard coordinator.clipView == nil else { return }
        DispatchQueue.main.async {
            coordinator.attachIfNeeded(from: nsView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        static let settleDelayNanoseconds: UInt64 = 80_000_000

        let controller: ConversationScrollController
        var onScroll: (ConversationScrollGeometry, CGFloat) -> Void
        var onScrollSettled: (ConversationScrollGeometry) -> Void
        var onScrollAwayFromBottom: () -> Void
        weak var clipView: NSClipView?
        nonisolated(unsafe) private var observer: NSObjectProtocol?
        private var lastBoundsChange: UInt64 = 0
        private var lastVisibleTop: CGFloat?
        private var settleTask: Task<Void, Never>?

        init(
            controller: ConversationScrollController,
            onScroll: @escaping (ConversationScrollGeometry, CGFloat) -> Void,
            onScrollSettled: @escaping (ConversationScrollGeometry) -> Void,
            onScrollAwayFromBottom: @escaping () -> Void = {}
        ) {
            self.controller = controller
            self.onScroll = onScroll
            self.onScrollSettled = onScrollSettled
            self.onScrollAwayFromBottom = onScrollAwayFromBottom
        }

        func attachIfNeeded(from view: NSView) {
            guard clipView == nil else { return }
            var candidate: NSView? = view
            while let current = candidate {
                if let scrollView = current as? NSScrollView {
                    attach(to: scrollView.contentView)
                    return
                }
                candidate = current.superview
            }
        }

        func detach() {
            settleTask?.cancel()
            settleTask = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            clipView = nil
        }

        private func attach(to clipView: NSClipView) {
            self.clipView = clipView
            controller.clipView = clipView
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.boundsDidChange() }
            }
            clipView.postsBoundsChangedNotifications = true
            reportSettled()
        }

        private func boundsDidChange() {
            lastBoundsChange = DispatchTime.now().uptimeNanoseconds
            if let geometry = controller.geometry {
                let delta = geometry.visibleTop - (lastVisibleTop ?? geometry.visibleTop)
                lastVisibleTop = geometry.visibleTop
                // Yield to the reader before a queued tail scroll can fire;
                // history-anchor corrections must keep the follow state.
                if delta < -0.5, geometry.distanceToBottom > 1, !controller.isAdjustingScroll {
                    onScrollAwayFromBottom()
                }
                onScroll(geometry, delta)
            }
            scheduleSettle()
        }

        /// One sleeping task per gesture instead of one per bounds change:
        /// the task re-arms itself until the clip view has been still for the
        /// settle delay.
        private func scheduleSettle() {
            guard settleTask == nil else { return }
            settleTask = Task { @MainActor [weak self] in
                var remaining = Self.settleDelayNanoseconds
                while true {
                    try? await Task.sleep(nanoseconds: remaining)
                    guard let self, !Task.isCancelled else { return }
                    let elapsed = DispatchTime.now().uptimeNanoseconds &- self.lastBoundsChange
                    if elapsed >= Self.settleDelayNanoseconds {
                        self.settleTask = nil
                        self.reportSettled()
                        return
                    }
                    remaining = Self.settleDelayNanoseconds - elapsed
                }
            }
        }

        private func reportSettled() {
            guard let geometry = controller.geometry else { return }
            lastVisibleTop = geometry.visibleTop
            onScrollSettled(geometry)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// The working Bot hops in a fixed slot; unknown profiles use the live step glyph.
struct SignalTrace: View {
    enum Phase {
        case thinking, tool, compacting

        init(activity: [ActiveToolCall]) {
            switch activity.last(where: { !$0.isComplete })?.name {
            case ActiveToolCall.thinkingName?, nil: self = .thinking
            case ActiveToolCall.compactionName?: self = .compacting
            default: self = .tool
            }
        }

        /// One theme-accent colour for every phase, so the emblem never flips
        /// between blue and grey as the live step changes.
        var color: Color { .dockAccent }
    }

    let phase: Phase
    let activity: [ActiveToolCall]
    var bot: BotSummary? = nil
    var botAvatar: Data? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    static let size: CGFloat = 56

    private var liveStep: ActiveToolCall? { activity.last(where: { !$0.isComplete }) }
    private var liveGlyph: Ph { Self.glyph(for: liveStep) }

    var body: some View {
        let color = phase.color
        ZStack {
            if let bot {
                BotWorkingAvatarView(bot: bot, imageData: botAvatar,
                                     activitySignature: activity.map { "\($0.id):\($0.isComplete)" },
                                     activityIcon: Self.glyph(for: activity.last))
            } else {
                Circle()
                    .fill(color.opacity(breathe ? 0.18 : 0.08))
                    .frame(width: 28, height: 28)
                    .scaleEffect(breathe ? 1 : 0.88)
                // Keyed by glyph so each new step starts its own trace loop.
                TracingGlyph(icon: liveGlyph, color: color)
                    .id(liveGlyph)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        // Without a Bot only the 28pt glyph shows; a 56pt frame left a wide gap before the text.
        .frame(width: bot == nil ? 32 : Self.size, height: bot == nil ? 32 : Self.size)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: liveGlyph)
        .animation(.easeInOut(duration: 0.3), value: phase)
        .onAppear {
            guard bot == nil, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathe = true }
        }
        .accessibilityHidden(true)
    }

    private static func glyph(for step: ActiveToolCall?) -> Ph {
        switch step?.name {
        case ActiveToolCall.thinkingName?, nil: return .brain
        case ActiveToolCall.compactionName?: return .arrowsInSimple
        default: return step.map { TurnActivityView.icon(for: $0.name) } ?? .wrench
        }
    }
}

/// A step glyph whose outline traces itself on a loop over a faint fill.
private struct TracingGlyph: View {
    let icon: Ph
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trace: CGFloat = 0
    @State private var breathe = false

    var body: some View {
        ZStack {
            PhosphorShape(icon: icon).fill(color.opacity(reduceMotion ? 1 : 0.35))
            // Phosphor glyphs are filled outlines, so a stroke draws both edges; keep it hairline.
            PhosphorShape(icon: icon)
                .trim(from: 0, to: reduceMotion ? 0 : trace)
                .stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: 0.35, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 13, height: 13)
        .scaleEffect(breathe ? 1.06 : 0.94)
        .opacity(breathe ? 1 : 0.7)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) { trace = 1 }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// One soft highlight sweeping across text; a single masked offset animation.
private struct RunningShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, Color.dockPrimaryText.opacity(0.55), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.45)
                            .offset(x: sweep ? proxy.size.width : -proxy.size.width * 0.45)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { sweep = true }
                }
        }
    }
}

/// Bots this session messaged that are still working after the turn that
/// sent them ended: the huddle with the finished lead dimmed.
struct BotCrewRow: View {
  let from: BotSummary
  let partners: [BotSummary]
  let since: Date
  var avatars: [String: Data] = [:]

  var body: some View {
    HStack(spacing: 12) {
      BotHuddle(lead: from, partners: partners, avatars: avatars, leadDone: true)
      VStack(alignment: .leading, spacing: 2) {
        (Text(partners.map(\.name).formatted(.list(type: .and))).foregroundStyle(Color.dockPrimaryText)
          + Text(" messaged by \(from.name)").fontWeight(.regular).foregroundStyle(Color.dockMetadataText))
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text("Working for about \(TurnActivityView.roughDuration(context.date.timeIntervalSince(since)))")
            .font(.system(size: 11))
            .foregroundStyle(Color.dockMetadataText)
            .modifier(RunningShimmer())
        }
      }
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Consecutive Bot DMs in a turn's steps, one row per Bot with its task and
/// live status. A finished row expands to the start of the Bot's reply.
struct BotDispatchCard: View {
  let records: [BotActivityRecord]
  var botsByID: [String: BotSummary] = [:]
  var avatars: [String: Data] = [:]
  @State private var openIDs: Set<String> = []

  var body: some View {
    let working = records.filter(\.isLive).count
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        DockIcon(.envelopeSimple, size: 11, color: Color.dockMetadataText)
        Text("Messaged \(records.count) Bot\(records.count == 1 ? "" : "s")" + (working > 0 && records.count > 1 ? " · \(working) working" : ""))
      }
      .font(.system(size: 11))
      .foregroundStyle(Color.dockMetadataText)
      .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 5)
      ForEach(records) { record in
        Divider().overlay(Color.dockBorderLight)
        row(record)
      }
    }
    .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).fill(Color.dockPrimaryText.opacity(0.03)))
    .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.75))
    .padding(.leading, 24)
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private func row(_ record: BotActivityRecord) -> some View {
    let bot = botsByID[record.botID]
    let reply = record.result.flatMap { $0.isEmpty ? nil : $0 }
    let isOpen = openIDs.contains(record.id)
    Button {
      guard reply != nil, !record.isLive else { return }
      if isOpen { openIDs.remove(record.id) } else { openIDs.insert(record.id) }
    } label: {
      HStack(spacing: 8) {
        if let bot {
          BotAvatarView(bot: bot, imageData: avatars[bot.id], size: 18, orbits: record.isLive)
        }
        Text(bot?.name ?? record.botName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockPrimaryText)
        Text(record.summary).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
          .lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 8)
        status(record)
        if reply != nil, !record.isLive {
          DockIcon(isOpen ? .caretDown : .caretRight, size: 9, color: Color.dockMetadataText)
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.dockHover)
    .help(record.state == .failed ? (reply ?? "Failed") : "")
    if isOpen, let reply {
      Text(reply)
        .font(.system(size: 12))
        .foregroundStyle(Color.dockSecondaryText)
        .lineLimit(8)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 36).padding(.trailing, 10).padding(.bottom, 8)
    }
  }

  @ViewBuilder
  private func status(_ record: BotActivityRecord) -> some View {
    Group {
      switch record.state {
      case .working, .queued, .waiting:
        TimelineView(.periodic(from: .now, by: 1)) { context in
          HStack(spacing: 5) {
            Circle().fill(Color.dockAccent).frame(width: 6, height: 6)
            Text(Self.clock(context.date.timeIntervalSince(record.createdAt)))
          }
        }
      case .failed:
        HStack(spacing: 4) { Text("×").fontWeight(.bold).foregroundStyle(Color.dockDestructive); Text("failed") }
      case .canceled:
        Text("canceled")
      case .completed:
        HStack(spacing: 4) {
          DockIcon(.check, size: 10, color: Color.dockSuccess)
          Text(Self.clock(record.updatedAt.timeIntervalSince(record.createdAt)))
        }
      }
    }
    .font(.system(size: 11).monospacedDigit())
    .foregroundStyle(Color.dockMetadataText)
  }

  /// "45s", "2m 14s", "1h 5m".
  static func clock(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
  }
}

extension BotActivityRecord {
  var isLive: Bool { state == .working || state == .queued || state == .waiting }
}

/// The tool calls behind one response, shown above its bubble. While the
/// response streams the list stays open and grows per call; once complete it
/// collapses to a "Worked for …" summary the reader can expand.
struct TurnActivityView: View {
  let activity: [ActiveToolCall]
  /// Turn start while streaming; nil once the response is complete.
  let runningSince: Date?
  let duration: TimeInterval?
  var bot: BotSummary? = nil
  var botAvatar: Data? = nil
  /// Bot DMs keyed by the tool call that sent them; those calls render as a card.
  var dispatches: [String: BotActivityRecord] = [:]
  /// Bots this session messaged that are still working, shown in the huddle.
  var crew: [BotSummary] = []
  var botsByID: [String: BotSummary] = [:]
  var avatars: [String: Data] = [:]
  @State private var isExpanded = false
  @State private var expandedThoughtIDs: Set<String> = []
  @State private var expandedDiffIDs: Set<String> = []
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let runningSince {
        // One transaction keeps each new step and the Bot's movement together.
        steps
        let phase = SignalTrace.Phase(activity: activity)
        let crew = bot.map { lead in self.crew.filter { $0.id != lead.id } } ?? []
        HStack(spacing: crew.isEmpty ? 10 : 12) {
          if let bot, !crew.isEmpty {
            BotHuddle(lead: bot, partners: crew, avatars: avatars.merging(botAvatar.map { [bot.id: $0] } ?? [:]) { a, _ in a })
          } else {
            SignalTrace(phase: phase, activity: activity, bot: bot, botAvatar: botAvatar)
          }
          VStack(alignment: .leading, spacing: 2) {
            // Live tool steps have their own row above; live compaction is named here instead.
            if bot != nil || phase == .compacting {
              (Text([bot?.name, phase == .compacting ? "Compacting context" : nil].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(Color.dockPrimaryText)
                + Text(crew.isEmpty ? "" : " with \(crew.map(\.name).formatted(.list(type: .and)))")
                .fontWeight(.regular).foregroundStyle(Color.dockMetadataText))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
              Text("Running for about \(Self.roughDuration(context.date.timeIntervalSince(runningSince)))"
                   + (crew.isEmpty ? "" : " · \(crew.count) Bot\(crew.count == 1 ? "" : "s") working"))
                .font(.system(size: bot == nil && phase != .compacting ? 12 : 11))
                .foregroundStyle(Color.dockMetadataText)
                .modifier(RunningShimmer())
            }
          }
        }
        .padding(.vertical, 6)
        .transition(.opacity)
      } else {
        Button {
          withAnimation(disclosureMotion) { isExpanded.toggle() }
        } label: {
          HStack(spacing: 6) {
            Text(summary).font(.system(size: 12, weight: .medium))
            DockIcon(isExpanded ? .caretDown : .caretRight, size: 10)
          }
          .foregroundStyle(Color.dockSecondaryText)
          .padding(.vertical, 6)
          .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityLabel(isExpanded ? "Hide activity" : "Show activity")
        .transition(.opacity)
        if isExpanded {
          steps
        } else if segments.contains(where: { $0.records.contains(where: \.isLive) }) {
          // Bots still working outlive the collapse until they finish.
          VStack(alignment: .leading, spacing: 6) {
            ForEach(segments.filter { $0.records.contains(where: \.isLive) }) { card($0.records) }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(stepMotion, value: stepSignature)
    .animation(stepMotion, value: runningSince != nil)
  }

  /// Whole units only: "45 seconds", "3 minutes", "2 hours".
  static func roughDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    let (value, unit) = s < 60 ? (s, "second") : s < 3600 ? (s / 60, "minute") : (s / 3600, "hour")
    return "\(value) \(unit)\(value == 1 ? "" : "s")"
  }

  private var summary: String {
    let count = "\(activity.count) step\(activity.count == 1 ? "" : "s")"
    return duration.map { "Worked for \(Self.roughDuration($0)) · \(count)" } ?? "Worked · \(count)"
  }

  private var motionEnabled: Bool { !reduceMotion && DockThemeStyle.current.animates }
  private var stepMotion: Animation? { motionEnabled ? .spring(response: 0.38, dampingFraction: 0.86) : nil }
  private var disclosureMotion: Animation? { motionEnabled ? .dockEase(duration: 0.18) : nil }
  private var stepSignature: [String] { activity.map { "\($0.id):\($0.isComplete):\(dispatches[$0.id]?.state.rawValue ?? "")" } }

  /// One step, or a run of consecutive Bot DMs shown as one card.
  private struct Segment: Identifiable {
    let calls: [ActiveToolCall]
    let records: [BotActivityRecord]
    var id: String { calls[0].id }
  }

  private var segments: [Segment] {
    var result: [Segment] = []
    for call in activity {
      if let record = dispatches[call.id] {
        if let last = result.last, !last.records.isEmpty {
          result[result.count - 1] = Segment(calls: last.calls + [call], records: last.records + [record])
          continue
        }
        result.append(Segment(calls: [call], records: [record]))
      } else {
        result.append(Segment(calls: [call], records: []))
      }
    }
    return result
  }

  private func card(_ records: [BotActivityRecord]) -> some View {
    BotDispatchCard(records: records, botsByID: botsByID, avatars: avatars)
  }

  private var steps: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(segments) { segment in
        let call = segment.calls[0]
        if !segment.records.isEmpty {
          card(segment.records)
        } else if call.name == ActiveToolCall.thinkingName {
          thoughtRow(call)
        } else if call.name == ActiveToolCall.compactionName {
          if call.isComplete { CompactionStepRow(call: call) }
        } else {
          toolRow(call)
        }
      }
      .transition(stepMotion == nil ? .identity : .opacity.combined(with: .offset(y: 6)))
    }
    .padding(.vertical, 4)
  }

  private func thoughtRow(_ call: ActiveToolCall) -> some View {
    let isOpen = expandedThoughtIDs.contains(call.id)
    let seconds = call.completedAt.map { $0.timeIntervalSince(call.startedAt) }
    let title = call.isComplete
      ? seconds.map { "Thought for \(Self.roughDuration($0))" } ?? "Thought"
      : "Thinking"
    return VStack(alignment: .leading, spacing: 4) {
      Button {
        withAnimation(disclosureMotion) {
          if isOpen { expandedThoughtIDs.remove(call.id) } else { expandedThoughtIDs.insert(call.id) }
        }
      } label: {
        HStack(spacing: 8) {
          stepIcon(.brain)
          Text(title).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
          if !call.isComplete { ProgressView().controlSize(.mini) }
          DockIcon(isOpen ? .caretDown : .caretRight, size: 9, color: Color.dockMetadataText)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.dockHover)
      .accessibilityLabel(isOpen ? "Hide thinking" : "Show thinking")
      if isOpen {
        Text((call.result ?? "").isEmpty ? "…" : call.result ?? "")
          .font(.system(size: 12))
          .foregroundStyle(Color.dockMetadataText)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, 28)
      }
    }
  }

  private func stepIcon(_ icon: Ph) -> some View {
    DockIcon(icon, size: 13, color: Color.dockSecondaryText).frame(width: 16, height: 16)
  }

  @ViewBuilder
  private func toolRow(_ call: ActiveToolCall) -> some View {
    if let diff = call.diffPreview, let stats = call.diffStats {
      // Edits carry their diff, collapsed until asked for.
      let isOpen = expandedDiffIDs.contains(call.id)
      VStack(alignment: .leading, spacing: 4) {
        Button {
          withAnimation(disclosureMotion) {
            if isOpen { expandedDiffIDs.remove(call.id) } else { expandedDiffIDs.insert(call.id) }
          }
        } label: {
          HStack(spacing: 8) {
            toolLabel(call)
            Text("+\(stats.added)").foregroundStyle(Color.dockSuccess)
            Text("−\(stats.removed)").foregroundStyle(Color.dockDestructive)
            DockIcon(isOpen ? .caretDown : .caretRight, size: 9, color: Color.dockMetadataText)
          }
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityLabel(isOpen ? "Hide changes" : "Show changes")
        if isOpen {
          ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(PullRequestDiffPresentation.lines(diff)) { line in
                PullRequestDiffLineView(line: line)
              }
            }
          }
          .frame(maxHeight: 280)
          .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).fill(Color.dockCanvas))
          .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
          .padding(.leading, 24)
        }
      }
    } else {
      toolLabel(call)
    }
  }

  private func toolLabel(_ call: ActiveToolCall) -> some View {
    HStack(spacing: 8) {
      if Self.isFileTool(call.name), let image = ArtifactFileIcon.inlineImage(forPath: call.context, size: 14) {
        Image(nsImage: image).frame(width: 16, height: 16)
      } else {
        stepIcon(Self.icon(for: call.name))
      }
      Text(AgentActivityPresentation.toolActivityTitle(name: call.name, context: call.context))
        .font(.system(size: 12))
        .foregroundStyle(Color.dockSecondaryText)
        .lineLimit(1).truncationMode(.tail)
      if !call.isComplete { ProgressView().controlSize(.mini) }
    }
    .help(Self.tooltip(for: call))
  }

  /// Readable hover text: the tool's context, then its unwrapped output, capped so it stays a tooltip.
  static func tooltip(for call: ActiveToolCall) -> String {
    var output = call.result ?? ""
    if let data = output.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      if let error = json["error"] as? String, !error.isEmpty {
        output = "Error: \(error)"
      } else if let text = json["output"] as? String {
        output = text
      }
    }
    output = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.count > 12 { output = lines.prefix(12).joined(separator: "\n") + "\n…" }
    if output.count > 800 { output = String(output.prefix(800)) + "…" }
    let head = call.context.isEmpty ? AgentActivityPresentation.toolActivityTitle(name: call.name, context: call.context) : call.context
    let body = output.isEmpty ? call.input : output
    return body.isEmpty ? head : "\(head)\n\n\(body)"
  }

  /// Tools whose context is one file path, so the row can show its type icon.
  static func isFileTool(_ toolName: String) -> Bool {
    ["read_file", "write_file", "edit_file", "patch", "apply_patch"]
      .contains(toolName.lowercased().replacingOccurrences(of: "-", with: "_"))
  }

  static func icon(for toolName: String) -> Ph {
    let name = toolName.lowercased().replacingOccurrences(of: "-", with: "_")
    switch name {
    case "terminal", "shell", "exec", "exec_command", "process": return .terminal
    case "patch", "apply_patch", "edit_file", "write_file": return .pencilSimple
    case "read_file": return .fileText
    case "search_files", "search", "grep": return .magnifyingGlass
    case "view_image", "vision_analyze": return .image
    case "todo": return .listChecks
    default:
      if name.contains("delegate") || name.contains("subagent") { return .usersThree }
      if name.contains("browser") || name.contains("web") || name.contains("fetch") { return .globe }
      if name.contains("memory") || name.contains("skill") { return .brain }
      return .wrench
    }
  }
}

extension ActiveToolCall {
  /// Added and removed line counts of `diffPreview`, ignoring file headers.
  var diffStats: (added: Int, removed: Int)? {
    guard let diffPreview, !diffPreview.isEmpty else { return nil }
    var added = 0, removed = 0
    for line in diffPreview.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
      if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
    }
    return (added, removed)
  }
}

/// Live compaction step: transcript lines squeeze into one while a shimmer
/// sweeps the label, settling into a static "Compacted context" step.
private struct CompactionStepRow: View {
  let call: ActiveToolCall
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isSqueezed = false
  @State private var shimmer: CGFloat = -1

  var body: some View {
    HStack(spacing: 8) {
      if call.isComplete {
        DockIcon(.arrowsInLineVertical, size: 13, color: Color.dockSecondaryText).frame(width: 16, height: 16)
          .transition(.scale.combined(with: .opacity))
        Text(title).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
      } else {
        squeezeGlyph.frame(width: 16, height: 16)
        Text("Compacting context")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.dockAccent)
          .overlay { if !reduceMotion { shimmerOverlay } }
      }
    }
    .animation(.dockEase(duration: 0.25), value: call.isComplete)
    .help("Hermes summarizes older turns to free context")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(call.isComplete ? title : "Compacting context")
    .onAppear {
      guard !reduceMotion, !call.isComplete else { return }
      withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { isSqueezed = true }
      withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { shimmer = 1 }
    }
  }

  private var title: String {
    call.completedAt.map { "Compacted context in \(TurnActivityView.roughDuration($0.timeIntervalSince(call.startedAt)))" }
      ?? "Compacted context"
  }

  /// Three transcript lines that fold toward the middle one and back.
  private var squeezeGlyph: some View {
    ZStack {
      ForEach(Array([(-4.5, 10.0), (0, 14.0), (4.5, 8.0)].enumerated()), id: \.offset) { index, line in
        Capsule()
          .fill(Color.dockAccent.opacity(index == 1 ? 1 : isSqueezed ? 0.25 : 0.7))
          .frame(width: isSqueezed ? 14 : line.1, height: 2)
          .offset(y: isSqueezed ? 0 : line.0)
      }
    }
  }

  private var shimmerOverlay: some View {
    GeometryReader { proxy in
      LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
        .frame(width: proxy.size.width * 0.5)
        .offset(x: shimmer * proxy.size.width)
    }
    .mask(Text("Compacting context").font(.system(size: 12, weight: .medium)))
    .allowsHitTesting(false)
  }
}

/// Copies one fenced block and briefly confirms it in place.
private struct MarkdownCodeCopyButton: View {
  let code: String

  var body: some View {
    DockCopyButton(code, accessibilityLabel: "Copy code", presentation: .text)
      .font(DockTypography.control)
      .padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
    .buttonStyle(.dockCompact)
  }
}
