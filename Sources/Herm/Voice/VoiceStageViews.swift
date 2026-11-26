import SwiftUI

/// Observes only the meter readings, so per-buffer level changes redraw the
/// orb and not the whole surface around it. Shared by the Talk tab and the notch.
struct VoiceMeteredOrb: View {
    let mode: VoiceOrbMode
    @ObservedObject var speech: VoiceMeterReading
    @ObservedObject var mic: VoiceMeterReading
    let showsRing: Bool
    let hermFaceID: String?

    var body: some View {
        VoiceOrbView(mode: mode, audioLevel: max(speech.level, mic.level), hermFaceID: hermFaceID)
            .frame(width: 320, height: 320)
            .overlay {
                if showsRing { VoiceListeningRing(progress: mic.turnProgress).dockPadding(36) }
            }
    }
}

extension VoiceStagePresentation {
    var statusTint: Color {
        voiceState == .listening ? .dockSuccess : voiceState == .paused ? .dockMetadataText : .dockAccent
    }
}

/// Icon and title for voice call controls; a tint marks an off or destructive state on the icon.
struct VoiceControlLabel: View {
    let title: String
    let icon: Ph
    var tint: Color?

    var body: some View {
        HStack(spacing: 6) {
            DockIcon(icon, size: 13, color: tint)
            Text(title)
        }
    }
}

/// Mute mic and Mute replies for a native voice conversation, shared by the Talk tab and the notch.
struct VoiceMuteControls: View {
    let model: DockModel
    /// Redraws on voice changes only; the body still reads the model.
    @ObservedObject private var stage: VoiceStageState

    init(model: DockModel) {
        self.model = model
        _stage = ObservedObject(wrappedValue: model.voiceStage)
    }

    var body: some View {
        Button(action: model.toggleVoiceMicMuted) {
            VoiceControlLabel(
                title: model.isVoiceMicMuted ? "Unmute mic" : "Mute mic",
                icon: model.isVoiceMicMuted ? .microphoneSlash : .microphone,
                tint: model.isVoiceMicMuted ? .dockWarning : nil)
        }
        .buttonStyle(.dockSecondary)
        Button(action: model.toggleVoiceReplies) {
            VoiceControlLabel(
                title: model.voiceRepliesEnabled ? "Mute replies" : "Speak replies",
                icon: model.voiceRepliesEnabled ? .speakerSimpleHigh : .speakerSimpleSlash,
                tint: model.voiceRepliesEnabled ? nil : .dockWarning)
        }
        .buttonStyle(.dockSecondary)
    }
}

/// Liquid light around a glass edge: a soft gradient rim that drifts around the
/// shape and swells with the voice level, the way Siri lights a Mac's glass.
/// Reduce Motion holds the rim still and steady.
struct VoiceWaveHalo<S: InsettableShape>: View {
    let shape: S
    @ObservedObject var level: VoiceMeterReading
    var tint: Color = .dockAccent
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.dockMotion(paused: reduceMotion || !active)) { context in
            let loud = active && !reduceMotion ? Double(level.level) : 0
            let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate * 40
            let light = AngularGradient(
                colors: [tint, DockAccentColor.violet.fill, DockAccentColor.cyan.fill, tint],
                center: .center, angle: .degrees(turn))
            ZStack {
                shape.strokeBorder(light, lineWidth: 6 + 10 * loud)
                    .blur(radius: 10 + 12 * loud)
                    .opacity(active ? 0.35 + 0.55 * loud : 0.1)
                shape.strokeBorder(light, lineWidth: 1.2).opacity(active ? 0.75 : 0.25)
            }
            .animation(.smooth(duration: 0.18), value: loud)
        }
        .allowsHitTesting(false)
    }
}

/// The reply's generative UI as a floating card, shared by Talk and the notch.
struct VoiceGenerativeCard: View {
    let model: DockModel
    let message: ChatMessage
    let maxWidth: CGFloat
    let floating: Bool
    let maxHeight: CGFloat
    @ObservedObject private var stage: VoiceStageState
    @State private var contentHeight: CGFloat = 0

    init(
        model: DockModel, message: ChatMessage, maxWidth: CGFloat, floating: Bool = true, maxHeight: CGFloat = .infinity
    ) {
        self.model = model
        self.message = message
        self.maxWidth = maxWidth
        self.floating = floating
        self.maxHeight = maxHeight
        _stage = ObservedObject(wrappedValue: model.voiceStage)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DockLayout.paneRadius + 8, style: .continuous)
        let position = model.voicePreviewPosition(for: message.id)
        let preview = VoicePassiveVisual.preview(message.text)
        let context = preview.map { RichVoiceContext(preview: $0, position: position) }
        let hint = preview?.hint(at: position)
        let anchor = preview?.comparison.flatMap { comparison in
            position.option.map { RichVoicePreview.OptionAnchor(block: comparison.key, index: $0) }
        }
        // Voice already speaks and captions the summary. Every glance shows just its visuals.
        let streaming = model.liveVoiceVisual == message
        let media = streaming ? [] : VoiceReplyMedia.items(in: message)
        let content = VStack(alignment: .leading, spacing: DockSpacing.group) {
            ForEach(media) { item in
                VoiceReplyMediaView(item: item)
            }
            if let preview, preview.isVisual {
                // Layout uses the same parsed visuals as navigation, including on the first final frame.
                RichDocumentView(document: preview.document, visualsOnly: true, readOnlySurfaces: streaming)
                    .generativeUIMessage(model: model, message: message)
                    .environment(\.richGlance, true)
                    .environment(\.richVoiceContext, context)
                    .textSelection(.enabled)
            }
        }

        if floating {
            VStack(alignment: .leading, spacing: 0) {
                ViewThatFits(in: .vertical) {
                    content.fixedSize(horizontal: false, vertical: true)
                    previewScroll(to: anchor) { content }
                }
                if let hint { VoicePreviewHint(text: hint) }
            }
            .dockPadding(18)
            .frame(maxWidth: maxWidth)
            .clipShape(shape)
            .dockFloatingSurface(shape, stroke: Color.dockBorderLight)
            .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
        } else {
            let available = max(1, maxHeight - (hint == nil ? 0 : 44))
            VStack(alignment: .leading, spacing: 0) {
                previewScroll(to: anchor) {
                    content
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            contentHeight = $0
                        }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .frame(height: min(max(contentHeight, 1), available))
                if let hint { VoicePreviewHint(text: hint) }
            }
            .frame(maxWidth: maxWidth)
        }
    }

    private func previewScroll<Content: View>(
        to anchor: RichVoicePreview.OptionAnchor?, @ViewBuilder content: () -> Content
    ) -> some View {
        let body = content()
        return ScrollViewReader { scroll in
            ScrollView { body }
                .scrollIndicators(.visible, axes: .vertical)
                .onChange(of: anchor) { _, anchor in
                    if let anchor { scroll.scrollTo(anchor, anchor: .center) }
                }
        }
    }
}

/// Sized like a generated preview, but shows only the current question's real choices.
struct VoiceClarificationChoices: View {
    let preview: VoiceClarificationPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Options").dockFont(.rowTitle, weight: .semibold)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: DockSpacing.control)
                    if let progress = preview.progress {
                        Text(progress).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                    }
                }
                .dockPadding(.horizontal, DockSpacing.group)
                .dockPadding(.vertical, DockSpacing.control)
                Divider().overlay(Color.dockBorderLight)
                ViewThatFits(in: .vertical) {
                    rows.fixedSize(horizontal: false, vertical: true)
                    ScrollView { rows }.scrollIndicators(.visible)
                }
                .frame(maxHeight: 220)
            }
            .dockWell(.sunken, role: .pane)
            if let hint = preview.hint { VoicePreviewHint(text: hint) }
        }
        .id(preview.key)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(preview.choices.enumerated()), id: \.offset) { index, choice in
                if index > 0 { Divider().overlay(Color.dockBorderLight) }
                HStack(alignment: .firstTextBaseline, spacing: DockSpacing.control) {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(Color.dockSecondaryText)
                        .accessibilityHidden(true)
                    Text(verbatim: choice).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Option \(index + 1), \(choice)")
                }
                .dockFont(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dockPadding(.vertical, DockSpacing.control)
            }
        }
        .dockPadding(.horizontal, DockSpacing.group)
    }
}

struct VoicePreviewHint: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DockSpacing.control) {
            Divider().overlay(Color.dockBorderLight)
            HStack(alignment: .firstTextBaseline, spacing: DockSpacing.tight) {
                DockIcon(.microphone, size: 12).accessibilityHidden(true)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .dockFont(.metadata)
            .foregroundStyle(Color.dockSecondaryText)
        }
        .dockPadding(.top, DockSpacing.group)
    }
}

/// Says what voice read from the front app for this request, so sharing is never silent.
struct VoiceScreenChip: View {
    let context: VoiceScreenContext

    var body: some View {
        HStack(spacing: 4) {
            DockIcon(.eye, size: 11)
            Text("Seeing \(context.label)")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .dockFont(size: 11, weight: .medium)
        .foregroundStyle(Color.dockSecondaryText)
        .dockPill()
        .help(context.sharedSummary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice can see \(context.label) for this request")
    }
}
