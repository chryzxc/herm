import AppKit
import SwiftUI

/// Where a live voice conversation shows outside the Talk tab: the voice widget at the
/// top of the screen, whichever edge the dock lives on, unless a Talk tab already shows it.
enum EdgeVoiceStagePlacement: Equatable {
    case hidden
    /// The fixed-look widget at the top of the screen: it grows out of the camera
    /// notch and hangs below the menu bar on a screen without one.
    case island

    static func resolve(voiceActive: Bool, talkTabShowing: Bool) -> Self {
        voiceActive && !talkTabShowing ? .island : .hidden
    }
}

/// Drives the widget's grow-in and melt-away, so hiding can animate before the panel leaves.
@MainActor
private final class EdgeVoiceIslandPresence: ObservableObject {
    @Published var shown = false
    /// The camera housing the widget grows out of; zero on a screen without one.
    @Published var housing = CGSize.zero
}

/// The floating voice widget: dark glass like the notch, whatever Herm's skin, and
/// always at the top of the screen whichever edge the dock lives on. On a Mac with a
/// camera housing it grows straight out of the notch; elsewhere it hangs below the menu bar.
@MainActor
final class EdgeVoiceIsland {
    private let model: DockModel
    private let presence = EdgeVoiceIslandPresence()
    private(set) var panel: NSPanel?
    private let sizer = EdgeVoicePanelSizer(width: EdgeVoiceIsland.width)
    /// The reply's visual, in its own floating glass panel below the widget.
    private(set) var previewPanel: NSPanel?
    private let previewSizer = EdgeVoicePanelSizer(width: EdgeVoicePreviewView.width)
    /// The widget body's real height, so the preview floats just below it, not below the panel's headroom.
    private var bodyHeight: CGFloat = 0
    /// The widget's width; its light stays inside the body, so the panel needs no margin.
    static let width: CGFloat = 580
    /// Gap between the notch widget and the floating preview.
    static let previewGap: CGFloat = 12

    init(model: DockModel) { self.model = model }

    func show(_ visible: Bool) {
        guard visible else {
            guard presence.shown else { return }
            presence.shown = false
            // Let the widget fold back into the notch, and the preview drop back into it, first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, !self.presence.shown else { return }
                self.panel?.orderOut(nil)
                self.previewPanel?.orderOut(nil)
            }
            return
        }
        let panel =
            self.panel
            ?? makePanel(
                EdgeVoiceIslandView(model: model, mic: model.voiceMic, presence: presence) { [weak self] size in
                    guard let self else { return }
                    self.bodyHeight = size.height
                    self.sizer.fit(size) { self.place() }
                    self.placePreview()
                })
        self.panel = panel
        let preview =
            previewPanel
            ?? makePanel(
                EdgeVoicePreviewView(model: model, presence: presence) { [weak self] size in
                    guard let self else { return }
                    self.previewSizer.fit(size, delay: 0.6) { self.placePreview() }
                })
        previewPanel = preview
        place()
        placePreview()
        guard !presence.shown else { return }
        panel.orderFrontRegardless()
        // Next pass, so the folded state renders first and the widget springs open from it.
        DispatchQueue.main.async { [weak self] in self?.presence.shown = true }
    }

    private var top: CGFloat? {
        guard let screen = NSScreen.screens.first else { return nil }
        let housing = EdgeNotchMetrics.hasCameraHousing(screen) ? EdgeNotchMetrics.notchSize(for: screen) : .zero
        if presence.housing != housing { presence.housing = housing }
        // Flush with the screen top around a notch; below the menu bar elsewhere.
        return housing.height > 0 ? screen.frame.maxY : screen.visibleFrame.maxY - 8
    }

    private func place() {
        guard let panel, let top, let screen = NSScreen.screens.first else { return }
        panel.setFrame(sizer.frame(midX: screen.frame.midX, top: top), display: true)
    }

    /// Hangs the preview below the widget's visible body. Empty, it leaves the screen.
    private func placePreview() {
        guard let previewPanel, let top, let screen = NSScreen.screens.first else { return }
        guard previewSizer.height > 0, presence.shown || previewPanel.isVisible else {
            previewPanel.orderOut(nil)
            return
        }
        let frame = previewSizer.frame(midX: screen.frame.midX, top: top - bodyHeight - Self.previewGap)
        if previewPanel.frame.size == frame.size {
            previewPanel.setFrameOrigin(frame.origin)
        } else {
            previewPanel.setFrame(frame, display: true)
        }
        if !previewPanel.isVisible { previewPanel.orderFrontRegardless() }
    }

    /// The panel height for a content height: rounded up so small changes never resize the window.
    static func paddedHeight(_ content: CGFloat) -> CGFloat { (content / 40).rounded(.up) * 40 }

    private func makePanel(_ root: some View) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // One above the dock's own panel, which shares the notch when it sits on the top edge.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        // The notch's fixed dark look: Herm's skin never reaches the widget.
        panel.appearance = DockThemeStore.notchAppearance
        panel.contentView = EdgeVoiceHostingView(rootView: root)
        // Lay the hosting view out once off-screen so the first open doesn't pay for it mid-spring.
        panel.contentView?.layoutSubtreeIfNeeded()
        return panel
    }
}

/// The widget's panel never becomes key, so without this every click is swallowed as
/// the window's activating "first mouse" and End voice, Mute and the orb never fire.
private final class EdgeVoiceHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Window size for a springing SwiftUI body. A window resize is expensive and a spring
/// passes through many sizes, so growth jumps once to room for the whole spring and
/// shrinking waits until it settles; the body animates inside the panel meanwhile.
@MainActor
private final class EdgeVoicePanelSizer {
    let width: CGFloat
    private(set) var height: CGFloat = 0
    private var shrink: DispatchWorkItem?

    init(width: CGFloat) { self.width = width }

    func fit(_ content: CGSize, delay: TimeInterval = 0.45, apply: @escaping () -> Void) {
        shrink?.cancel()
        let target = content.height < 1 ? 0 : EdgeVoiceIsland.paddedHeight(content.height)
        if target > height {
            height = EdgeVoiceIsland.paddedHeight(content.height + 160)
            apply()
        }
        // Always trim back once the body settles; growth alone leaves the spring's headroom.
        if target < height {
            let work = DispatchWorkItem { [weak self] in
                self?.height = target
                apply()
            }
            shrink = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func frame(midX: CGFloat, top: CGFloat) -> NSRect {
        NSRect(x: midX - width / 2, y: top - max(height, 1), width: width, height: max(height, 1)).integral
    }
}

private struct EdgeVoiceIslandView: View {
    /// Passed through only; the widget below observes the voice stage itself.
    let model: DockModel
    @ObservedObject var mic: MicLevelMeter
    @ObservedObject var presence: EdgeVoiceIslandPresence
    let onSize: (CGSize) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = presence.shown
        let housing = presence.housing
        let onNotch = housing.height > 0
        // Around a notch the body is the notch itself: flat to the screen edge with concave shoulders.
        let shape = onNotch ? AnyShape(EdgeNotchShape(side: .top)) : AnyShape(RoundedRectangle(cornerRadius: 28))
        let folded = CGSize(width: onNotch ? housing.width / EdgeVoiceIsland.width : 0.3, height: 0.12)
        EdgeVoiceWidget(model: model, mic: mic, bots: model.botMode, shown: shown)
            .dockPadding(.top, housing.height)
            .dockPadding(.horizontal, onNotch ? EdgeVoiceWidget.shoulder : 0)
            .frame(width: EdgeVoiceIsland.width)
            .fixedSize(horizontal: false, vertical: true)
            .background { EdgeVoiceGlass(shape: shape, housing: housing.height) }
            .clipShape(shape)
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                onSize($0)
            }
            // The one authored moment: folded to the camera housing, it springs open out of the notch.
            .scaleEffect(
                x: shown || reduceMotion ? 1 : folded.width, y: shown || reduceMotion ? 1 : folded.height,
                anchor: .top
            )
            .opacity(shown || !reduceMotion ? 1 : 0)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.15)
                    : shown
                        ? .spring(response: 0.5, dampingFraction: 0.78) : .spring(response: 0.28, dampingFraction: 1),
                value: shown
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .dockThemedRoot(surface: .cameraNotch).dockPreferredTextSize()
    }
}

/// The reply's visual (charts, tables, previews; never its prose, which is spoken and
/// captioned) as its own floating glass panel below the notch widget. It drops out of the
/// widget like a bead of liquid, reshapes as the visual changes, and draws back up when done.
private struct EdgeVoicePreviewView: View {
    let model: DockModel
    /// Redraws on voice changes only; the body still reads the model.
    @ObservedObject private var stage: VoiceStageState
    @ObservedObject var presence: EdgeVoiceIslandPresence
    let onSize: (CGSize) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: DockModel, presence: EdgeVoiceIslandPresence, onSize: @escaping (CGSize) -> Void) {
        self.model = model
        _stage = ObservedObject(wrappedValue: model.voiceStage)
        self.presence = presence
        self.onSize = onSize
    }

    static let width: CGFloat = 640
    static let maxHeight: CGFloat = 460

    var body: some View {
        let clarification = presence.shown ? stage.snapshot.clarificationPreview : nil
        let visual =
            presence.shown && clarification == nil && model.voicePreview(on: .floating) == .visual
            ? model.voiceGenerativeReply : nil
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(spacing: 0) {
            if clarification != nil || visual != nil {
                Group {
                    if let clarification {
                        VoiceClarificationChoices(preview: clarification)
                    } else if let visual {
                        VoiceGenerativeCard(
                            model: model, message: visual, maxWidth: Self.width - 40, floating: false,
                            maxHeight: Self.maxHeight - 40)
                    }
                }
                .dockPadding(20)
                .frame(width: Self.width)
                .fixedSize(horizontal: false, vertical: true)
                .background { EdgeVoiceGlass(shape: AnyShape(shape), housing: 0) }
                .clipShape(shape)
                .transition(drop)
            }
        }
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            onSize($0)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : EdgeVoiceWidget.liquid, value: visual?.id)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : EdgeVoiceWidget.liquid, value: clarification?.key)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .dockThemedRoot(surface: .cameraNotch).dockPreferredTextSize()
    }

    /// Out of the widget above: squeezed and lifted toward it, then springing to full size.
    private var drop: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.4, anchor: .top).combined(with: .offset(y: -36)).combined(with: .opacity)
    }
}

/// One material for the embedded stage and floating panels. Only the camera band is black.
struct EdgeVoiceGlass: View {
    let shape: AnyShape
    let housing: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @DockChromeTheme private var theme

    var body: some View {
        let tint = DockThemePalette(theme: theme).opaqueBackground
        ZStack(alignment: .top) {
            if reduceTransparency {
                tint
            } else {
                if #available(macOS 26.0, *) {
                    NativeLiquidGlassBackground()
                } else {
                    NativePopoverBackground(material: .hudWindow)
                }
                tint.opacity(theme == .island ? 0.72 : 0.5)
            }
            if housing > 0 {
                VStack(spacing: 0) {
                    Rectangle().fill(.black).frame(height: housing)
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                }
            }
        }
        .overlay {
            shape.stroke(
                LinearGradient(
                    colors: [Color.dockGlassHighlight, .clear, Color.dockGlassHighlight.opacity(0.7)],
                    startPoint: .bottomLeading, endPoint: .topTrailing),
                lineWidth: DockLayout.hairline
            )
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The voice widget's content: a living orb beside one quiet status and one large line,
/// a caption, and a band of light along the bottom. The reply's visual
/// floats in its own panel below. The notch can minimize the widget during a call.
struct EdgeVoiceWidget: View {
    let model: DockModel
    /// Redraws on voice changes only; the body still reads the model.
    @ObservedObject private var stage: VoiceStageState
    @ObservedObject var mic: MicLevelMeter
    @ObservedObject var bots: BotModeModel
    let shown: Bool
    /// Inside Herm's notch the reply's visual opens in the notch too; the standalone
    /// widget floats it in its own panel instead.
    var inNotch = false
    /// The content width inside the notch, for the reply's visual.
    var visualWidth: CGFloat = 0
    let onMinimize: (() -> Void)?
    @State private var heldCue: (generation: Int, text: String)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @DockChromeTheme private var theme

    init(
        model: DockModel, mic: MicLevelMeter, bots: BotModeModel, shown: Bool, inNotch: Bool = false,
        visualWidth: CGFloat = 0, onMinimize: (() -> Void)? = nil
    ) {
        self.model = model
        _stage = ObservedObject(wrappedValue: model.voiceStage)
        self.mic = mic
        self.bots = bots
        self.shown = shown
        self.inNotch = inNotch
        self.visualWidth = visualWidth
        self.onMinimize = onMinimize
    }

    /// Shell and preview changes settle with a little give so the glass reads as liquid.
    static let liquid = Animation.spring(response: 0.5, dampingFraction: 0.74)
    /// The notch shape's concave top corners; content stays inside them.
    static let shoulder: CGFloat = 18

    var body: some View {
        let stage = VoiceStagePresentation(model: model)
        VStack(alignment: .leading, spacing: 14) {
            header(stage)
            if inNotch, let clarification = self.stage.snapshot.clarificationPreview {
                VoiceClarificationChoices(preview: clarification)
                    .frame(maxWidth: visualWidth)
                    .transition(unfold)
            } else if inNotch, model.voicePreview(on: .floating) == .visual, let visual = model.voiceGenerativeReply {
                VoiceGenerativeCard(
                    model: model, message: visual, maxWidth: visualWidth, floating: false, maxHeight: 320
                )
                .transition(unfold)
            }
        }
        .dockPadding(.horizontal, 16)
        .dockPadding(.top, 10)
        .dockPadding(.bottom, 20)
        .overlay(alignment: .bottom) {
            EdgeVoiceLightBand(
                level: mic.reading, tint: stage.statusTint, thinking: stage.orbMode == .thinking, active: shown)
        }
        // Content arrives just after the body opens and leaves before it folds.
        // Opacity and a short lift only: a blur over the whole content costs frames on the open.
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : -6)
        .animation(shown ? .easeOut(duration: 0.28).delay(0.1) : .easeIn(duration: 0.1), value: shown)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Self.liquid, value: self.stage.screenContext)
        .onChange(of: model.voiceSpokenCaption, initial: true) { _, cue in
            guard model.voiceState == .speaking, let cue else { return }
            heldCue = (model.voicePlaybackGeneration, cue)
        }
        .onChange(of: model.voiceState) { _, state in
            if state != .speaking { heldCue = nil }
        }
    }

    private var handoff: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .scale(scale: 0.4).combined(with: .opacity),
                removal: .scale(scale: 1.4).combined(with: .opacity))
    }

    private var unfold: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.94, anchor: .top).combined(with: .opacity)
    }

    private func header(_ stage: VoiceStagePresentation) -> some View {
        let pendingPrompt: String? =
            if stage.hasApproval { model.voicePromptSpeech } else if stage.hasQuestion {
                model.clarificationQuestion
            } else if stage.hasValuePrompt { "Open the conversation to enter the requested information securely." } else
            { nil }
        let said = pendingPrompt ?? model.messages.last(where: { $0.role == .user })?.text
        let heldSpeech = heldCue?.generation == model.voicePlaybackGeneration ? heldCue?.text : nil
        let quietLine =
            model.isNotchVoiceConversation && !model.isVoiceMicMuted && model.voiceState == .listening
            ? model.voiceSpokenCaption : nil
        let line =
            stage.widgetCaption(
                heard: mic.transcript, said: said, caption: model.voiceSpokenCaption, heldSpeech: heldSpeech)
            ?? (quietLine ?? pendingPrompt).map { VoiceWidgetCaption($0) }
        let bot = model.voiceBot
        let needsCapture = stage.orbMode == .listening || stage.wakesByVoice
        let preparingSpeech = needsCapture && mic.isPreparingSpeech
        let waitingForCapture = needsCapture && (mic.isStarting || mic.isPreparingSpeech)
        let status =
            if preparingSpeech {
                "Preparing speech recognition…"
            } else if waitingForCapture {
                "Starting microphone…"
            } else {
                stage.widgetStatus
            }
        let failure =
            model.voiceState == .paused && !model.isVoiceMicMuted
            ? (model.isNotchVoiceConversation ? model.voiceSpokenCaption : nil)
                ?? model.messages.last.flatMap { $0.isError ? $0.text : nil } : nil
        // An uploaded avatar shows as itself; a saved Herm face is drawn live instead.
        let avatar = bot.flatMap { bot in
            bots.avatarImages[bot.id].flatMap { BotAvatarView.showsHermFace($0, id: bot.id) ? nil : (bot, $0) }
        }
        return HStack(alignment: .center, spacing: 14) {
            Button {
                _ = model.voiceOrbTapped()
            } label: {
                EdgeVoiceWidgetOrb(
                    level: mic.reading, mode: stage.orbMode, tint: stage.statusTint,
                    faceID: bot?.id ?? model.defaults.string(forKey: DockModel.voiceBotFaceKey),
                    avatar: avatar, active: shown
                )
                .frame(width: EdgeVoiceWidgetOrb.side, height: EdgeVoiceWidgetOrb.side)
                // A Bot switch mid-call swaps the face: the old one spins away, the new one lands.
                .id(bot?.id)
                .transition(handoff)
                .contentShape(Circle())
            }
            .buttonStyle(.dockHover)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72), value: bot?.id)
            .help(stage.orbHelp)
            .accessibilityLabel(stage.orbHelp)
            VStack(alignment: .leading, spacing: 3) {
                if let error = mic.errorMessage {
                    Text("Voice input unavailable")
                        .dockFont(size: 12, weight: .semibold)
                        .foregroundStyle(Color.dockWarning)
                    Text(error)
                        .dockFont(size: 15, weight: .medium)
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(2)
                    Button("Try again") {
                        mic.stop()
                        model.syncVoiceCapture()
                    }
                    .buttonStyle(.dockLink)
                } else {
                    HStack(spacing: 8) {
                        // Work in progress reads as quiet metadata; only live states (listening) carry color.
                        let quiet = stage.orbMode == .thinking
                        let wakePrompt =
                            stage.orbMode == .idle && stage.wakesByVoice && failure == nil && !waitingForCapture
                        Text(status)
                            .dockFont(size: wakePrompt ? 18 : 13, weight: quiet ? .regular : .semibold)
                            .foregroundStyle(
                                wakePrompt ? Color.dockPrimaryText : quiet ? Color.dockSecondaryText : stage.statusTint
                            )
                            .lineLimit(wakePrompt ? 2 : 1)
                            .contentTransition(.opacity)
                        EdgeVoiceHelperFaces(agents: model.activeSubagents.filter(\.isRunning))
                    }
                    if let failure {
                        // A paused call says why, not just "Paused"; the chat keeps the same message.
                        Text(failure)
                            .dockFont(size: 13)
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try again") { model.resumeVoiceListening(force: true) }
                            .buttonStyle(.dockLink)
                    } else if !waitingForCapture,
                        let caption = line
                            ?? (stage.orbMode == .listening ? VoiceWidgetCaption("Go ahead, I’m listening") : nil)
                    {
                        captionView(caption, dimmed: line == nil)
                    }
                }
                if let seen = self.stage.screenContext {
                    VoiceScreenChip(context: seen).transition(unfold)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : EdgeVoiceWidget.liquid, value: status)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : EdgeVoiceWidget.liquid, value: mic.errorMessage)
            controls
        }
    }

    private func captionView(_ caption: VoiceWidgetCaption, dimmed: Bool) -> some View {
        let handoff: AnyTransition =
            reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 4)),
                removal: .opacity.combined(with: .offset(y: -3)))
        return ZStack(alignment: .topLeading) {
            Text(caption.text)
                .dockFont(size: 20, weight: .medium)
                .foregroundStyle(dimmed ? Color.dockSecondaryText : Color.dockPrimaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .id(caption.handoff)
                .transition(handoff)
        }
        .clipped()
        .animation(reduceMotion ? .easeOut(duration: 0.14) : .dockEase(duration: 0.23), value: caption.handoff)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(caption.text))
    }

    /// Compact call controls at the end of the row.
    private var controls: some View {
        HStack(spacing: 2) {
            DockIconButton(
                icon: model.isVoiceMicMuted ? .microphoneSlash : .microphone,
                label: model.isVoiceMicMuted ? "Unmute mic" : "Mute mic", hasBackground: false, size: 30,
                style: DockThemePalette(theme: theme), action: model.toggleVoiceMicMuted)
            if let onMinimize {
                DockIconButton(
                    icon: .minus, label: "Minimize voice", hasBackground: false, size: 30,
                    style: DockThemePalette(theme: theme), action: onMinimize)
            }
            DockIconButton(
                icon: .x, label: "End voice", hasBackground: false, size: 30,
                style: DockThemePalette(theme: theme), action: model.stopVoiceConversation)
        }
        .dockPadding(3)
        .dockWell(.raised, radius: 20)
        .fixedSize()
    }
}

/// A small living light: three soft colors drifting inside a sphere, breathing with
/// your voice, racing while the agent thinks, settling while it waits.
struct EdgeVoiceWidgetOrb: View {
    static let side: CGFloat = 56
    @ObservedObject var level: VoiceMeterReading
    let mode: VoiceOrbMode
    let tint: Color
    /// The bot you're talking to, or the last one voice used while the roster loads. Nil only
    /// before voice has ever resolved a bot; the light stands alone then.
    var faceID: String?
    /// The bot's uploaded picture, when it has one instead of a drawn face.
    var avatar: (bot: BotSummary, data: Data)?
    /// False while the widget is folded away, so nothing keeps animating off screen.
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let avatar {
            BotAvatarView(
                bot: avatar.bot, imageData: avatar.data, size: 44, animated: active,
                mood: VoiceOrbView.faceMood(for: mode)
            )
            .clipShape(Circle())
            .frame(width: Self.side, height: Self.side)
            .allowsHitTesting(false)
        } else if let faceID {
            face(faceID)
        } else {
            sphere
        }
    }

    /// The bot's own face on a faint disc, its mood following the conversation and
    /// leaning in a little as you speak.
    private func face(_ id: String) -> some View {
        let loud = mode == .idle ? 0 : min(1, Double(level.level) * 1.6)
        return ZStack {
            Circle().fill(Color.white.opacity(mode == .idle ? 0.06 : 0.1))
            BotFaceMark(
                id: id, size: 38, animated: !reduceMotion && active, busy: mode != .idle,
                mood: VoiceOrbView.faceMood(for: mode), theme: .glass)
        }
        .scaleEffect(reduceMotion ? 1 : 1 + 0.08 * loud)
        .animation(.smooth(duration: 0.15), value: loud)
        .frame(width: Self.side, height: Self.side)
        .allowsHitTesting(false)
    }

    private var sphere: some View {
        TimelineView(.dockMotion(paused: reduceMotion || mode == .idle || !active)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let turn = time * (mode == .thinking ? 260 : 70)
            let loud = mode == .idle ? 0 : min(1, Double(level.level) * 1.6)
            ZStack {
                // Colored light turning inside the sphere.
                Circle().fill(
                    AngularGradient(
                        colors: [
                            DockAccentColor.cyan.fill, DockAccentColor.violet.fill, tint, DockAccentColor.cyan.fill,
                        ],
                        center: .center, angle: .degrees(turn)))
                // A soft core that brightens as you speak.
                Circle().fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.35 + 0.4 * loud), .clear], center: .center, startRadius: 0,
                        endRadius: 22))
                // Shade toward the rim so it reads as a sphere, not a disc.
                Circle().fill(
                    RadialGradient(
                        colors: [.clear, Color.black.opacity(0.45)], center: UnitPoint(x: 0.4, y: 0.35),
                        startRadius: 12, endRadius: 32))
            }
            .frame(width: 50, height: 50)
            .scaleEffect(0.9 + 0.14 * loud)
            .opacity(mode == .idle ? 0.5 : 1)
            .animation(.smooth(duration: 0.12), value: loud)
            .frame(width: Self.side, height: Self.side)
        }
        .allowsHitTesting(false)
    }
}

/// The widget's edge light, kept inside the body so nothing smears past its corners:
/// a thin band of color along the bottom that widens with your voice and flows while it thinks.
private struct EdgeVoiceLightBand: View {
    @ObservedObject var level: VoiceMeterReading
    let tint: Color
    let thinking: Bool
    /// False while the widget is folded away, so its light stops drawing.
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let flows = active && thinking && !reduceMotion
        TimelineView(.dockMotion(paused: !flows)) { context in
            let time = flows ? context.date.timeIntervalSinceReferenceDate : 0
            let phase = (time * 0.9).truncatingRemainder(dividingBy: 1)
            let loud = thinking ? 0.55 : min(1, Double(level.level) * 1.6)
            let light = LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: DockAccentColor.cyan.fill, location: 0.15 + 0.2 * phase),
                    .init(color: tint, location: 0.5),
                    .init(color: DockAccentColor.violet.fill, location: 0.65 + 0.2 * phase),
                    .init(color: .clear, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            ZStack(alignment: .bottom) {
                // A vertical fade stands in for a glow; a live blur re-rasterizes every frame.
                Rectangle().foregroundStyle(light).frame(height: 10)
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                    .opacity(0.2 + 0.45 * loud)
                Capsule().foregroundStyle(light).frame(height: 1.5).opacity(0.5 + 0.5 * loud)
            }
            .scaleEffect(x: 0.45 + 0.55 * loud, anchor: .center)
            .dockPadding(.horizontal, 36)
            .animation(.smooth(duration: 0.18), value: loud)
        }
        .frame(height: 12)
        .allowsHitTesting(false)
    }
}

/// Helper bots Hermes has running for this turn, as small still faces beside the status.
struct EdgeVoiceHelperFaces: View {
    let agents: [HermesSubagent]

    var body: some View {
        if !agents.isEmpty {
            HStack(spacing: 2) {
                ForEach(agents.prefix(4)) { agent in
                    BotFaceMark(id: agent.name ?? agent.id, size: 13, theme: .glass)
                        .frame(width: 18, height: 18)
                        .help(agent.latestActivity ?? agent.goal)
                }
                if agents.count > 4 {
                    Text("+\(agents.count - 4)")
                        .dockFont(size: 11, weight: .medium)
                        .foregroundStyle(Color.dockSecondaryText)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(agents.count) helper\(agents.count == 1 ? "" : "s") working")
            .transition(.opacity)
        }
    }
}
