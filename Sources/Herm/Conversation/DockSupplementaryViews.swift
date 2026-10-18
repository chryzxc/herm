import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers
struct StartupAssistantView: View {
    var onSuggestion: (String) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private static let suggestions: [(icon: String, text: String)] = [
        ("doc.text.magnifyingglass", "Summarize this project"),
        ("checklist", "Review my recent changes"),
        ("lightbulb", "Plan a new feature"),
    ]

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            // The voice orb at rest, scaled down: chat and voice share one visual language.
            VoiceOrbView(mode: .idle, audioLevel: 0)
                .frame(width: 300, height: 300)
                .scaleEffect(0.5)
                .frame(width: 150, height: 150)
            Text("What can I help with?")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Text("Ask a question, give it a task, or attach files and folders.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
            HStack(spacing: 8) {
                ForEach(Array(Self.suggestions.enumerated()), id: \.offset) { index, item in
                    StartupSuggestionChip(icon: item.icon, text: item.text) { onSuggestion(item.text) }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8).delay(0.25 + Double(index) * 0.08), value: appeared)
                }
            }
            .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 6)
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { appeared = true } }
    }
}

private struct StartupSuggestionChip: View {
    let icon: String
    let text: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovering ? Color.dockAccent : Color.dockSecondaryText)
                    .scaleEffect(isHovering ? 1.12 : 1)
                Text(text)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isHovering ? Color.dockPrimaryText : Color.dockSecondaryText)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.dockAccent.opacity(isHovering ? 0.12 : 0.05)))
            .overlay(Capsule().stroke(Color.dockAccent.opacity(isHovering ? 0.35 : 0.12), lineWidth: 0.7))
            .shadow(color: Color.dockAccent.opacity(isHovering ? 0.25 : 0), radius: 10)
            .offset(y: isHovering ? -2 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) { isHovering = hovering }
        }
    }
}

enum VoiceOrbMode: Equatable {
    case idle, listening, transcribing, thinking, speaking
}

/// Eases every orb parameter toward its per-mode target each frame, so state
/// changes read as one continuous motion instead of snapping. A reference type
/// held in `@State`: mutating it from the timeline must not invalidate the view.
final class VoiceOrbMotion {
    struct Frame {
        var energy = 0.04
        var glow = 0.15
        var scan = 0.0
        var spin = 0.1
        var rotation = 0.0
        /// Pointer interaction: 0 away ... 1 hovering, lean in unit coords, ripple 0 ... 1 age.
        var hover = 0.0
        var leanX = 0.0
        var leanY = 0.0
        var ripple = 1.0
    }

    private(set) var frame = Frame()
    private var lastTime: TimeInterval?
    /// Written by hover/tap handlers; read on the next frame.
    var pointer: CGPoint?
    var rippleStart: TimeInterval?

    func advance(to time: TimeInterval, mode: VoiceOrbMode, level: Double) -> Frame {
        let dt = min(max(time - (lastTime ?? time), 0), 0.1)
        lastTime = time
        var target = Self.target(mode: mode, level: level, time: time)
        // ~160ms time constant; the level already arrives smoothed.
        let k = 1 - exp(-dt * 6.5)
        let hoverTarget = pointer == nil ? 0.0 : 1.0
        frame.hover += (hoverTarget - frame.hover) * (1 - exp(-dt * 9))
        frame.leanX += ((pointer.map { Double($0.x) } ?? 0) - frame.leanX) * (1 - exp(-dt * 8))
        frame.leanY += ((pointer.map { Double($0.y) } ?? 0) - frame.leanY) * (1 - exp(-dt * 8))
        frame.ripple = rippleStart.map { min(1, (time - $0) / 0.9) } ?? 1
        // Hover wakes the orb a little; a tap kicks it.
        target.energy += frame.hover * 0.1 + (1 - frame.ripple) * 0.35
        target.glow += frame.hover * 0.2
        target.spin += frame.hover * 0.25
        frame.energy += (target.energy - frame.energy) * k
        frame.glow += (target.glow - frame.glow) * k
        frame.scan += (target.scan - frame.scan) * k
        frame.spin += (target.spin - frame.spin) * k
        frame.rotation = (frame.rotation + frame.spin * dt).truncatingRemainder(dividingBy: .pi * 2)
        return frame
    }

    static func target(mode: VoiceOrbMode, level: Double, time: TimeInterval) -> Frame {
        switch mode {
        case .idle:
            return Frame(energy: 0.04, glow: 0.15, scan: 0, spin: 0.1)
        case .listening:
            return Frame(energy: 0.1 + level * 0.9, glow: 0.3 + level * 0.6, scan: 0, spin: 0.15)
        case .transcribing:
            return Frame(energy: 0.28, glow: 0.55, scan: 1, spin: 2.4)
        case .thinking:
            return Frame(energy: 0.32, glow: 0.5, scan: 0.75, spin: 1.1)
        case .speaking:
            // A syllable-rate envelope stands in for Hermes' speaker output,
            // which the gateway does not stream back to clients.
            let syllables = abs(sin(time * 6.3)) * (0.6 + 0.4 * sin(time * 1.7 + 1))
            return Frame(energy: 0.35 + syllables * 0.5, glow: 0.65, scan: 0.2, spin: 0.4)
        }
    }
}

struct VoiceOrbView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: VoiceOrbMode
    let audioLevel: CGFloat
    @State private var motion = VoiceOrbMotion()
    @State private var isHovering = false

    var body: some View {
        if reduceMotion {
            orb(VoiceOrbMotion.target(mode: mode, level: Double(audioLevel), time: 0), time: 0)
        } else {
            // Idle keeps a slow breathing cadence unless the pointer is engaging it.
            GeometryReader { proxy in
                TimelineView(.animation(minimumInterval: mode == .idle && !isHovering ? 1.0 / 15.0 : 1.0 / 60.0)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    orb(motion.advance(to: time, mode: mode, level: Double(audioLevel)), time: time)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        // Normalised -1 ... 1 from the centre, clamped to the orb.
                        let half = max(min(proxy.size.width, proxy.size.height) / 2, 1)
                        let x = (location.x - proxy.size.width / 2) / half
                        let y = (location.y - proxy.size.height / 2) / half
                        let length = max(1, hypot(x, y))
                        motion.pointer = CGPoint(x: x / length, y: y / length)
                        if !isHovering { isHovering = true }
                    case .ended:
                        motion.pointer = nil
                        isHovering = false
                    }
                }
                .simultaneousGesture(TapGesture().onEnded {
                    motion.rippleStart = Date().timeIntervalSinceReferenceDate
                })
            }
        }
    }

    private func orb(_ frame: VoiceOrbMotion.Frame, time: TimeInterval) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [Color.dockAccent.opacity(0.08 + frame.glow * 0.14), .clear],
                    center: .center, startRadius: 30, endRadius: 160
                ))
                .scaleEffect(1 + frame.energy * 0.08)

            Canvas { context, size in
                Self.drawField(in: &context, size: size, frame: frame, time: time)
            }

            Circle()
                .fill(RadialGradient(
                    colors: [Color.white.opacity(0.10 + frame.glow * 0.12), Color.dockAccent.opacity(0.28), Color.dockAccent.opacity(0.06)],
                    center: UnitPoint(x: 0.36, y: 0.3), startRadius: 1, endRadius: 58
                ))
                .overlay(Circle().stroke(Color.dockAccent.opacity(0.2 + frame.glow * 0.3), lineWidth: 0.7))
                .frame(width: 92, height: 92)
                .shadow(color: Color.dockAccent.opacity(0.15 + frame.glow * 0.35), radius: 14 + frame.glow * 24)
                .scaleEffect(1 + frame.energy * 0.1 + 0.015 * sin(time * 1.6))
                // The core drifts toward the pointer like it is paying attention.
                .offset(x: frame.leanX * 9 * frame.hover, y: frame.leanY * 9 * frame.hover)
                .overlay {
                    VoiceCoreBars(heights: VoiceCoreBars.heights(mode: mode, level: Double(audioLevel), time: time))
                        .foregroundStyle(Color.dockAccent.opacity(0.7 + frame.glow * 0.3))
                }
        }
        .animation(.dockEase(duration: 0.3), value: mode)
    }

    /// Rings, ticks, scanner arcs, and the voice membrane. Every angular term
    /// uses an integer harmonic so the shapes close without a seam.
    private static func drawField(in context: inout GraphicsContext, size: CGSize, frame: VoiceOrbMotion.Frame, time: TimeInterval) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let accent = Color.dockAccent

        // Tap ripple: two rings expanding out of the core.
        if frame.ripple < 1 {
            for delay in [0.0, 0.18] {
                let age = max(0, (frame.ripple - delay) / (1 - delay))
                guard age > 0, age < 1 else { continue }
                let radius = 50 + age * 110
                let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.stroke(ring, with: .color(accent.opacity(0.5 * (1 - age))), lineWidth: 1.5 * (1 - age) + 0.4)
            }
        }

        for (radius, opacity) in [(150.0, 0.07), (128.0, 0.05)] {
            let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(accent.opacity(opacity + frame.glow * 0.05)), style: StrokeStyle(lineWidth: 0.6, dash: radius > 140 ? [] : [2, 6]))
        }

        // Scanner arcs sweep while Hermes transcribes or thinks.
        if frame.scan > 0.01 {
            for (offset, length, width) in [(0.0, 0.9, 1.6), (.pi, 0.55, 1.0)] {
                var arc = Path()
                let start = frame.rotation + offset
                arc.addArc(center: center, radius: 112, startAngle: .radians(start), endAngle: .radians(start + length), clockwise: false)
                context.stroke(arc, with: .color(accent.opacity(0.75 * frame.scan)), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }

        let ticks = 72
        for index in 0..<ticks {
            let angle = Double(index) / Double(ticks) * .pi * 2
            let wave = 0.5 + 0.5 * sin(angle * 4 + time * 3.1) * cos(angle * 3 - time * 1.9)
            let length = 2.5 + frame.energy * 20 * wave
            let sweep = pow(max(0, cos(angle - frame.rotation - 0.45)), 10) * frame.scan
            // Ticks facing the pointer stretch and brighten.
            let pointerAngle = atan2(frame.leanY, frame.leanX)
            let attention = pow(max(0, cos(angle - pointerAngle)), 8) * frame.hover * min(1, hypot(frame.leanX, frame.leanY) * 1.5)
            let tickLength = length + attention * 10
            var tick = Path()
            tick.move(to: CGPoint(x: center.x + cos(angle) * 96, y: center.y + sin(angle) * 96))
            tick.addLine(to: CGPoint(x: center.x + cos(angle) * (96 + tickLength), y: center.y + sin(angle) * (96 + tickLength)))
            context.stroke(tick, with: .color(accent.opacity(0.22 + frame.energy * 0.35 + sweep * 0.5 + attention * 0.45)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        for (phase, width, opacity) in [(0.0, 1.6, 0.75), (2.1, 0.8, 0.35)] {
            context.stroke(
                membrane(center: center, radius: 76, frame: frame, time: time + phase),
                with: .color(accent.opacity(opacity * (0.35 + frame.glow * 0.65))),
                lineWidth: width
            )
        }
    }

    private static func membrane(center: CGPoint, radius: Double, frame: VoiceOrbMotion.Frame, time: TimeInterval) -> Path {
        var path = Path()
        let points = 120
        for index in 0...points {
            let angle = Double(index) / Double(points) * .pi * 2
            let ripple = sin(angle * 3 + time * 1.3) * 0.5 + sin(angle * 5 - time * 1.9) * 0.3 + sin(angle * 7 + time * 2.7) * 0.2
            let r = radius + 1.5 * sin(angle * 2 + time * 0.6) + frame.energy * 16 * ripple
            let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// The orb core's voice line: bars that pulse while the agent talks and
/// follow the mic while it listens.
struct VoiceCoreBars: View {
    /// Per-bar height, 0 flat ... 1 full.
    let heights: [Double]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule().frame(width: 4, height: 3 + 30 * heights[index])
            }
        }
        .frame(height: 34)
        .accessibilityHidden(true)
    }

    static func heights(mode: VoiceOrbMode, level: Double, time: TimeInterval) -> [Double] {
        // Centre bars run tallest so the line reads as a voice, not a meter.
        let shape = [0.45, 0.75, 1.0, 0.75, 0.45]
        return shape.indices.map { index in
            let phase = Double(index) * 1.3
            switch mode {
            case .idle:
                return 0
            case .listening:
                return shape[index] * min(1, level * 1.4) * (0.75 + 0.25 * sin(time * 9 + phase))
            case .transcribing, .thinking:
                // A slow travelling ripple while Hermes works.
                return 0.18 * max(0, sin(time * 4 - phase))
            case .speaking:
                // Hermes plays TTS itself and does not stream its audio back, so
                // the bars follow a syllable-like envelope, not the real audio.
                let syllables = sin(time * 7.3 + phase) * 0.5 + sin(time * 11.9 + phase * 2) * 0.3 + sin(time * 3.1) * 0.35
                let phrasePause = sin(time * 0.8) > -0.75 ? 1.0 : 0.1
                return shape[index] * min(1, max(0.08, syllables + 0.35)) * phrasePause
            }
        }
    }
}

struct MicWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool

    var body: some View {
        if isActive && !reduceMotion {
            TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { context in
                waveform(at: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            waveform(at: 0)
        }
    }

    private func waveform(at time: TimeInterval) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let phase = time * 4 + Double(index) * 0.8
                Capsule()
                    .frame(width: 2, height: isActive ? 5 + CGFloat(abs(sin(phase)) * 13) : 3)
            }
        }
        .foregroundStyle(Color.dockAccent)
        .frame(width: 28, height: 28)
    }
}

struct KanbanMutationEditor: View {
    let request: KanbanMutationRequest
    let assignees: [String]
    let isPending: Bool
    let submit: (KanbanMutationRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var reclaimFirst = false
    @State private var confirming = false

    init(request: KanbanMutationRequest, assignees: [String], isPending: Bool, submit: @escaping (KanbanMutationRequest) -> Void) {
        self.request = request
        self.assignees = assignees
        self.isPending = isPending
        self.submit = submit
        _value = State(initialValue: request.value)
        _reclaimFirst = State(initialValue: request.reclaimFirst)
    }

    private var placeholder: String {
        switch request.kind {
        case .comment: "Comment for Hermes"
        case .schedule: "Reason or timing note"
        case .assign, .reassign: "Profile name, or none to unassign"
        case .promote, .reclaim: "Audit reason"
        }
    }

    var body: some View {
        DockModal(icon: .kanban, title: request.kind.title, subtitle: request.task.title, width: 440) {
            TextField(placeholder, text: $value, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.dockGlass)
            if (request.kind == .assign || request.kind == .reassign), !assignees.isEmpty {
                DockMenu {
                    ForEach(assignees, id: \.self) { assignee in
                        Button(assignee) { value = assignee }
                    }
                } label: {
                    DockIconLabel("Choose Hermes profile", icon: .caretDown)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockAccent)
                }
                .fixedSize()
            }
            if request.kind == .reassign {
                Toggle("Reclaim active worker first", isOn: $reclaimFirst)
                    .toggleStyle(.dockSwitch)
                    .font(.system(size: 12))
            }
        } footer: {
            modalActions(primaryTitle: request.kind.title, pendingTitle: "Saving…", isDisabled: value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPending, isPending: isPending, onCancel: { dismiss() }) {
                confirming = true
            }
        }
        .confirmationDialog("Confirm Kanban change?", isPresented: $confirming) {
            Button(request.kind.title) {
                submit(KanbanMutationRequest(task: request.task, kind: request.kind, value: value, reclaimFirst: reclaimFirst))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will persist this \(request.kind.rawValue) change on ‘\(request.task.title)’. Herm will refresh the authoritative task afterwards.")
        }
    }
}

struct CronConfigurationFields: View {
    @Binding var draft: CronConfigurationDraft
    var isScriptOnly = false

    var body: some View {
        DisclosureGroup("Configuration") {
            VStack(alignment: .leading, spacing: 12) {
                labeledField("Delivery", hint: "local or a configured Hermes delivery target") {
                    DockTextField("local", text: $draft.delivery).textFieldStyle(.dockGlass)
                }
                labeledField("Working directory", hint: "Directory on the Hermes backend; blank uses its default") {
                    DockTextField("Default directory", text: $draft.workdir).textFieldStyle(.dockGlass)
                }
                if !isScriptOnly {
                    HStack(alignment: .top, spacing: 12) {
                        labeledField("Model override") {
                            DockTextField("Default model", text: $draft.model).textFieldStyle(.dockGlass)
                        }
                        labeledField("Provider") {
                            DockTextField("Default provider", text: $draft.provider).textFieldStyle(.dockGlass)
                        }
                    }
                }
            }.padding(.top, 8)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.dockSecondaryText)
    }
}

struct CronEditEditor: View {
    let job: CronSummary
    @ObservedObject var control: ControlCenterModel
    @Environment(\.dismiss) private var dismiss
    @State private var loadedJob: CronSummary?
    @State private var loadedBindingGeneration: UInt64?
    @State private var draft: CronEditDraft
    @State private var confirming = false
    @State private var isSaving = false
    @State private var error: String?
    @State private var isLoading = true

    init(job: CronSummary, control: ControlCenterModel) {
        self.job = job
        self.control = control
        _draft = State(initialValue: CronEditDraft(job: job))
    }

    var body: some View {
        DockModal(icon: .clock, title: "Edit automation", subtitle: job.name, width: 520) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isLoading {
                        ProgressView("Loading automation details…").controlSize(.small)
                    }
                    Group {
                        labeledField("Name") {
                            DockTextField("Name", text: $draft.name).textFieldStyle(.dockGlass)
                        }
                        labeledField("Schedule", hint: "every 2h · 0 9 * * *") {
                            DockTextField("Schedule", text: $draft.schedule).textFieldStyle(.dockGlass)
                        }
                        if loadedJob?.details.noAgent != true {
                            labeledField("Request") {
                                DockTextField("Request", text: $draft.prompt, axis: .vertical)
                                    .lineLimit(3...6).textFieldStyle(.dockGlass)
                            }
                        }
                        CronConfigurationFields(draft: $draft.configuration, isScriptOnly: loadedJob?.details.noAgent == true)
                    }.disabled(loadedJob == nil || isSaving)
                    if let error { ModalNote(text: error, icon: .warning, tone: .dockWarning) }
                    if !isLoading, loadedJob == nil {
                        Button("Retry loading details") { Task { await load() } }.buttonStyle(.dockCompact)
                    }
                }
            }.frame(height: 400)
        } footer: {
            modalActions(primaryTitle: "Save changes", isDisabled: loadedJob == nil || draft.changes(comparedTo: loadedJob ?? job).isEmpty || isSaving, isPending: isSaving, onCancel: { dismiss() }) {
                confirming = true
            }
        }
        .task { await load() }
        .interactiveDismissDisabled(isSaving)
        .confirmationDialog("Save automation changes?", isPresented: $confirming) {
            Button("Save changes") {
                guard let loadedJob, !isSaving else { return }
                guard loadedBindingGeneration == control.clientBindingGeneration else {
                    error = "The Hermes connection changed. Close this editor and reopen the automation."
                    return
                }
                isSaving = true
                Task {
                    if await control.editCron(loadedJob, draft: draft) { dismiss() }
                    else { error = control.lastError ?? "Hermes could not save this automation." }
                    isSaving = false
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @MainActor private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let bindingGeneration = control.clientBindingGeneration
        do {
            let detail = try await control.loadCronDetail(job)
            guard !Task.isCancelled, bindingGeneration == control.clientBindingGeneration else { return }
            loadedBindingGeneration = bindingGeneration
            loadedJob = detail
            draft = CronEditDraft(job: detail)
        } catch { self.error = ControlCenterModel.safeUserDiagnostic(error.localizedDescription) }
    }
}

struct CronReportDetailSheet: View {
    let request: CronReportRequest
    @ObservedObject var control: ControlCenterModel
    @Environment(\.dismiss) private var dismiss
    @State private var report: CronReportDetail?
    @State private var loadError: String?
    @State private var isLoading = true

    private var job: CronSummary { request.job }

    var body: some View {
        DockModal(
            icon: .fileText,
            title: job.name,
            subtitle: "\(CronScheduleFormatting.humanReadable(job.schedule))  ·  \(job.id)",
            width: nil,
            contentPadding: 0
        ) {
            Group {
                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading report…")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let report {
                    ScrollView {
                        MarkdownMessageView(markdown: report.markdown)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                } else {
                    VStack(spacing: 10) {
                        DockIcon(.warning)
                            .font(.system(size: 22))
                            .foregroundStyle(Color.dockWarning)
                        Text(loadError ?? "The report could not be loaded.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockSecondaryText)
                            .multilineTextAlignment(.center)
                        Button("Try Again") { load() }
                            .buttonStyle(.dockSecondary)
                            .controlSize(.small)
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } footer: {
            Spacer()
            if let report {
                DockCopyButton(
                    report.markdown,
                    label: "Copy Markdown",
                    accessibilityLabel: "Copy Markdown",
                    iconSize: 16
                )
                .buttonStyle(.dockSecondary)
            }
            Button("Done") { dismiss() }
                .buttonStyle(.dockPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 480, idealHeight: 620)
        .task(id: request.sessionID) { await loadReport() }
    }

    private func load() {
        Task { await loadReport() }
    }

    @MainActor
    private func loadReport() async {
        isLoading = true
        loadError = nil
        do {
            report = try await control.cronReport(for: request)
        } catch {
            report = nil
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

struct RepositoryFleetRow: View {
    let path: String
    let activePath: String?
    let select: (String) -> Void
    @State private var snapshot: RepositorySnapshot?
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                DockIcon(snapshot?.isGitRepository == true ? .gitBranch : .folder)
                    .foregroundStyle(snapshot?.isGitRepository == true ? Color.dockSuccess : Color.dockSecondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockPrimaryText)
                    Text(snapshot?.branch ?? "Inspecting…")
                        .font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                }
                Spacer()
                if isRefreshing { ProgressView().controlSize(.small) }
                if path == activePath { Text("ACTIVE").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dockAccent) }
            }
            if let snapshot, snapshot.isGitRepository {
                Text("\(snapshot.changedFiles) changed · \(snapshot.aheadCount.map(String.init) ?? "—") ahead · \(snapshot.behindCount.map(String.init) ?? "—") behind")
                    .font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                if let operation = snapshot.operation { Text(operation.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dockWarning) }
            }
            HStack(spacing: 12) {
                Button("SELECT") { select(path) }
                Button("REFRESH") { Task { await refresh() } }
            }
            .buttonStyle(.dockCompact)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.dockAccent)
        }
        .dockListRow()
        .task { await refresh() }
    }

    private func refresh() async {
        isRefreshing = true
        snapshot = await RepositoryService.inspect(path: path)
        isRefreshing = false
    }
}

struct DockActionPalette: View {
    let repositoryAvailable: Bool
    let isWorking: Bool
    let select: (DockAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @StateObject private var preferences = CommandCenterPreferencesStore()

    private var commands: [DockActionDescriptor] {
        let descriptors = DockActionRegistry.make(repositoryAvailable: repositoryAvailable, isWorking: isWorking)
        return DockActionRegistry.search(query, descriptors: descriptors, recentIDs: preferences.recentActionIDs)
    }

    var body: some View {
        DockModal(icon: .command, title: "Command Center", subtitle: "Search actions  ·  ⌘K", width: 480, contentPadding: 16) {
            DockTextField("Search actions", text: $query)
                .textFieldStyle(.dockGlass)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(commands) { command in
                        Button {
                            guard command.isAvailable else { return }
                            preferences.recordAction(command.id)
                            select(command.action)
                            dismiss()
                        } label: {
                            HStack(spacing: 9) {
                                DockIcon(command.icon).frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(command.title).font(.system(size: 13, weight: .medium))
                                    Text(command.isAvailable ? command.subtitle : (command.unavailableReason ?? command.subtitle))
                                        .font(.system(size: 11)).lineLimit(1)
                                }
                                Spacer()
                                Text(command.category.uppercased()).font(.system(size: 10))
                            }
                            .foregroundStyle(command.isAvailable ? Color.dockPrimaryText : Color.dockMetadataText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockPress)
                        .disabled(!command.isAvailable)
                    }
                }
            }
            .frame(maxHeight: 350)
        }
    }
}
