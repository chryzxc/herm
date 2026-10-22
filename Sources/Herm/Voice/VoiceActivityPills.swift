import SwiftUI

/// Short-lived activity cards around the voice orb. At most `capacity` are
/// visible; a new card replaces the oldest, and each fades out after its
/// lifetime, so the stage never piles up.
struct VoicePillQueue: Equatable {
    enum Tone: Equatable { case accent, success, warning, danger }

    struct Pill: Identifiable, Equatable {
        let id: String
        var icon: Ph
        var title: String
        var detail: String?
        var isRunning: Bool
        var tone: Tone
        /// A URL or file path the card opens when clicked.
        var target: String?
        var slot: Int
        var expiresAt: Date
    }

    static let capacity = 3
    static let slotCount = 4
    static let lifetime: TimeInterval = 7
    /// Clickable cards stay long enough to reach for.
    static let targetLifetime: TimeInterval = 15

    private(set) var pills: [Pill] = []
    private var nextSlot = 0

    /// Re-pushing an existing `key` updates that card in place and extends it.
    /// `slots` limits where a new card may sit, e.g. to keep a side free.
    mutating func push(key: String, icon: Ph, title: String, detail: String?, isRunning: Bool = false,
                       tone: Tone = .accent, target: String? = nil, slots: [Int] = Array(0..<slotCount), now: Date = .now) {
        let slots = Array(Set(slots.filter { (0..<Self.slotCount).contains($0) })).sorted()
        expire(now: now)
        restrict(to: slots)
        guard !slots.isEmpty else { return }
        let expiresAt = now.addingTimeInterval(target == nil ? Self.lifetime : Self.targetLifetime)
        if let index = pills.firstIndex(where: { $0.id == key }) {
            pills[index].icon = icon
            pills[index].title = title
            pills[index].detail = detail
            pills[index].isRunning = isRunning
            pills[index].tone = tone
            pills[index].target = target
            pills[index].expiresAt = expiresAt
            return
        }
        if pills.count >= min(Self.capacity, slots.count) { pills.removeFirst() }
        let used = Set(pills.map(\.slot))
        let slot = (0..<Self.slotCount).map { (nextSlot + $0) % Self.slotCount }
            .first { slots.contains($0) && !used.contains($0) } ?? slots.first ?? nextSlot
        nextSlot = (slot + 1) % Self.slotCount
        pills.append(Pill(id: key, icon: icon, title: title, detail: detail, isRunning: isRunning,
                          tone: tone, target: target, slot: slot, expiresAt: expiresAt))
    }

    mutating func expire(now: Date = .now) {
        pills.removeAll { $0.expiresAt <= now }
    }

    /// Keep the newest cards and move them into distinct allowed slots.
    mutating func restrict(to slots: [Int]) {
        let allowed = Array(Set(slots.filter { (0..<Self.slotCount).contains($0) })).sorted()
        pills = Array(pills.suffix(min(Self.capacity, allowed.count)))
        var used = Set<Int>()
        for index in pills.indices {
            if !allowed.contains(pills[index].slot) || used.contains(pills[index].slot) {
                pills[index].slot = allowed.first { !used.contains($0) }!
            }
            used.insert(pills[index].slot)
        }
    }

    /// The first web link, or else the first existing file path, in tool text.
    static func target(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
           let link = detector.matches(in: text, range: range).compactMap(\.url)
               .first(where: { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }) {
            return link.absoluteString
        }
        guard let regex = try? NSRegularExpression(pattern: #"(?:~|/)[^\s"'`,;:()\[\]{}<>]+"#) else { return nil }
        return regex.matches(in: text, range: range)
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .first { path in
                let expanded = (path as NSString).expandingTildeInPath
                return expanded.count > 1 && FileManager.default.fileExists(atPath: expanded)
            }
    }

    /// A short label for a card target: the host of a link or a file's name.
    static func label(for target: String) -> String {
        if let host = URL(string: target)?.host { return host }
        return (target as NSString).lastPathComponent
    }
}

struct VoiceActivityPillsLayer: View {
    @ObservedObject var model: DockModel
    var cardWidth: CGFloat = 280
    var cronJobs: [CronSummary] = []
    /// The HUD deck sits on the left, so cards keep to the right corners.
    var leavesLeftFree = false
    @State private var queue = VoicePillQueue()

    var body: some View {
        GeometryReader { geometry in
            let width = min(cardWidth, max(0, (geometry.size.width - 12) / 2))
            HStack(spacing: 0) {
                pillColumn(slots: leavesLeftFree ? [] : [0, 3], width: width, height: geometry.size.height)
                Spacer(minLength: 12)
                pillColumn(slots: [1, 2], width: width, height: geometry.size.height)
            }
        }
        // Replacement cards must not animate on top of their outgoing card.
        .transaction { $0.animation = nil }
        .onChange(of: leavesLeftFree) { _, _ in queue.restrict(to: allowedSlots) }
        .onChange(of: model.activeToolCalls) { old, new in
            // `__thinking` / `__compaction` are internal activity markers.
            for call in new where !call.name.hasPrefix("__") {
                let previous = old.first { $0.id == call.id }
                guard previous == nil || (previous?.isComplete == false && call.isComplete) else { continue }
                pushStep(call)
            }
        }
        .onChange(of: cronJobs) { old, new in
            for job in new {
                guard let ran = job.lastRunAt, let before = old.first(where: { $0.id == job.id }), before.lastRunAt != ran else { continue }
                let failed = job.lastError != nil || ["failed", "error"].contains(job.lastStatus?.lowercased() ?? "")
                push(key: "cron-\(job.id)-\(ran)", icon: .calendarCheck, title: failed ? "\(job.name) failed" : "\(job.name) ran",
                     detail: job.lastError ?? job.schedule, tone: failed ? .danger : .success)
            }
        }
        .onChange(of: model.activeSubagents) { old, new in
            for agent in new where !old.contains(where: { $0.id == agent.id }) {
                push(key: "agent-\(agent.id)", icon: .robot, title: agent.name ?? "Subagent",
                     detail: String(agent.goal.prefix(90)), isRunning: true)
            }
        }
        .onChange(of: model.reasoningState?.isComplete) { _, isComplete in
            guard isComplete == true,
                  let text = model.reasoningState?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            push(key: "reasoning-\(text.count)", icon: .brain, title: "Reasoning", detail: String(text.prefix(110)))
        }
        .onChange(of: model.queuedPrompts.map(\.id)) { old, new in
            for prompt in model.queuedPrompts where !old.contains(prompt.id) {
                push(key: "queued-\(prompt.id)", icon: .queue, title: "Queued",
                     detail: String(prompt.text.prefix(90)), isRunning: true)
            }
        }
        .onChange(of: model.backgroundTasks) { old, new in
            for task in new where task.status == .completed
                && old.first(where: { $0.id == task.id })?.status != .completed {
                push(key: "task-\(task.id)", icon: .checkCircle, title: "Background task done",
                     detail: String(task.prompt.prefix(90)), tone: .success,
                     target: task.output.flatMap(VoicePillQueue.target(in:)))
            }
        }
        .onChange(of: model.messages.last(where: \.isError)?.id) { _, id in
            guard let id, let message = model.messages.first(where: { $0.id == id }) else { return }
            push(key: "error-\(id)", icon: .warningCircle, title: "Something went wrong",
                 detail: String(message.text.prefix(110)), tone: .danger)
        }
        .onChange(of: model.isHermesConnected) { _, isConnected in
            push(key: "connection", icon: isConnected ? .plugs : .wifiSlash,
                 title: isConnected ? "Hermes reconnected" : "Hermes disconnected",
                 detail: nil, tone: isConnected ? .success : .danger)
        }
        .onChange(of: contextBand) { old, new in
            // One warning per 5% step past 80%, not one per token.
            guard let new, new > (old ?? 0) else { return }
            push(key: "context", icon: .gauge, title: "Context \(new)% full",
                 detail: "Compact or start a new session soon.", tone: .warning)
        }
        .onChange(of: model.voiceTelemetry.completedAt) { _, completedAt in
            let telemetry = model.voiceTelemetry
            guard let completedAt, !telemetry.wasInterrupted, let submitted = telemetry.requestSubmittedAt else { return }
            var parts: [String] = []
            if let first = telemetry.firstResponseAt {
                parts.append(String(format: "First reply %.1fs", first.timeIntervalSince(submitted)))
            }
            parts.append(String(format: "done %.1fs", completedAt.timeIntervalSince(submitted)))
            push(key: "speed", icon: .timer, title: "Turn speed", detail: parts.joined(separator: " · "))
            let edited = Set(model.activeToolCalls.filter { ["write_file", "patch"].contains($0.name.lowercased()) }.compactMap { $0.args?["path"] })
            if edited.count > 1 {
                push(key: "files-\(completedAt.timeIntervalSince1970)", icon: .files, title: "\(edited.count) files changed",
                     detail: edited.map { ($0 as NSString).lastPathComponent }.sorted().joined(separator: ", "), tone: .success)
            }
            // The answer's link or file, one click away.
            if let reply = model.messages.last(where: { $0.role == .hermes && !$0.isError }),
               let target = VoicePillQueue.target(in: reply.text) {
                push(key: "result-\(reply.id)", icon: target.hasPrefix("http") ? .link : .file, title: "Result",
                     detail: VoicePillQueue.label(for: target), tone: .success, target: target)
            }
        }
    }

    private var allowedSlots: [Int] {
        leavesLeftFree ? [1, 2] : Array(0..<VoicePillQueue.slotCount)
    }

    private func pillColumn(slots: [Int], width: CGFloat, height: CGFloat) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 12) {
                ForEach(queue.pills.filter { slots.contains($0.slot) }.sorted { $0.slot < $1.slot }) { pill in
                    VoicePillCard(pill: pill, maxWidth: width)
                        .allowsHitTesting(pill.target != nil)
                }
            }
            .frame(width: width)
            .frame(minHeight: height)
        }
        .scrollIndicators(.hidden)
        .frame(width: width, height: height)
    }

    private func pushStep(_ call: ActiveToolCall) {
        let key = "tool-\(call.id)"
        let name = call.name.lowercased()
        if name == "terminal", call.isComplete, let tests = TestSummary(ToolText.field("output", in: call.result) ?? call.result ?? "") {
            return push(key: key, icon: tests.failed > 0 ? .warningCircle : .checkCircle,
                        title: tests.failed > 0 ? "\(tests.failed) test\(tests.failed == 1 ? "" : "s") failed" : "All \(tests.passed) tests passed",
                        detail: tests.failed > 0 ? "\(tests.passed) passed" : nil, tone: tests.failed > 0 ? .danger : .success)
        }
        guard !ToolStep.hasCard(call.name) else { return }
        let step = ToolStep.describe(call)
        if name == "web_extract", call.isComplete {
            let target = call.args?["urls"].flatMap(VoicePillQueue.target(in:))
            let excerpt = (ToolText.field("content", in: call.result) ?? ToolText.field("text", in: call.result))
                .map { String($0.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(120)) }
            return push(key: key, icon: .fileText, title: step.title, detail: excerpt ?? target.map(VoicePillQueue.label(for:)),
                        tone: .success, target: target)
        }
        let target = call.isComplete
            ? VoicePillQueue.target(in: [call.input, call.context, call.result ?? "", call.args?["path"] ?? ""].joined(separator: "\n"))
            : nil
        if let stats = call.isComplete ? call.diffStats : nil {
            let file = target.map(VoicePillQueue.label(for:))
            push(key: key, icon: .pencilSimple, title: file.map { "Edited \($0)" } ?? step.title,
                 detail: "+\(stats.added) −\(stats.removed) lines", tone: .success, target: target)
        } else if let target {
            push(key: key, icon: step.icon, title: step.title,
                 detail: step.detail ?? VoicePillQueue.label(for: target), tone: .success, target: target)
        } else {
            let detail = step.detail ?? [call.context, call.input].first { !$0.isEmpty }.map { String($0.prefix(90)) }
            push(key: key, icon: step.icon, title: step.title, detail: detail, isRunning: !call.isComplete,
                 tone: call.isComplete ? .success : .accent)
        }
    }

    /// Context use rounded down to 5%, or nil below 80%.
    private var contextBand: Int? {
        guard let usage = model.sessionContextUsage, usage.sessionID == model.sessionID, usage.max > 0 else { return nil }
        let percent = usage.used * 100 / usage.max
        return percent >= 80 ? percent / 5 * 5 : nil
    }

    private func push(key: String, icon: Ph, title: String, detail: String?, isRunning: Bool = false,
                      tone: VoicePillQueue.Tone = .accent, target: String? = nil) {
        queue.push(key: key, icon: icon, title: title, detail: detail, isRunning: isRunning, tone: tone, target: target,
                   slots: allowedSlots)
        let lifetime = target == nil ? VoicePillQueue.lifetime : VoicePillQueue.targetLifetime
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(lifetime + 0.05))
            queue.expire()
        }
    }
}

private struct VoicePillCard: View {
    let pill: VoicePillQueue.Pill
    let maxWidth: CGFloat

    private var tint: Color {
        switch pill.tone {
        case .accent: Color.dockAccent
        case .success: Color.dockSuccess
        case .warning: Color.dockWarning
        case .danger: Color.dockDestructive
        }
    }

    var body: some View {
        if let target = pill.target {
            Button { ArtifactOpener.open(target) } label: { card }
                .buttonStyle(.dockHover)
                .help(target)
        } else {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 10) {
            DockIcon(pill.icon, size: 15, weight: .fill)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(pill.title)
                        .dockFont(size: 12, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                    if pill.isRunning { ThinkingDots() }
                    if pill.target != nil {
                        DockIcon(.arrowUpRight, size: 10).foregroundStyle(tint)
                    }
                }
                if let detail = pill.detail {
                    Text(detail)
                        .dockFont(size: 11)
                        .foregroundStyle(pill.target == nil ? Color.dockSecondaryText : tint)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.paneRadius + 4, style: .continuous)
                .dockSurfaceFill(Color.dockSurface6.opacity(0.92), stroke: tint.opacity(0.3), lineWidth: 0.6, strokeOnGlass: true)
        )
        .shadow(color: tint.opacity(0.18), radius: 16)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius + 4, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The last few exchanges of the same conversation the chat shows, as a
/// compact floating card.
struct VoiceRecentTranscript: View {
    let messages: [ChatMessage]
    static let limit = 6

    var body: some View {
        let recent = Self.recent(messages)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if recent.isEmpty {
                        Text("Nothing said yet.")
                            .dockFont(size: 12)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    ForEach(recent) { message in
                        let isUser = message.role == .user
                        Group {
                            if isUser {
                                Text(message.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .dockFont(size: 12, weight: .medium)
                                    .foregroundStyle(Color.dockSecondaryText)
                            } else {
                                MarkdownMessageView(
                                    markdown: message.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                    bodySize: 12
                                )
                                .equatable()
                            }
                        }
                            .lineLimit(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                            .multilineTextAlignment(isUser ? .trailing : .leading)
                            .id(message.id)
                    }
                }
                .padding(14)
            }
            .onAppear { proxy.scrollTo(recent.last?.id, anchor: .bottom) }
            .onChange(of: recent.last?.id) { _, id in proxy.scrollTo(id, anchor: .bottom) }
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.paneRadius + 4, style: .continuous)
                .dockSurfaceFill(Color.dockSurface6.opacity(0.95), stroke: Color.dockAccent.opacity(0.25), lineWidth: 0.6, strokeOnGlass: true)
        )
        .shadow(color: Color.dockAccent.opacity(0.15), radius: 16)
    }

    static func recent(_ messages: [ChatMessage]) -> [ChatMessage] {
        Array(messages.filter {
            ($0.role == .user || $0.role == .hermes) && !$0.isError
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.suffix(limit))
    }
}
