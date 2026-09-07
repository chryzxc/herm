import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers
struct VoiceWavePath: Shape {
    let t: Double
    var amplitude: Double = 12

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let base = min(rect.width, rect.height) / 2 - 14
        let points = 80
        for i in 0...points {
            let angle = Double(i) / Double(points) * .pi * 2
            let noise = sin(angle * 3 + t * 0.5) * 6
                       + sin(angle * 5 - t * 0.3) * 4
                       + sin(angle * 7 + t * 0.7) * 3
            let r = base + noise + sin(t + Double(i) * 0.2) * amplitude
            let x = cx + cos(angle) * r
            let y = cy + sin(angle) * r
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        return path
    }
}

struct StartupAssistantView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let agentName: String

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 12.0)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate

            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.dockSuccess)
                        .frame(width: 5, height: 5)
                        .shadow(color: Color.dockSuccess.opacity(0.8), radius: 5)
                    Text("\(agentName.uppercased()) // ONLINE")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(Color.dockAccent.opacity(0.85))
                }
                .padding(.top, 24)

                Spacer(minLength: 16)

                startupOrb(time: t)
                    .frame(width: 250, height: 250)

                Spacer(minLength: 14)

                VStack(spacing: 5) {
                    Text("Good to see you.")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("All systems nominal. How may I assist you?")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockSecondaryText)
                }
                .multilineTextAlignment(.center)

                HStack(spacing: 6) {
                    Capsule().fill(Color.dockAccent.opacity(0.35)).frame(width: 18, height: 1)
                    Text("AWAITING COMMAND")
                        .font(.system(size: 12, weight: .medium))
                        .tracking(1.25)
                        .foregroundStyle(Color.dockMetadataText)
                    Capsule().fill(Color.dockAccent.opacity(0.35)).frame(width: 18, height: 1)
                }
                .padding(.top, 15)
                .padding(.bottom, 22)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agentName) online. All systems nominal. Awaiting command.")
    }

    @ViewBuilder
    private func startupOrb(time t: TimeInterval) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.dockAccent.opacity(0.12), Color.dockAccent.opacity(0.025), .clear],
                        center: .center,
                        startRadius: 15,
                        endRadius: 122
                    )
                )
                .blur(radius: 5)

            ForEach(0..<3) { index in
                let phase = t * 0.72 + Double(index) * 1.75
                let scale = 0.94 + 0.045 * sin(phase)
                Circle()
                    .stroke(
                        Color.dockAccent.opacity(index == 1 ? 0.2 : 0.12),
                        style: StrokeStyle(lineWidth: index == 1 ? 0.7 : 0.5, dash: index == 1 ? [2, 5] : [])
                    )
                    .frame(width: CGFloat(158 + index * 35), height: CGFloat(158 + index * 35))
                    .scaleEffect(scale)
                    .opacity(0.5 + 0.25 * sin(phase))
            }

            Circle()
                .trim(from: 0.05, to: 0.28)
                .stroke(Color.dockAccent.opacity(0.75), style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                .frame(width: 212, height: 212)
                .rotationEffect(.degrees(t * 18))
            Circle()
                .trim(from: 0.57, to: 0.78)
                .stroke(Color.dockAccent.opacity(0.4), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                .frame(width: 212, height: 212)
                .rotationEffect(.degrees(-t * 12))

            ForEach(0..<18) { index in
                let angle = Double(index) / 18 * .pi * 2 + t * 0.18
                Circle()
                    .fill(Color.dockAccent.opacity(index.isMultiple(of: 3) ? 0.75 : 0.28))
                    .frame(width: index.isMultiple(of: 3) ? 2.5 : 1.5, height: index.isMultiple(of: 3) ? 2.5 : 1.5)
                    .offset(x: cos(angle) * 98, y: sin(angle) * 98)
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.26), Color.dockAccent.opacity(0.32), Color.dockAccent.opacity(0.07)],
                        center: UnitPoint(x: 0.35, y: 0.28),
                        startRadius: 1,
                        endRadius: 62
                    )
                )
                .frame(width: 116, height: 116)
                .overlay(Circle().stroke(Color.dockAccent.opacity(0.35), lineWidth: 0.7))
                .shadow(color: Color.dockAccent.opacity(0.24), radius: 20)
                .scaleEffect(1 + 0.025 * sin(t * 1.7))

            Circle()
                .trim(from: 0.08, to: 0.92)
                .stroke(Color.white.opacity(0.26), style: StrokeStyle(lineWidth: 0.5, lineCap: .round))
                .frame(width: 82, height: 82)
                .rotationEffect(.degrees(-t * 20))

            LucideImage(systemName: "audio-lines")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.dockAccent.opacity(0.9))
                .shadow(color: Color.dockAccent.opacity(0.7), radius: 8)

            Capsule()
                .fill(Color.dockAccent.opacity(0.55))
                .frame(width: 58, height: 0.8)
                .offset(y: 42)
                .scaleEffect(x: 0.7 + 0.3 * (sin(t * 2.2) + 1) / 2, y: 1)
        }
    }
}

struct VoiceOrbView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isListening: Bool
    let isResponding: Bool
    let audioLevel: CGFloat

    var body: some View {
        let isActive = isListening || isResponding
        if isActive && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                orb(time: context.date.timeIntervalSinceReferenceDate, isActive: true)
            }
        } else {
            // An idle or motion-reduced voice control must not keep the
            // display link alive; render one static active frame instead.
            orb(time: 0, isActive: isActive)
        }
    }

    private func orb(time animationTime: TimeInterval, isActive: Bool) -> some View {
            let voiceLevel = Double(audioLevel)
            let waveSpeed = isResponding ? 6.0 : (isListening ? 4.0 : 0)
            let waveAmplitude = isResponding ? 22.0 : (isListening ? 4.0 + voiceLevel * 26.0 : 0)
        return ZStack {
                ForEach(0..<4) { i in
                    let size = 140.0 + Double(i) * 60
                    Circle()
                        .stroke(
                            Color.dockAccent.opacity(i % 2 == 0 ? 0.08 : 0.05),
                            style: StrokeStyle(lineWidth: i % 2 == 0 ? 1 : 0.5, dash: i % 2 == 0 ? [] : [3, 4])
                    )
                    .frame(width: size, height: size)
                    .scaleEffect(1 + (isResponding ? 0.16 : 0.1) * sin(animationTime * (isResponding ? 1.5 : 0.8) + Double(i) * 0.5))
                    .opacity(isActive ? 0.25 + 0.15 * sin(animationTime * (isResponding ? 1.5 : 0.8) + Double(i) * 0.5) : 0.08)
                }

                ForEach(0..<48) { i in
                    let phase = (1 + sin(animationTime * waveSpeed + Double(i) * 0.4)) / 2
                    let barH = isResponding
                        ? 4 + waveAmplitude * phase
                        : (isListening ? 3 + waveAmplitude * (0.2 + 0.8 * phase) : 2)
                    Capsule()
                        .fill(Color.dockAccent)
                        .frame(width: 2, height: barH)
                        .offset(y: -92)
                        .rotationEffect(.degrees(Double(i) / 48 * 360))
                        .opacity(0.4)
                }

                VoiceWavePath(t: animationTime, amplitude: waveAmplitude)
                    .stroke(Color.dockAccent.opacity(isActive ? (isResponding ? 0.8 : 0.5) : 0.16), lineWidth: isResponding ? 2 : 1.5)
                    .frame(width: 200, height: 200)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.dockAccent.opacity(0.3), Color.dockAccent.opacity(0.12), Color.dockAccent.opacity(0.04)],
                            center: UnitPoint(x: 0.35, y: 0.35),
                            startRadius: 0,
                            endRadius: 55
                        )
                    )
                    .frame(width: 90, height: 90)
                    .overlay(Circle().stroke(Color.dockAccent.opacity(0.2), lineWidth: 0.5))
                    .shadow(color: Color.dockAccent.opacity(0.25), radius: 30)
                    .scaleEffect(
                        1 + (isResponding
                             ? 0.12 * sin(animationTime * .pi)
                             : (isListening ? 0.025 + voiceLevel * 0.1 : 0))
                    )
                    .overlay {
                        LucideImage(systemName: isResponding ? "waveform" : "audio-lines")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.dockAccent)
                            .scaleEffect(1 - 0.12 * (1 + sin(animationTime * .pi * 1.6)) / 2)
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

    private var placeholder: String {
        switch request.kind {
        case .comment: "Comment for Hermes"
        case .schedule: "Reason or timing note"
        case .assign, .reassign: "Profile name, or none to unassign"
        case .promote, .reclaim: "Audit reason"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.kind.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            Text(request.task.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.dockPrimaryText)
            TextField(placeholder, text: $value, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.dockGlass)
            if (request.kind == .assign || request.kind == .reassign), !assignees.isEmpty {
                Menu("Choose Hermes profile") {
                    ForEach(assignees, id: \.self) { assignee in
                        Button(assignee) { value = assignee }
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            }
            if request.kind == .reassign {
                Toggle("Reclaim active worker first", isOn: $reclaimFirst)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSecondaryText)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(request.kind.title) { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPending)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Color.dockCanvas)
        .confirmationDialog("Confirm Kanban change?", isPresented: $confirming) {
            Button(request.kind.title) {
                submit(KanbanMutationRequest(task: request.task, kind: request.kind, value: value, reclaimFirst: reclaimFirst))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will persist this \(request.kind.rawValue) change on ‘\(request.task.title)’. The Dock will refresh the authoritative task afterwards.")
        }
    }
}

struct CronEditEditor: View {
    let job: CronSummary
    let isPending: Bool
    let submit: (CronEditDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CronEditDraft
    @State private var confirming = false

    init(job: CronSummary, isPending: Bool, submit: @escaping (CronEditDraft) -> Void) {
        self.job = job
        self.isPending = isPending
        self.submit = submit
        _draft = State(initialValue: CronEditDraft(job: job))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EDIT SCHEDULED JOB")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            if job.editableFields.contains(.name) {
                TextField("Name", text: $draft.name).textFieldStyle(.dockGlass)
            }
            if job.editableFields.contains(.schedule) {
                TextField("Schedule", text: $draft.schedule).textFieldStyle(.dockGlass)
            }
            if job.editableFields.contains(.prompt), job.prompt != nil {
                TextField("Prompt", text: $draft.prompt, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.dockGlass)
            }
            Text("Only values supplied by Hermes are editable. Unchanged values are not sent.")
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save Changes") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.changes(comparedTo: job).filter { job.editableFields.contains($0.key) }.isEmpty || isPending)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Color.dockCanvas)
        .confirmationDialog("Save scheduled-job changes?", isPresented: $confirming) {
            Button("Save Changes") { submit(draft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            let fields = draft.changes(comparedTo: job).filter { job.editableFields.contains($0.key) }.keys.map(\.title).sorted().joined(separator: ", ")
            Text("Hermes will update \(fields) for ‘\(job.name)’. The scheduler remains authoritative.")
        }
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
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AUTOMATION REPORT")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Color.dockAccent)
                    Text(job.name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("\(CronScheduleFormatting.humanReadable(job.schedule))  ·  \(job.id)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                }
                Spacer(minLength: 12)
                if let report {
                    Button("COPY") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.markdown, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                }
                Button("DONE") { dismiss() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dockSecondaryText)
            }
            .padding(18)

            Divider().overlay(Color.dockBorderLight)

            Group {
                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("LOADING REPORT")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.dockMetadataText)
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
                        LucideImage(systemName: "exclamationmark.triangle")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.dockWarning)
                        Text(loadError ?? "The report could not be loaded.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockSecondaryText)
                            .multilineTextAlignment(.center)
                        Button("TRY AGAIN") { load() }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.dockAccent)
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 480, idealHeight: 620)
        .background(Color.dockCanvas)
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
                LucideImage(systemName: snapshot?.isGitRepository == true ? "arrow.triangle.branch" : "folder")
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
            .buttonStyle(.borderless)
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

enum DockCommand: Identifiable, CaseIterable {
    case tab(ControlTab)
    case newChat
    case focusComposer
    case stop
    case voice

    static var allCases: [DockCommand] {
        ControlTab.allCases.map(DockCommand.tab) + [.newChat, .focusComposer, .stop, .voice]
    }

    var id: String {
        switch self {
        case .tab(let tab): "tab.\(tab.rawValue)"
        case .newChat: "new-chat"
        case .focusComposer: "focus-composer"
        case .stop: "stop"
        case .voice: "voice"
        }
    }

    var title: String {
        switch self {
        case .tab(let tab): "Open \(tab.tabLabel)"
        case .newChat: "New chat"
        case .focusComposer: "Focus composer"
        case .stop: "Stop active request"
        case .voice: "Start voice"
        }
    }

    var icon: String {
        switch self {
        case .tab(let tab): tab.icon
        case .newChat: "message-circle-plus"
        case .focusComposer: "text.cursor"
        case .stop: "stop.circle"
        case .voice: "mic"
        }
    }
}

struct DockCommandPalette: View {
    let select: (DockCommand) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var commands: [DockCommand] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !needle.isEmpty else { return DockCommand.allCases }
        return DockCommand.allCases.filter { $0.title.localizedLowercase.contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("COMMAND PALETTE")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                Spacer()
                Text("⌘K")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockSecondaryText)
            }
            TextField("Search actions", text: $query)
                .textFieldStyle(.dockGlass)
            ForEach(commands) { command in
                Button {
                    select(command)
                    dismiss()
                } label: {
                    LucideLabel(command.title, icon: command.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.dockPrimaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Color.dockCanvas)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("COMMAND CENTER")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockAccent)
                Spacer()
                Text("⌘K").font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
            }
            TextField("Search actions", text: $query)
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
                                LucideImage(systemName: command.icon).frame(width: 16)
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
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!command.isAvailable)
                    }
                }
            }
            .frame(maxHeight: 350)
        }
        .padding(20)
        .frame(width: 460)
        .background(Color.dockCanvas)
    }
}
