import AppKit
import KeyboardShortcuts
import SwiftUI
import Foundation
import UniformTypeIdentifiers

extension Color {
    static let scifiBg = Color.black
    static let scifiCanvas = Color(red: 0.035, green: 0.045, blue: 0.085)
    static let scifiSurface = Color.white.opacity(0.03)
    static let scifiSurface2 = Color.white.opacity(0.02)
    static let scifiSurface4 = Color.white.opacity(0.04)
    static let scifiSurface6 = Color.white.opacity(0.06)
    static let scifiSurface8 = Color.white.opacity(0.08)
    // An explicit cool control fill prevents translucent fields from inheriting
    // a warm macOS-material tint from whatever sits behind the popup.
    static let scifiControlSurface = Color(red: 0.075, green: 0.085, blue: 0.135)
    static let scifiBorderStrong = Color.white.opacity(0.12)
    static let scifiBorder = Color.white.opacity(0.08)
    static let scifiBorderLight = Color.white.opacity(0.06)
    static let scifiAccent = Color(red: 0, green: 0.65, blue: 0.95)
    static let scifiAccentMuted = Color(red: 0, green: 0.67, blue: 1).opacity(0.08)
    static let scifiAccentGlow = Color(red: 0, green: 0.67, blue: 1).opacity(0.25)
    static let scifiFg = Color(white: 0.94)
    static let scifiMuted = Color(white: 0.58)
    static let scifiTertiary = Color(white: 0.35)
    static let scifiSuccess = Color(red: 0.16, green: 0.78, blue: 0.25)
    static let scifiWarning = Color(red: 1, green: 0.74, blue: 0.18)
    static let scifiDestructive = Color(red: 1, green: 0.37, blue: 0.34)
}

extension Animation {
    static func scifiEase(duration: TimeInterval = 0.3) -> Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
    }
}

private extension View {
    /// Keeps compact glass controls visually light while preserving the 44pt
    /// hit area specified by the Dock design system.
    func dockHitTarget() -> some View {
        frame(minWidth: 44, minHeight: 44)
    }
}

private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    let p = (t + Double(i) * 0.2).truncatingRemainder(dividingBy: 1.4) / 1.4
                    let s = 0.6 + 0.4 * max(0, sin(p * .pi * 2))
                    Circle()
                        .fill(Color.scifiAccent)
                        .frame(width: 6, height: 6)
                        .scaleEffect(s)
                        .opacity(s)
                }
            }
        }
    }
}

private struct VoiceModeToolbar: View {
    var onReturnToChat: () -> Void
    var onToggleWorkspace: () -> Void
    var isWorkspaceVisible: Bool
    var canStopRequest: Bool
    var onStopRequest: () -> Void

    var body: some View {
        HStack {
            Button(action: onReturnToChat) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.scifiMuted)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.scifiSurface4))
            }
            .buttonStyle(.scifiPress)
            .dockHitTarget()
            .help("Return to chat")

            Spacer()

            HStack(spacing: 8) {
                Button(action: onToggleWorkspace) {
                    Image(systemName: isWorkspaceVisible ? "rectangle.compress.vertical" : "rectangle.split.2x1")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isWorkspaceVisible ? Color.scifiAccent : Color.scifiMuted)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(isWorkspaceVisible ? Color.scifiAccent.opacity(0.1) : Color.scifiSurface4))
                }
                .buttonStyle(.scifiPress)
                .dockHitTarget()
                .help(isWorkspaceVisible ? "Hide Workspace" : "Show Workspace")

                if canStopRequest {
                    Button(action: onStopRequest) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.scifiDestructive)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.scifiDestructive.opacity(0.1)))
                    }
                    .buttonStyle(.scifiPress)
                    .dockHitTarget()
                    .help("Stop Hermes request")
                }
            }
        }
    }
}

private struct AgentAvatar: View {
    let identity: String
    let statusColor: Color

    private var seed: Int {
        identity.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
    }

    var body: some View {
        let rotation = Double(seed % 360)
        let secondaryRotation = Double((seed / 7) % 360)

        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.scifiAccent.opacity(0.3), Color.scifiAccent.opacity(0.08)],
                        center: UnitPoint(x: 0.32, y: 0.24),
                        startRadius: 1,
                        endRadius: 20
                    )
                )
            Circle()
                .stroke(Color.scifiAccent.opacity(0.36), lineWidth: 0.6)
            Circle()
                .trim(from: 0.08, to: 0.43)
                .stroke(Color.scifiAccent.opacity(0.8), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .rotationEffect(.degrees(rotation))
                .padding(4)
            Circle()
                .trim(from: 0.58, to: 0.77)
                .stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 0.6, lineCap: .round))
                .rotationEffect(.degrees(secondaryRotation))
                .padding(7)
            Circle()
                .fill(statusColor)
                .frame(width: 4, height: 4)
                .offset(x: 8, y: -7)
                .shadow(color: statusColor.opacity(0.8), radius: 3)
            Circle()
                .fill(Color.scifiAccent.opacity(0.9))
                .frame(width: 5, height: 5)
        }
        .shadow(color: Color.scifiAccent.opacity(0.18), radius: 6)
        .accessibilityLabel("Agent avatar")
    }
}

private struct MessageBubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let r = rect
        let b: CGFloat = 18
        let s: CGFloat = 6
        let tl = b
        let tr = b
        let br = isUser ? s : b
        let bl = isUser ? b : s
        return Path { p in
            p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
            p.addArc(center: CGPoint(x: r.maxX - tr, y: r.minY + tr), radius: tr,
                     startAngle: Angle(degrees: -90), endAngle: Angle(degrees: 0), clockwise: false)
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
            p.addArc(center: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br,
                     startAngle: Angle(degrees: 0), endAngle: Angle(degrees: 90), clockwise: false)
            p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
            p.addArc(center: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl,
                     startAngle: Angle(degrees: 90), endAngle: Angle(degrees: 180), clockwise: false)
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
            p.addArc(center: CGPoint(x: r.minX + tl, y: r.minY + tl), radius: tl,
                     startAngle: Angle(degrees: 180), endAngle: Angle(degrees: 270), clockwise: false)
            p.closeSubpath()
        }
    }
}

private struct MarkdownMessageView: View {
    let markdown: String

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(text: String, marker: String)
        case code(String, language: String?)
        case quote(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    if let rendered = inlineMarkdown(text) {
                        Text(rendered)
                            .font(.system(size: Self.headingSize(level), weight: .bold))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                case .paragraph(let text):
                    if let rendered = inlineMarkdown(text) {
                        Text(rendered)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .listItem(let text, let marker):
                    HStack(alignment: .top, spacing: 6) {
                        Text(marker)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.scifiAccent)
                            .frame(minWidth: 16, alignment: .trailing)
                        if let rendered = inlineMarkdown(text) {
                            Text(rendered)
                                .font(.system(size: 14))
                                .textSelection(.enabled)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .code(let code, let language):
                    VStack(alignment: .leading, spacing: 2) {
                        if let lang = language {
                            Text(lang)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.scifiMuted)
                                .textCase(.uppercase)
                                .padding(.horizontal, 8)
                                .padding(.top, 6)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code)
                                .font(.system(size: 12.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.scifiSurface4)
                            .stroke(Color.scifiBorder, lineWidth: 0.5)
                    )
                case .quote(let text):
                    if let rendered = inlineMarkdown(text) {
                        Text(rendered)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.scifiMuted)
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Color.scifiBorder).frame(width: 2)
                            }
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 20
        case 2: 17
        case 3: 15
        default: 14
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var code: [String] = []
        var language: String?
        var inCode = false
        var paragraph: [String] = []
        var orderedIndex = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            orderedIndex = 0
            if !text.isEmpty { result.append(.paragraph(text)) }
        }

        func flushCode() {
            result.append(.code(code.joined(separator: "\n"), language: language))
            code.removeAll()
            language = nil
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                } else {
                    flushParagraph()
                    let suffix = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    language = suffix.isEmpty ? nil : suffix
                }
                inCode.toggle()
                continue
            }
            if inCode {
                code.append(line)
                continue
            }
            if let level = Self.headingLevel(trimmed) {
                flushParagraph()
                let text = String(trimmed.drop(while: { $0 == "#" }).drop(while: { $0 == " " }))
                result.append(.heading(level: level, text: text))
                continue
            }
            if let content = Self.orderedListContent(trimmed) {
                flushParagraph()
                orderedIndex += 1
                result.append(.listItem(text: content, marker: "\(orderedIndex)."))
                continue
            }
            if let item = Self.unorderedListItem(trimmed) {
                flushParagraph()
                result.append(.listItem(text: item, marker: "•"))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let content = String(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                if !content.isEmpty { result.append(.quote(content)) }
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            paragraph.append(line)
        }
        if inCode { flushCode() } else { flushParagraph() }
        return result
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes > 0, hashes <= 6, line.count > hashes,
              line[line.index(line.startIndex, offsetBy: hashes)] == " " else { return nil }
        return hashes
    }

    private static func orderedListContent(_ line: String) -> String? {
        guard let dotIndex = line.firstIndex(of: "."),
              !line[..<dotIndex].isEmpty,
              line[..<dotIndex].allSatisfy(\.isNumber),
              line.index(after: dotIndex) < line.endIndex,
              line[line.index(after: dotIndex)] == " " else { return nil }
        return String(line[line.index(dotIndex, offsetBy: 2)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func unorderedListItem(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] {
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func inlineMarkdown(_ value: String) -> AttributedString? {
        do {
            return try AttributedString(
                markdown: groupedNumbers(in: value),
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            return AttributedString(value)
        }
    }

    private func groupedNumbers(in value: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_./-])\d{4,}(?![A-Za-z0-9_./-])"#
        ) else {
            return value
        }

        var result = value
        let range = NSRange(value.startIndex..., in: value)
        for match in regex.matches(in: value, range: range).reversed() {
            guard let matchRange = Range(match.range, in: result) else { continue }
            let number = String(result[matchRange])
            guard !(number.count == 4 && (number.hasPrefix("19") || number.hasPrefix("20"))) else { continue }

            let digits = Array(number)
            var grouped = ""
            for index in digits.indices {
                if index > 0 && (digits.count - index).isMultiple(of: 3) {
                    grouped.append(",")
                }
                grouped.append(digits[index])
            }
            result.replaceSubrange(matchRange, with: grouped)
        }
        return result
    }
}

private struct ConversationBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct WorkspaceActivitySidebar: View {
    @ObservedObject var model: DockModel
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var control: ControlCenterModel
    var onClose: () -> Void = {}
    @State private var selectedMode: ControlTab = .today
    @State private var selectedAttentionID: String?
    @State private var inboxFilter: InboxFilter = .all
    @State private var isShowingCommandPalette = false
    @State private var searchQuery = ""
    @State private var selectedModelID = ""
    @State private var selectedAgentID: String?
    @State private var repository = RepositorySnapshot.empty
    @State private var isRefreshingRepository = false
    @State private var showingRepositoryPicker = false
    @State private var reminderForConfirmation: ReminderSummary?
    @State private var isShowingReminderConfirmation = false
    @State private var cronChangeRequest: CronChangeRequest?
    @State private var isShowingCronConfirmation = false
    @State private var cronRemovalRequest: CronSummary?
    @State private var isShowingCronRemovalConfirmation = false
    @State private var cronRunRequest: CronSummary?
    @State private var isShowingCronRunConfirmation = false
    @State private var automationName = ""
    @State private var automationSchedule = ""
    @State private var automationPrompt = ""
    @State private var isShowingAutomationConfirmation = false
    @State private var isShowingMCPReloadConfirmation = false
    @State private var kanbanTitle = ""
    @State private var kanbanBody = ""
    @State private var isShowingKanbanConfirmation = false
    @State private var kanbanChangeRequest: KanbanChangeRequest?
    @State private var isShowingKanbanChangeConfirmation = false
    @State private var selectedKanbanTask: KanbanTaskSummary?
    @State private var kanbanMutationRequest: KanbanMutationRequest?
    @State private var cronEditJob: CronSummary?
    @State private var clarificationItem: AttentionItem?
    @State private var clarificationResponse = ""
    @State private var expandedCronReportIDs: Set<String> = []
    @State private var kanbanStatusFilter = "All"
    @State private var kanbanAssigneeFilter = "All"
    @State private var kanbanMineOnly = false
    @State private var kanbanCurrentSessionOnly = false
    @State private var kanbanSort = "updated"
    @State private var sessionSteerText = ""

    private enum KanbanLane: String, CaseIterable, Identifiable {
        case triage = "Triage"
        case todo = "Todo"
        case ready = "Ready"
        case running = "Running"
        case review = "Review"
        case scheduled = "Scheduled"
        case blocked = "Blocked"
        case done = "Done"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .triage: "scope"
            case .todo: "circle.dashed"
            case .ready: "circle"
            case .running: "arrow.triangle.2.circlepath"
            case .review: "eye"
            case .scheduled: "clock"
            case .blocked: "exclamationmark.octagon"
            case .done: "checkmark.circle"
            }
        }
        var color: Color {
            switch self {
            case .triage: Color.scifiWarning
            case .todo: Color.scifiMuted
            case .ready: Color.scifiAccent
            case .running: Color(red: 0.55, green: 0.55, blue: 1)
            case .review: Color(red: 0.72, green: 0.48, blue: 1)
            case .scheduled: Color(red: 0.32, green: 0.78, blue: 0.82)
            case .blocked: Color.scifiWarning
            case .done: Color.scifiSuccess
            }
        }
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("HERMES CONTROL")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Color.scifiAccent)
                    Text("PERSONAL OPERATING SURFACE")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(Color.scifiTertiary)
                }
                Spacer()
                Button { isShowingCommandPalette = true } label: {
                    Image(systemName: "command")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.scifiAccent)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.scifiPress)
                .help("Command palette")
                .keyboardShortcut("k", modifiers: [.command])
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.scifiMuted)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.scifiSurface4))
                }
                .buttonStyle(.scifiPress)
                .dockHitTarget()
                .help("Return to chat")
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: statusColor.opacity(0.8), radius: 4)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }

            modePicker

            ScrollView {
                Group {
                     switch selectedMode {
                     case .today: nowContent
                     case .inbox: inboxContent
                     case .activity: activityContent
                     case .automations: automationsContent
                     case .projects: projectsContent
                     case .search: searchContent
                     case .kanban: kanbanContent
                     case .core: coreContent
                     }
                }
                .padding(16)
            }
        }
    }

    private var observedSidebar: some View {
        sidebarContent
        .background {
            ZStack {
                Color.scifiCanvas
                RadialGradient(
                    colors: [Color.scifiAccent.opacity(0.055), .clear],
                    center: UnitPoint(x: 0.9, y: 0),
                    startRadius: 0,
                    endRadius: 300
                )
            }
        }
        .environment(\.colorScheme, .dark)
        .fileImporter(isPresented: $showingRepositoryPicker, allowedContentTypes: [.folder], onCompletion: handleRepositoryImport)
        .task(id: activeRepositoryIdentity) { await refreshRepository() }
        .task {
            control.bind(to: model)
            control.refresh()
        }
        .onChange(of: model.status) { _, _ in control.rebuildAttention() }
        .onChange(of: model.approvalText) { _, _ in control.rebuildAttention() }
        .onChange(of: model.sessionID) { _, sessionID in control.focus(sessionID: sessionID) }
        .onChange(of: control.capabilities) { _, _ in
            guard selectedMode == .kanban, control.capabilityAvailable("kanban") else { return }
            control.refreshKanban()
        }
        .onChange(of: model.controlInboxRequest) { _, _ in
            selectedMode = .inbox
            selectedAttentionID = model.requestedAttentionID
        }
        .onChange(of: searchQuery) { _, query in
            guard selectedMode == .search else { return }
            control.search(query)
        }

    }

    var body: some View {
        observedSidebar
        .sheet(item: $selectedKanbanTask) { task in
            kanbanDetailSheet(task)
        }
        .sheet(isPresented: $isShowingCommandPalette) {
            DockCommandPalette { command in
                run(command)
                isShowingCommandPalette = false
            }
        }
        .sheet(item: $kanbanMutationRequest) { request in
            KanbanMutationEditor(request: request, assignees: control.kanbanAssignees, isPending: control.isActionPending(control.kanbanActionID(request.kind, task: request.task))) { updated in
                control.mutateKanban(updated)
            }
        }
        .sheet(item: $cronEditJob) { job in
            CronEditEditor(job: job, isPending: control.isActionPending(control.cronActionID("edit", job: job))) { draft in
                control.editCron(job, draft: draft)
            }
        }
        .confirmationDialog("Complete Apple Reminder?", isPresented: $isShowingReminderConfirmation) {
            if let reminder = reminderForConfirmation {
                Button("Complete Reminder") { control.completeReminder(reminder) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let reminder = reminderForConfirmation {
                Text("Hermes will submit a request to complete ‘\(reminder.title)’ through the Apple Reminders skill. No other reminder will be changed.")
            }
        }
        .confirmationDialog("Change Scheduled Job?", isPresented: $isShowingCronConfirmation) {
            if let request = cronChangeRequest {
                Button(request.enable ? "Resume Job" : "Pause Job") { control.setCron(request.job, enabled: request.enable) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let request = cronChangeRequest {
                Text("Hermes will \(request.enable ? "resume" : "pause") ‘\(request.job.name)’.")
            }
        }
        .confirmationDialog("Remove Scheduled Job?", isPresented: $isShowingCronRemovalConfirmation) {
            if let job = cronRemovalRequest {
                Button("Remove Job", role: .destructive) { control.removeCron(job) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let job = cronRemovalRequest {
                Text("Hermes will remove ‘\(job.name)’ from the scheduler.")
            }
        }
        .confirmationDialog("Run Scheduled Job Now?", isPresented: $isShowingCronRunConfirmation) {
            if let job = cronRunRequest {
                Button("Run Job Now") { control.runCronNow(job) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let job = cronRunRequest {
                Text("Hermes will start ‘\(job.name)’ immediately, in addition to its normal schedule.")
            }
        }
        .confirmationDialog("Create Scheduled Job?", isPresented: $isShowingAutomationConfirmation) {
            Button("Create Job") {
                Task {
                    if await control.createCron(name: automationName, schedule: automationSchedule, prompt: automationPrompt) {
                        automationName = ""
                        automationSchedule = ""
                        automationPrompt = ""
                    }
                }
            }
            .disabled(control.isActionPending("cron.create"))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will create ‘\(automationName)’ on schedule ‘\(automationSchedule)’." )
        }
        .confirmationDialog("Reload MCP Tools?", isPresented: $isShowingMCPReloadConfirmation) {
            Button("Reload MCP Tools") { control.reloadMCP() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will invalidate the active session's cached MCP tool snapshot and reload configured servers.")
        }
        .confirmationDialog("Create Kanban Task?", isPresented: $isShowingKanbanConfirmation) {
            Button("Create Kanban Task") {
                Task {
                    if await control.createKanbanTask(title: kanbanTitle, body: kanbanBody) {
                        kanbanTitle = ""
                        kanbanBody = ""
                    }
                }
            }
            .disabled(control.isCreatingKanbanTask)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will create this task in the authoritative Kanban board through its CLI.")
        }
        .confirmationDialog("Change Kanban Task?", isPresented: $isShowingKanbanChangeConfirmation) {
            if let request = kanbanChangeRequest {
                Button(request.action.rawValue.uppercased()) {
                    control.updateKanbanTask(request.task, action: request.action)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let request = kanbanChangeRequest {
                let action = request.action.rawValue
                let title = request.task.title
                Text(verbatim: "Hermes will " + action + " ‘" + title + "’ on the authoritative Kanban board.")
            }
        }
        .sheet(item: $clarificationItem, onDismiss: { clarificationResponse = "" }) { item in
            VStack(alignment: .leading, spacing: 14) {
                Text("CLARIFICATION REQUIRED")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.scifiAccent)
                Text(item.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scifiFg)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Your response", text: $clarificationResponse, axis: .vertical)
                    .textFieldStyle(.scifiGlass)
                    .lineLimit(3...6)
                HStack {
                    Spacer()
                    Button("Cancel") { clarificationItem = nil }
                    Button("SEND RESPONSE") {
                        control.respond(to: item, action: .respond, response: clarificationResponse)
                        clarificationItem = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(clarificationResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 390)
            .background(Color.scifiBg)
            .environment(\.colorScheme, .dark)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 3) {
            ForEach(primaryTabs) { mode in
                modeButton(mode)
            }

            Menu {
                ForEach(secondaryTabs) { mode in
                    Button {
                        select(mode)
                    } label: {
                        Label(mode.tabLabel, systemImage: mode.icon)
                    }
                }
            } label: {
                Text(secondaryTabs.contains(selectedMode) ? selectedMode.tabLabel.uppercased() : "MORE")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(0.75)
                .foregroundStyle(secondaryTabs.contains(selectedMode) ? Color.scifiFg : Color.scifiMuted)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(secondaryTabs.contains(selectedMode) ? Color.scifiAccent.opacity(0.11) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.scifiPress)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
    }

    private var primaryTabs: [ControlTab] { [.today, .inbox, .activity, .automations] }
    private var secondaryTabs: [ControlTab] { [.projects, .search, .kanban, .core] }

    private func modeButton(_ mode: ControlTab) -> some View {
        Button { select(mode) } label: {
            HStack(spacing: 5) {
                Text(mode.tabLabel.uppercased())
                    .lineLimit(1)
                if badgeCount(for: mode) > 0 {
                    Text(badgeLabel(for: mode))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(badgeIsUrgent(for: mode) ? Color.scifiBg : Color.scifiFg)
                        .frame(minWidth: 18, minHeight: 18)
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(badgeIsUrgent(for: mode) ? Color.scifiWarning : Color.scifiAccent.opacity(0.85)))
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .tracking(0.75)
            .foregroundStyle(selectedMode == mode ? Color.scifiFg : Color.scifiMuted)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(selectedMode == mode ? Color.scifiAccent.opacity(0.11) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.scifiPress)
        .frame(maxWidth: .infinity)
    }

    private func select(_ mode: ControlTab) {
        withAnimation(.scifiEase(duration: 0.2)) { selectedMode = mode }
        if mode == .core {
            model.refreshRuntimeConfiguration()
            control.refresh(forceCapabilities: true)
        }
        if mode == .automations { control.refresh(); control.refreshCronRuns() }
        if mode == .projects { control.refresh() }
        if mode == .search { control.search(searchQuery) }
        if mode == .kanban { control.refreshKanban() }
    }

    private func run(_ command: DockCommand) {
        switch command {
        case .tab(let tab): select(tab)
        case .newChat: model.newChat(); model.requestComposerFocus()
        case .focusComposer: model.requestComposerFocus()
        case .stop: model.stop()
        case .voice: model.startVoiceConversation()
        }
    }

    private var activityContent: some View {
        AgentBoardView(model: model, embedded: true)
    }

    private var automationsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            projectionRefreshNotice("cron.jobs")
            sectionLabel("CREATE AUTOMATION")
            VStack(alignment: .leading, spacing: 10) {
                controlFieldLabel("NAME")
                scifiTextField("Morning review", text: $automationName)

                HStack(alignment: .firstTextBaseline) {
                    controlFieldLabel("SCHEDULE")
                    Spacer()
                    Text("EVERY 2H  ·  0 9 * * *")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(Color.scifiTertiary)
                }
                scifiTextField("When should Hermes run this?", text: $automationSchedule)

                controlFieldLabel("REQUEST")
                TextField("What should Hermes do?", text: $automationPrompt, axis: .vertical)
                    .lineLimit(2...3)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(Color.scifiFg)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.scifiSurface)
                            .stroke(Color.scifiBorder, lineWidth: 0.5)
                    )

                Button {
                    isShowingAutomationConfirmation = true
                } label: {
                    HStack(spacing: 8) {
                        Text("REVIEW AND CREATE")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(.scifiPrimary)
                .opacity(canCreateAutomation && control.capabilityAvailable("rpc-scheduling") ? 1 : 0.42)
                .disabled(!canCreateAutomation || !control.capabilityAvailable("rpc-scheduling"))
            }
            .padding(.bottom, 2)

            if !control.cronJobs.isEmpty {
                sectionLabel("AUTOMATION DETAILS")
                ForEach(control.cronJobs) { job in
                    cronReportCard(job)
                }
            }

            sectionLabel("SCHEDULED JOBS  ·  \(control.cronJobs.count)")
            if control.cronJobs.isEmpty {
                emptyState(icon: "clock.badge.questionmark", title: "No automations", detail: "Create a Hermes cron job above.")
            } else {
                ForEach(control.cronJobs) { job in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Circle().fill(job.enabled ? Color.scifiAccent : Color.scifiTertiary).frame(width: 6, height: 6)
                            Text(job.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.scifiFg)
                            Spacer()
                            Text(job.enabled ? "ENABLED" : "PAUSED")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(job.enabled ? Color.scifiSuccess : Color.scifiWarning)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CronScheduleFormatting.humanReadable(job.schedule))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.scifiFg)
                            Text(job.schedule)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.scifiTertiary)
                        }
                        if let nextRun = job.nextRun {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.right.circle")
                                Text("NEXT RUN")
                                Text(HumanDateFormatting.dateAndTime(nextRun))
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.scifiAccent)
                        }
                        HStack(spacing: 12) {
                            if control.capabilityAvailable("cron.runNow") {
                                Button {
                                    cronRunRequest = job
                                    isShowingCronRunConfirmation = true
                                } label: {
                                    ScifiActionLabel(
                                        title: "RUN NOW",
                                        pendingTitle: "RUNNING…",
                                        isPending: control.isActionPending(control.cronActionID("run", job: job))
                                    )
                                }
                                .disabled(control.isActionPending(control.cronActionID("run", job: job)))
                            }
                            if control.capabilityAvailable("cron.edit"), !job.editableFields.isEmpty {
                                Button { cronEditJob = job } label: {
                                    ScifiActionLabel(
                                        title: "EDIT",
                                        pendingTitle: "SAVING…",
                                        isPending: control.isActionPending(control.cronActionID("edit", job: job))
                                    )
                                }
                                .disabled(control.isActionPending(control.cronActionID("edit", job: job)))
                            }
                            if control.capabilityAvailable("rpc-scheduling") {
                                Button {
                                    cronChangeRequest = CronChangeRequest(job: job, enable: !job.enabled)
                                    isShowingCronConfirmation = true
                                } label: {
                                    ScifiActionLabel(
                                        title: job.enabled ? "PAUSE" : "RESUME",
                                        pendingTitle: job.enabled ? "PAUSING…" : "RESUMING…",
                                        isPending: control.isActionPending(control.cronActionID(job.enabled ? "pause" : "resume", job: job))
                                    )
                                }
                                .disabled(control.isActionPending(control.cronActionID(job.enabled ? "pause" : "resume", job: job)))
                                Button {
                                    cronRemovalRequest = job
                                    isShowingCronRemovalConfirmation = true
                                } label: {
                                    ScifiActionLabel(
                                        title: "REMOVE",
                                        pendingTitle: "REMOVING…",
                                        isPending: control.isActionPending(control.cronActionID("remove", job: job)),
                                        tint: Color.scifiWarning
                                    )
                                }
                                .foregroundStyle(Color.scifiWarning)
                                .disabled(control.isActionPending(control.cronActionID("remove", job: job)))
                            }
                            Spacer()
                        }
                        .buttonStyle(.scifiPress)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.scifiAccent)
                    }
                    .padding(12)
                    .scifiGlassPane()
                }
            }
            sectionLabel("RUN HISTORY  ·  \(control.cronRuns.count)")
            if let state = control.refreshState(for: "cron.history"), state.isStale {
                Text("Showing the last successful history while Hermes reconnects. \(state.error ?? "")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.scifiWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !control.cronHistoryAvailable && control.cronRuns.isEmpty {
                Text("Hermes cron history is unavailable through the installed CLI.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scifiTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if control.cronRuns.isEmpty {
                Text("No cron execution attempts recorded.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scifiTertiary)
            } else {
                ForEach(control.cronRuns) { run in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle().fill(cronRunIsSuccessful(run) ? Color.scifiSuccess : Color.scifiWarning).frame(width: 6, height: 6)
                            Text(run.status.uppercased()).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Color.scifiFg)
                            Spacer()
                            Text(run.jobID ?? run.id).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.scifiMuted).lineLimit(1)
                        }
                        if let claimedAt = run.claimedAt {
                            Text(HumanDateFormatting.dateAndTime(claimedAt)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.scifiTertiary)
                        }
                        if let error = run.error {
                            Text(error).font(.system(size: 12)).foregroundStyle(Color.scifiWarning).lineLimit(3)
                        }
                    }
                    .padding(12)
                    .scifiGlassPane()
                }
            }
        }
    }

    private func cronReportCard(_ job: CronSummary) -> some View {
        let latestRun = control.cronRuns.first { $0.jobID == job.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: job.enabled ? "clock.badge.checkmark" : "clock.badge.xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(job.enabled ? Color.scifiSuccess : Color.scifiWarning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.scifiFg)
                        .lineLimit(2)
                    Text(job.enabled ? "ENABLED AND SCHEDULED" : "PAUSED")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.45)
                        .foregroundStyle(job.enabled ? Color.scifiSuccess : Color.scifiWarning)
                }
                Spacer(minLength: 0)
            }

            Divider().overlay(Color.scifiBorderLight)

            reportRow("SCHEDULE", value: CronScheduleFormatting.humanReadable(job.schedule))
            reportRow("CRON", value: job.schedule)
            reportRow("NEXT RUN", value: job.nextRun.map(HumanDateFormatting.dateAndTime) ?? "Not reported by Hermes")
            reportRow("JOB ID", value: job.id)
            if let delivery = job.delivery, !delivery.isEmpty {
                reportRow("DELIVERY", value: delivery.uppercased())
            }
            if let prompt = job.prompt, !prompt.isEmpty {
                reportRow("REQUEST", value: prompt)
            }
            if let latestRun {
                reportRow("LAST RUN", value: latestRun.claimedAt.map(HumanDateFormatting.dateAndTime) ?? latestRun.id)
                HStack(spacing: 6) {
                    Circle().fill(cronRunIsSuccessful(latestRun) ? Color.scifiSuccess : Color.scifiWarning).frame(width: 5, height: 5)
                    Text("LAST STATUS")
                    Text(latestRun.status.uppercased())
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(cronRunIsSuccessful(latestRun) ? Color.scifiSuccess : Color.scifiWarning)
                if let error = latestRun.error, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scifiWarning)
                        .lineLimit(3)
                }
            } else {
                reportRow("LAST RUN", value: "No execution recorded")
            }
            if let report = job.report, !report.isEmpty {
                Divider().overlay(Color.scifiBorderLight)
                Button {
                    withAnimation(.scifiEase(duration: 0.2)) {
                        if expandedCronReportIDs.contains(job.id) {
                            expandedCronReportIDs.remove(job.id)
                        } else {
                            expandedCronReportIDs.insert(job.id)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expandedCronReportIDs.contains(job.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                        Text(expandedCronReportIDs.contains(job.id) ? "HIDE REPORT" : "VIEW LATEST REPORT")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(Color.scifiAccent)
                }
                .buttonStyle(.scifiPress)
                if expandedCronReportIDs.contains(job.id) {
                    MarkdownMessageView(markdown: report)
                        .padding(10)
                        .background(Color.black.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else {
                Divider().overlay(Color.scifiBorderLight)
                VStack(alignment: .leading, spacing: 6) {
                    Text("REPORT BODY UNAVAILABLE")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.scifiTertiary)
                    Text("Hermes recorded this run, but the installed CLI only provides execution status and delivery metadata—not the response body. " + (job.delivery?.lowercased() == "origin" ? "This job delivers its result to its origin chat." : ""))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scifiMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("RETURN TO CHAT") {
                        onClose()
                        model.requestComposerFocus()
                    }
                    .buttonStyle(.scifiPress)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.scifiAccent)
                }
            }
        }
        .padding(12)
        .scifiGlassPane()
    }

    private func reportRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(Color.scifiTertiary)
            Text(value)
                .foregroundStyle(Color.scifiMuted)
                .lineLimit(2)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func cronRunIsSuccessful(_ run: CronRunSummary) -> Bool {
        let status = run.status.lowercased()
        return ["ok", "success", "successful", "completed", "complete", "succeeded"].contains(status)
    }

    private func scifiTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundStyle(Color.scifiFg)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.scifiSurface)
                    .stroke(Color.scifiBorder, lineWidth: 0.5)
            )
    }

    private var canCreateAutomation: Bool {
        !automationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !automationSchedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !automationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func controlFieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(.body, design: .monospaced).weight(.semibold))
            .tracking(0.9)
            .foregroundStyle(Color.scifiMuted)
    }

    private var tabBadges: ControlTabBadgeState {
        ControlTabBadgeState.make(
            attention: control.attention,
            activeAgentCount: model.activeSubagents.filter { $0.status.lowercased() != "complete" }.count,
            activeToolCount: model.activeToolCalls.filter { !$0.isComplete }.count
        )
    }

    private func badgeCount(for tab: ControlTab) -> Int {
        tabBadges.count(for: tab)
    }

    private func badgeLabel(for tab: ControlTab) -> String {
        let count = badgeCount(for: tab)
        return count > 99 ? "99+" : "\(count)"
    }

    private func badgeIsUrgent(for tab: ControlTab) -> Bool {
        tabBadges.isUrgent(for: tab)
    }

    private var projectsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            projectionRefreshNotice("projects")
            if let selectedProjectID = control.selectedProjectID,
               let project = control.projects.first(where: { $0.id == selectedProjectID }) {
                HStack {
                    Button {
                        control.closeProject()
                    } label: {
                        Label("PROJECTS", systemImage: "chevron.left")
                    }
                    .buttonStyle(.scifiPress)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.scifiAccent)
                    Spacer()
                }
                sectionLabel("PROJECT  ·  \(project.name)")
                if control.projectSessions.isEmpty {
                    emptyState(icon: "bubble.left.and.bubble.right", title: "No sessions in this project", detail: "Hermes returned no grouped sessions for this project.")
                } else {
                    sectionLabel("SESSIONS  ·  \(control.projectSessions.count)")
                    ForEach(control.projectSessions) { session in
                        Button {
                            control.openProjectSession(session)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Circle().fill(Color.scifiAccent).frame(width: 6, height: 6)
                                    Text(session.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.scifiFg)
                                        .lineLimit(2)
                                    Spacer()
                                    Text(session.state.uppercased())
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.scifiMuted)
                                }
                                if let preview = session.preview {
                                    Text(preview)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.scifiTertiary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .scifiListRow()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.scifiPress)
                    }
                }
            } else if control.projects.isEmpty {
                sectionLabel("HERMES PROJECTS  ·  0")
                emptyState(icon: "folder", title: "No Hermes projects", detail: "Projects will appear here when Hermes has project contexts configured.")
            } else {
                sectionLabel("HERMES PROJECTS  ·  \(control.projects.count)")
                ForEach(control.projects) { project in
                    Button {
                        control.openProject(project)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: project.isActive ? "folder.fill" : "folder")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(project.isActive ? Color.scifiAccent : Color.scifiMuted)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(projectDisplayName(project))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.scifiFg)
                                    .lineLimit(1)
                                Text(projectMetadata(project))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Color.scifiTertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if project.isActive {
                                Text("ACTIVE")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .tracking(0.5)
                                    .foregroundStyle(Color.scifiSuccess)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.scifiAccent)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.scifiPress)
                }
            }
        }
    }

    private func projectDisplayName(_ project: ProjectSummary) -> String {
        guard project.name != "__no_project__" else { return "Unassigned sessions" }
        let path = URL(fileURLWithPath: project.name)
        return path.lastPathComponent.isEmpty ? project.name : path.lastPathComponent
    }

    private func projectMetadata(_ project: ProjectSummary) -> String {
        let counts = "\(project.repoCount) repos  ·  \(project.sessionCount) sessions"
        guard project.name != "__no_project__" else { return counts }
        return "\(counts)  ·  \(project.name)"
    }

    private var kanbanContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("HERMES KANBAN")
                    Text("\(control.kanbanTasks.count) tasks across \(KanbanLane.allCases.count) lanes")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.scifiTertiary)
                }
                Spacer()
                if control.capabilityAvailable("kanban.boards") {
                    Menu {
                        ForEach(control.kanbanBoards.filter { !$0.archived }) { board in
                            Button {
                                control.selectKanbanBoard(board)
                            } label: {
                                Label(board.name, systemImage: control.selectedKanbanBoardSlug == board.slug ? "checkmark.circle" : "circle")
                            }
                        }
                        if control.kanbanBoards.isEmpty {
                            Text("No boards reported by Hermes")
                        }
                        Button {
                            control.refreshKanbanBoards()
                        } label: {
                            Label("Refresh boards", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Label(control.kanbanBoards.first(where: { $0.slug == control.selectedKanbanBoardSlug })?.name ?? "BOARD", systemImage: "rectangle.3.group")
                    }
                    .buttonStyle(.scifiPress)
                    .foregroundStyle(Color.scifiAccent)
                }
                Button { control.refreshKanban() } label: {
                    if control.isActionPending(control.refreshKanbanActionID) {
                        ProgressView().controlSize(.small).tint(Color.scifiAccent)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.scifiPress)
                .foregroundStyle(Color.scifiAccent)
                .disabled(control.isActionPending(control.refreshKanbanActionID))
            }
            if control.capabilityAvailable("kanban.create") {
                createKanbanTaskForm
            }

            if control.capabilityAvailable("kanban.filters") {
                kanbanFilterControls
            }
            if let stats = control.kanbanStats, !stats.counts.isEmpty {
                HStack(spacing: 8) {
                    ForEach(stats.counts.keys.sorted(), id: \.self) { status in
                        Text("\(status.uppercased()) \(stats.counts[status] ?? 0)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.scifiTertiary)
                    }
                }
            }

            if control.kanbanTasks.isEmpty {
                emptyState(icon: "rectangle.3.group", title: "No Kanban tasks", detail: "Create the first task above, or refresh if you expected an existing Hermes board.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(KanbanLane.allCases) { lane in
                            kanbanLane(lane)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Text("Hermes owns this board. The Dock only reads and submits confirmed CLI actions.")
                .font(.body)
                .foregroundStyle(Color.scifiTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let state = control.refreshState(for: "kanban.board"), let error = state.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .medium))
                    Text(state.isStale ? "Showing the last successful board. \(error)" : error)
                        .font(.system(.body, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.scifiWarning)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(Color.scifiWarning.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.scifiWarning.opacity(0.34), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var kanbanFilterControls: some View {
        HStack(spacing: 8) {
            Menu(kanbanStatusFilter.uppercased()) {
                Button("ALL") { kanbanStatusFilter = "All"; applyKanbanFilters() }
                ForEach(KanbanLane.allCases) { lane in
                    Button(lane.rawValue.uppercased()) { kanbanStatusFilter = lane.rawValue; applyKanbanFilters() }
                }
            }
            Menu(kanbanAssigneeFilter.uppercased()) {
                Button("ALL ASSIGNEES") { kanbanAssigneeFilter = "All"; applyKanbanFilters() }
                ForEach(control.kanbanAssignees, id: \.self) { assignee in
                    Button(assignee) { kanbanAssigneeFilter = assignee; applyKanbanFilters() }
                }
            }
            Toggle("MINE", isOn: $kanbanMineOnly)
                .toggleStyle(.button)
                .onChange(of: kanbanMineOnly) { _, _ in applyKanbanFilters() }
            if model.sessionID != nil {
                Toggle("SESSION", isOn: $kanbanCurrentSessionOnly)
                    .toggleStyle(.button)
                    .onChange(of: kanbanCurrentSessionOnly) { _, _ in applyKanbanFilters() }
            }
            Menu("SORT") {
                ForEach(["updated", "created-desc", "priority-desc", "title"], id: \.self) { value in
                    Button(value.uppercased()) { kanbanSort = value; applyKanbanFilters() }
                }
            }
        }
        .buttonStyle(.scifiPress)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.scifiAccent)
        .disabled(control.isActionPending(control.refreshKanbanActionID))
    }

    private func applyKanbanFilters() {
        control.refreshKanban(filter: KanbanListFilter(
            status: kanbanStatusFilter == "All" ? nil : kanbanStatusFilter.lowercased(),
            assignee: kanbanAssigneeFilter == "All" ? nil : kanbanAssigneeFilter,
            mine: kanbanMineOnly,
            sessionID: kanbanCurrentSessionOnly ? model.sessionID : nil,
            sort: kanbanSort
        ))
    }

    private var createKanbanTaskForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.scifiAccent)
                Text("ADD TASK")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(Color.scifiMuted)
            }
            HStack(spacing: 8) {
                scifiTextField("What needs to be done?", text: $kanbanTitle)
                Button {
                    isShowingKanbanConfirmation = true
                } label: {
                    Group {
                        if control.isCreatingKanbanTask {
                            ProgressView().controlSize(.small).tint(Color.scifiBg)
                        } else {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13, weight: .bold))
                        }
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.scifiPrimary)
                .opacity(canCreateKanbanTask && !control.isCreatingKanbanTask ? 1 : 0.42)
                .disabled(!canCreateKanbanTask || control.isCreatingKanbanTask)
                .help("Create task")
            }
            TextField("Add context for Hermes (optional)", text: $kanbanBody, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.scifiFg)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.scifiSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(12)
        .background(Color.scifiSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.scifiBorder, lineWidth: 0.5))
    }

    private func kanbanLane(_ lane: KanbanLane) -> some View {
        let laneTasks = control.kanbanTasks.filter { kanbanLane(for: $0) == lane }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: lane.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(lane.color)
                Text(lane.rawValue.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Color.scifiMuted)
                Spacer()
                Text("\(laneTasks.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(lane.color)
            }
            .padding(.horizontal, 3)
            Rectangle().fill(lane.color.opacity(0.55)).frame(height: 1)

            if laneTasks.isEmpty {
                Text("No tasks")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(Color.scifiSurface2)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                ForEach(laneTasks) { task in
                    kanbanTaskCard(task, lane: lane)
                }
            }
        }
        .padding(10)
        .frame(width: 220, alignment: .topLeading)
        .background(Color.black.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.scifiBorder, lineWidth: 0.5))
    }

    private func kanbanTaskCard(_ task: KanbanTaskSummary, lane: KanbanLane) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.scifiFg)
                .lineLimit(3)
            if let detail = task.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scifiMuted)
                    .lineLimit(3)
            }
            HStack(spacing: 6) {
                if let priority = task.priority, !priority.isEmpty {
                    Text("P\(priority)")
                        .foregroundStyle(Color.scifiWarning)
                }
                if let assignee = task.assignee, !assignee.isEmpty {
                    Text(assignee)
                        .lineLimit(1)
                }
                Spacer()
                Text(task.id)
                    .lineLimit(1)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color.scifiTertiary)

            HStack(spacing: 10) {
                if control.capabilityAvailable("kanban.taskDetails") {
                    Button {
                        selectedKanbanTask = task
                        control.loadKanbanTask(task)
                    } label: {
                        ScifiActionLabel(
                            title: "DETAILS",
                            pendingTitle: "LOADING…",
                            isPending: control.isLoadingKanbanDetail,
                            tint: Color.scifiAccent
                        )
                    }
                    .buttonStyle(.scifiPress)
                    .foregroundStyle(Color.scifiMuted)
                    .disabled(control.isLoadingKanbanDetail)
                }
                if lane == .done, control.capabilityAvailable("kanban.archive") {
                    kanbanActionButton("ARCHIVE", task: task, action: .archive)
                } else if lane == .blocked, control.capabilityAvailable("kanban.unblock") {
                    kanbanActionButton("UNBLOCK", task: task, action: .unblock)
                } else {
                    if control.capabilityAvailable("kanban.complete") {
                        kanbanActionButton("DONE", task: task, action: .complete)
                    }
                    if control.capabilityAvailable("kanban.block") {
                        kanbanActionButton("BLOCK", task: task, action: .block)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.scifiSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(lane.color).frame(width: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.scifiBorderLight, lineWidth: 0.5))
    }

    private func kanbanDetailSheet(_ task: KanbanTaskSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("KANBAN TASK")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(Color.scifiAccent)
                Spacer()
                Button("DONE") { selectedKanbanTask = nil }
                    .buttonStyle(.scifiPress)
                    .foregroundStyle(Color.scifiMuted)
            }

            if control.isLoadingKanbanDetail {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("LOADING HERMES TASK…")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.scifiMuted)
                }
            } else if let detail = control.kanbanDetail {
                Text(detail.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.scifiFg)
                HStack(spacing: 10) {
                    Text(detail.status.uppercased())
                    if let priority = detail.priority { Text("P\(priority)") }
                    if let assignee = detail.assignee { Text(assignee) }
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.scifiAccent)
                if let body = detail.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.scifiFg)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Menu {
                    ForEach(KanbanMutationKind.allCases) { kind in
                        if control.capabilityAvailable(kind.capabilityID) {
                            Button(kind.title) {
                                kanbanMutationRequest = KanbanMutationRequest(task: task, kind: kind, value: "", reclaimFirst: false)
                            }
                        }
                    }
                } label: {
                    Label("TASK ACTIONS", systemImage: "ellipsis.circle")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.scifiAccent)
                }
                .menuStyle(.borderlessButton)
                Divider().overlay(Color.scifiBorderLight)
                Text("RUN HISTORY  ·  \(detail.runs.count)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.scifiMuted)
                if detail.runs.isEmpty {
                    Text("No run history returned by Hermes.")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.scifiTertiary)
                } else {
                    ForEach(detail.runs) { run in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(run.status.uppercased())
                                if let outcome = run.outcome { Text(outcome) }
                                Spacer()
                                if let elapsed = run.elapsed { Text(elapsed) }
                            }
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.scifiAccent)
                            if let summary = run.summary {
                                Text(summary)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.scifiMuted)
                            }
                        }
                        .padding(.vertical, 5)
                        .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
                    }
                }
            } else {
                Text("Hermes did not return structured details for this task.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.scifiWarning)
            }
        }
        .padding(20)
        .frame(width: 430, height: 500, alignment: .topLeading)
        .background(Color.scifiBg)
        .environment(\.colorScheme, .dark)
    }

    private func kanbanLane(for task: KanbanTaskSummary) -> KanbanLane {
        let status = task.status.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        if ["done", "completed", "complete", "archived"].contains(status) { return .done }
        if ["blocked", "failed", "error"].contains(status) { return .blocked }
        switch status {
        case "triage": return .triage
        case "todo": return .todo
        case "ready": return .ready
        case "running", "active", "in_progress", "inprogress", "working": return .running
        case "review": return .review
        case "scheduled": return .scheduled
        default: return .todo
        }
    }

    private var canCreateKanbanTask: Bool {
        !kanbanTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func kanbanActionButton(_ label: String, task: KanbanTaskSummary, action: KanbanTaskAction) -> some View {
        let isPending = control.isActionPending(control.kanbanActionID(action, task: task))
        return Button {
            kanbanChangeRequest = KanbanChangeRequest(task: task, action: action)
            isShowingKanbanChangeConfirmation = true
        } label: {
            ScifiActionLabel(
                title: label,
                pendingTitle: "UPDATING…",
                isPending: isPending,
                tint: action == .block || action == .archive ? Color.scifiWarning : Color.scifiAccent
            )
        }
        .buttonStyle(.scifiPress)
        .font(.system(.body, design: .monospaced).weight(.semibold))
        .foregroundStyle(action == .block || action == .archive ? Color.scifiWarning : Color.scifiAccent)
        .disabled(isPending)
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("SEARCH SOURCES")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.scifiAccent)
                    .frame(width: 16)
                TextField("Sessions, projects, Inbox, reminders", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.scifiFg)
                if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.scifiTertiary)
                    }
                    .buttonStyle(.scifiPress)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.scifiControlSurface)
                    .stroke(Color.scifiBorder, lineWidth: 0.5)
            )
            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search across the sources already connected to Hermes.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.scifiFg)
                    Text("Sessions  ·  projects  ·  Inbox  ·  Apple Reminders")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.scifiTertiary)
                }
                .padding(.top, 2)
            } else if control.isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("SEARCHING HERMES SOURCES…")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.scifiMuted)
                }
            } else if control.searchResults.isEmpty {
                emptyState(icon: "questionmark.circle", title: "No matches", detail: "Try a session title, project name, reminder, or Inbox detail.")
            } else {
                sectionLabel("RESULTS  ·  \(control.searchResults.count)")
                ForEach(control.searchResults) { result in
                    let canOpen = result.reference.source != .appleReminder && result.reference.source != .hermesCronJob
                    if canOpen {
                        Button { control.openSearchResult(result) } label: {
                            searchResultRow(result)
                        }
                        .buttonStyle(.scifiPress)
                    } else {
                        searchResultRow(result)
                    }
                }
            }
        }
    }

    private func searchResultRow(_ result: ControlSearchResult) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: result.reference.source == .appleReminder ? "checklist" : "circle.dotted")
                .font(.system(size: 12))
                .foregroundStyle(Color.scifiAccent)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(result.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.scifiFg)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(result.sourceLabel)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.scifiMuted)
                }
                Text(result.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
                    .lineLimit(2)
            }
            if result.reference.source != .appleReminder && result.reference.source != .hermesCronJob {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.scifiTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scifiListRow()
        .contentShape(Rectangle())
    }

    private var inboxContent: some View {
        let visibleItems = control.attention.filter { $0.state == .open && inboxFilter.includes($0) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionLabel("ATTENTION  ·  \(visibleItems.count)")
                Spacer()
                Picker("Inbox filter", selection: $inboxFilter) {
                    ForEach(InboxFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                }
                .labelsHidden()
                .font(.system(size: 11, design: .monospaced))
            }
            if visibleItems.isEmpty {
                emptyState(icon: "checkmark.circle", title: "Nothing needs your attention", detail: "Approvals, failures, clarifications, and due reminders will appear here.")
            } else {
                ForEach(visibleItems) { item in
                    attentionItemRow(item, isSelected: selectedAttentionID == item.id)
                }
            }
            if let error = control.lastError {
                Text(error).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.scifiWarning)
            }
        }
    }

    private func attentionItemRow(_ item: AttentionItem, isSelected: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: item.kind == .approval ? "exclamationmark.triangle" : "circle.dotted")
                    .font(.system(size: 12)).foregroundStyle(item.kind == .approval ? Color.scifiWarning : Color.scifiAccent)
                    .frame(width: 15)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.scifiFg)
                    Text(item.detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.scifiMuted).lineLimit(4)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                ForEach(item.actions.filter { $0 != .dismiss }, id: \.self) { action in
                    let isPending = control.isActionPending(control.attentionActionID(action, item: item))
                    Button {
                        if action == .complete, let reminder = control.reminder(withID: item.reference.sourceID) {
                            reminderForConfirmation = reminder
                            isShowingReminderConfirmation = true
                        } else if action == .respond {
                            clarificationItem = item
                        } else {
                            control.respond(to: item, action: action)
                        }
                    } label: {
                        ScifiActionLabel(
                            title: action.rawValue.uppercased(),
                            pendingTitle: action == .stop ? "STOPPING…" : "WORKING…",
                            isPending: isPending,
                            tint: action == .deny || action == .stop ? Color.scifiWarning : Color.scifiAccent
                        )
                    }
                    .buttonStyle(.scifiPress)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(action == .deny || action == .stop ? Color.scifiWarning : Color.scifiAccent)
                    .disabled(isPending)
                }
                Button("DISMISS") { control.dismiss(item.id) }
                    .buttonStyle(.scifiPress)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
                Button("SNOOZE") { control.snooze(item.id) }
                    .buttonStyle(.scifiPress)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
            }
        }
        .padding(12)
        .scifiGlassPane()
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isSelected ? Color.scifiAccent : .clear, lineWidth: 0.5))
    }

    private var nowContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            let openAttention = control.attention.filter { $0.state == .open }

            HStack(spacing: 8) {
                todayMetric("ATTENTION", value: openAttention.count, color: openAttention.isEmpty ? Color.scifiSuccess : Color.scifiWarning)
                todayMetric("RUNNING", value: control.activeAgents.count + control.processes.count, color: Color.scifiAccent)
                todayMetric("SCHEDULED", value: control.cronJobs.count, color: Color.scifiSuccess)
            }

            if !openAttention.isEmpty {
                attentionItemRow(openAttention.first!, isSelected: false)
                if openAttention.count > 1 {
                    Button("VIEW ALL IN INBOX  ·  \(openAttention.count) ITEMS") { select(.inbox) }
                        .buttonStyle(.scifiPress)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.scifiAccent)
                        .padding(.top, 2)
                }
            } else {
                attentionRow(
                    icon: "checkmark.circle",
                    title: "All clear",
                    detail: "No approvals, clarifications, or failures need a response.",
                    color: .scifiSuccess
                )
            }

            let backgroundSessions = control.activeSessions.filter { $0.id != model.sessionID }
            let hasRunningWork = !backgroundSessions.isEmpty || !control.activeAgents.isEmpty || !control.processes.isEmpty
            if hasRunningWork {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.scifiAccent)
                        Text("LIVE OPERATIONS")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(Color.scifiAccent)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(control.activeAgents) { agent in
                            HStack(spacing: 8) {
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.scifiAccent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.scifiFg)
                                        .lineLimit(1)
                                    Text(agent.sessionID.map { "\($0)  ·  \(agent.state.uppercased())" } ?? agent.state.uppercased())
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Color.scifiTertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .scifiListRow()
                        }

                        ForEach(backgroundSessions) { session in
                            Button {
                                Task {
                                    _ = try? await model.requestControl("session.activate", params: ["session_id": session.id])
                                    model.requestComposerFocus()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Circle().fill(Color.scifiAccent).frame(width: 5, height: 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.title)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Color.scifiFg)
                                            .lineLimit(1)
                                        Text(session.preview ?? session.state.uppercased())
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(Color.scifiTertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.scifiAccent)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .scifiListRow()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.scifiPress)
                        }

                        ForEach(control.processes) { process in
                            HStack(spacing: 8) {
                                Image(systemName: "gearshape.2")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.scifiMuted)
                                Text(process.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.scifiFg)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(process.state.uppercased())
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.scifiTertiary)
                            }
                            .scifiListRow()
                        }
                    }
                }
                .scifiGlassPane()
            }

            if !model.agentActivities.isEmpty || !control.cronRuns.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.scifiMuted)
                        Text("RECENT ACTIVITY")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(Color.scifiMuted)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.agentActivities.suffix(3).reversed())) { activity in
                            todayActivityRow(
                                timestamp: HumanDateFormatting.timeOnly(activity.timestamp),
                                label: activity.kind.replacingOccurrences(of: "subagent.", with: "").uppercased(),
                                detail: activity.text,
                                color: Color.scifiAccent
                            )
                        }
                        ForEach(control.cronRuns.prefix(3)) { run in
                            todayActivityRow(
                                timestamp: run.claimedAt.map(HumanDateFormatting.dateAndTime) ?? "Recent",
                                label: "CRON  ·  \(run.status.uppercased())",
                                detail: run.jobID ?? "Scheduled job execution",
                                color: cronRunIsSuccessful(run) ? Color.scifiSuccess : Color.scifiWarning
                            )
                        }
                    }
                }
                .scifiGlassPane()
            }

            if !control.cronJobs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.scifiMuted)
                        Text("SCHEDULED WORK  ·  \(control.cronJobs.count)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(Color.scifiMuted)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(control.cronJobs.prefix(3)) { job in
                            HStack(spacing: 8) {
                                Circle().fill(job.enabled ? Color.scifiAccent : Color.scifiTertiary)
                                    .frame(width: 5, height: 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.scifiFg)
                                    Text(CronScheduleFormatting.humanReadable(job.schedule))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.scifiFg)
                                    Text(job.schedule)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Color.scifiTertiary)
                                }
                                Spacer(minLength: 0)
                                if job.sessionID != nil {
                                    Button("OPEN") { control.openCronSession(job) }
                                        .buttonStyle(.scifiPress)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.scifiAccent)
                                }
                                Button(job.enabled ? "PAUSE" : "RESUME") {
                                    cronChangeRequest = CronChangeRequest(job: job, enable: !job.enabled)
                                    isShowingCronConfirmation = true
                                }
                                .buttonStyle(.scifiPress)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(job.enabled ? Color.scifiWarning : Color.scifiAccent)
                            }
                            .scifiListRow()
                        }
                    }

                    Button("VIEW ALL AUTOMATIONS") { select(.automations) }
                        .buttonStyle(.scifiPress)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.scifiAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .scifiGlassPane()
            }

            if !control.reminders.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "checklist")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.scifiMuted)
                        Text("REMINDERS  ·  \(control.reminders.count)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(Color.scifiMuted)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(control.reminders.prefix(3)) { reminder in
                            Button {
                                reminderForConfirmation = reminder
                                isShowingReminderConfirmation = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: reminder.isOverdue ? "exclamationmark.circle" : "checklist")
                                        .font(.system(size: 12))
                                        .foregroundStyle(reminder.isOverdue ? Color.scifiWarning : Color.scifiAccent)
                                    Text(reminder.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.scifiFg)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .scifiListRow()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.scifiPress)
                        }
                    }
                }
                .scifiGlassPane()
            }

            let setupCapabilities = unavailableSetupCapabilities
            if !setupCapabilities.isEmpty {
                Button { select(.core) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.scifiWarning)
                            .frame(width: 15)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SETUP  ·  \(setupCapabilities.count)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .tracking(0.7)
                                .foregroundStyle(Color.scifiFg)
                            Text("Review integrations and required permissions in Core.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.scifiTertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.scifiAccent)
                    }
                    .padding(12)
                    .scifiGlassPane()
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.scifiWarning.opacity(0.55), lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.scifiPress)
            }

            if !store.tasks.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.scifiMuted)
                        Text("RECENT TASKS  ·  \(store.tasks.count)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(Color.scifiMuted)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.tasks.prefix(4)) { task in
                            HStack(spacing: 8) {
                                Circle().fill(taskColor(task.status)).frame(width: 5, height: 5)
                                Text(task.title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.scifiFg)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(task.status.rawValue.uppercased())
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(taskColor(task.status))
                            }
                            .scifiListRow()
                        }
                    }
                }
                .scifiGlassPane()
            }

            if activeRepositoryPath != nil {
                repositoryContent
            }
        }
    }

    private func todayMetric(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.55)
                .foregroundStyle(Color.scifiTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .scifiGlassPane()
    }

    private func todayActivityRow(timestamp: String, label: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 5, height: 5).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(color)
                    Text(timestamp)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.scifiTertiary)
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scifiMuted)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scifiListRow()
    }

    private var repositoryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: repository.isGitRepository ? "arrow.triangle.branch" : "folder")
                    .foregroundStyle(repository.isGitRepository ? Color.scifiSuccess : Color.scifiMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(repository.isGitRepository ? repository.branch : "No repository selected")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.scifiFg)
                        .lineLimit(1)
                    if repository.isGitRepository {
                        Text(repository.changedFiles == 0 ? "CLEAN WORKING TREE" : "\(repository.changedFiles) CHANGED FILE\(repository.changedFiles == 1 ? "" : "S")")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(repository.changedFiles == 0 ? Color.scifiSuccess : Color.scifiWarning)
                    } else if let path = activeRepositoryPath {
                        Text(path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.scifiTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isRefreshingRepository { ProgressView().controlSize(.small) }
            }
            if repository.isGitRepository, !repository.latestCommit.isEmpty {
                Text(repository.latestCommit)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
                    .lineLimit(2)
            }
            HStack(spacing: 14) {
                Button("CHANGE REPOSITORY") {
                    showingRepositoryPicker = true
                }
                Button {
                    Task { await refreshRepository() }
                } label: {
                    ScifiActionLabel(
                        title: "REFRESH",
                        pendingTitle: "REFRESHING…",
                        isPending: isRefreshingRepository
                    )
                }
                .disabled(isRefreshingRepository)
            }
            .buttonStyle(.scifiPress)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.scifiAccent)
        }
        .padding(12)
        .scifiGlassPane()
    }

    private func providerSetupCard(_ capability: CapabilityState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(Color.scifiWarning)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 3) {
                Text(capability.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.scifiFg)
                Text(capability.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
                    .lineLimit(2)
                if let recovery = capability.recovery {
                    Text(recovery)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scifiWarning)
                        .lineLimit(2)
                }
                if let command = capability.recoveryCommand {
                    Button("COPY \(command)") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .buttonStyle(.scifiPress)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.scifiAccent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .scifiGlassPane()
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.scifiWarning.opacity(0.55), lineWidth: 0.5))
    }

    private var unavailableSetupCapabilities: [CapabilityState] {
        control.capabilities.filter {
            ["reminders", "notes", "calendar", "messaging", "email"].contains($0.id) && !$0.isAvailable
        }
    }

    private func attentionRow(icon: String, title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.scifiFg)
                Text(detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.scifiTertiary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .scifiListRow()
    }

    private var currentTask: WorkspaceTask? {
        if let sessionID = model.sessionID {
            return store.task(forSessionID: sessionID)
        }
        return store.activeTask
    }

    private var activeRepositoryPath: String? {
        guard let task = currentTask,
              let sessionID = model.sessionID,
              task.sessionID == sessionID else { return nil }
        return task.projectPath
    }

    /// A repository path can be shared by multiple sessions. The task identity
    /// therefore includes the stable Hermes session ID so a session switch
    /// always refreshes Today’s contextual repository projection.
    private var activeRepositoryIdentity: String? {
        guard let sessionID = model.sessionID, let path = activeRepositoryPath else { return nil }
        return "\(sessionID):\(path)"
    }

    private func taskColor(_ status: WorkspaceTaskStatus) -> Color {
        switch status {
        case .todo: .scifiMuted
        case .inProgress: .scifiAccent
        case .awaitingApproval: .scifiWarning
        case .readyForReview: .scifiSuccess
        case .done: .scifiTertiary
        }
    }

    private func refreshRepository() async {
        guard let path = activeRepositoryPath else {
            repository = .empty
            control.setDevelopmentContextProjection(nil)
            isRefreshingRepository = false
            return
        }
        isRefreshingRepository = true
        defer {
            if path == activeRepositoryPath || activeRepositoryPath == nil {
                isRefreshingRepository = false
            }
        }
        let snapshot = await RepositoryService.inspect(path: path)
        guard path == activeRepositoryPath else { return }
        repository = snapshot
        control.setDevelopmentContextProjection(snapshot)
    }

    private func handleRepositoryImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        store.attachProject(at: url.path, toSessionID: model.sessionID)
    }

    private var agentRoster: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                rosterTile(title: "ALL", subtitle: "Hermes", status: model.status.title, color: statusColor, id: nil)
                ForEach(model.activeSubagents) { agent in
                    rosterTile(title: agent.role ?? initials(for: agent.goal), subtitle: shortGoal(agent.goal), status: agent.status, color: nativeAgentColor(agent.status), id: agent.id)
                }
            }
        }
    }

    private func rosterTile(title: String, subtitle: String, status: String, color: Color, id: String?) -> some View {
        Button {
            selectedAgentID = id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    AgentAvatar(identity: id ?? "hermes", statusColor: color)
                        .frame(width: 28, height: 28)
                    Circle().fill(color).frame(width: 5, height: 5)
                }
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(Color.scifiFg)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scifiMuted)
                    .lineLimit(1)
            }
            .frame(width: 82, alignment: .leading)
            .padding(8)
            .background(selectedAgentID == id ? color.opacity(0.12) : Color.scifiSurface4)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selectedAgentID == id ? color.opacity(0.5) : Color.scifiBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.scifiPress)
        .help(status)
    }

    private func activityRow(_ activity: AgentActivity) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(HumanDateFormatting.timeOnly(activity.timestamp))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.scifiTertiary)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.kind.replacingOccurrences(of: "subagent.", with: "").uppercased())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(Color.scifiAccent)
                Text(activity.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.scifiMuted)
                    .lineLimit(2)
            }
        }
    }

    private func initials(for value: String) -> String {
        let words = value.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "-" })
        return words.prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }

    private func shortGoal(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > 22 ? String(clean.prefix(22)) + "…" : clean
    }

    private var coreContent: some View {
        VStack(alignment: .leading, spacing: 17) {
            if !unavailableSetupCapabilities.isEmpty {
                sectionLabel("SETUP NEEDED  ·  \(unavailableSetupCapabilities.count)")
                ForEach(unavailableSetupCapabilities) { capability in
                    providerSetupCard(capability)
                }
                Divider().overlay(Color.scifiBorderLight)
            }

            sectionLabel("SYSTEM STATUS")
            projectionRefreshNotice("core")
            ForEach(control.capabilities.filter { !unavailableSetupCapabilities.contains($0) }) { capability in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(capability.isAvailable ? Color.scifiSuccess : Color.scifiWarning).frame(width: 6, height: 6).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(capability.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.scifiFg)
                        Text(capability.detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.scifiTertiary).lineLimit(2)
                        if let recovery = capability.recovery {
                            Text(recovery).font(.system(size: 12)).foregroundStyle(Color.scifiWarning).lineLimit(2)
                        }
                        if let command = capability.recoveryCommand {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            } label: {
                                Label("COPY \(command)", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.scifiPress)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.scifiAccent)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if control.sessionUsage != nil || control.sessionContext != nil {
                Divider().overlay(Color.scifiBorderLight)
                sectionLabel("SESSION COCKPIT")
                if let usage = control.sessionUsage {
                    diagnosticRow(label: "TOKENS", value: "(usage.totalTokens) total  ·  (usage.inputTokens) in  ·  (usage.outputTokens) out", color: Color.scifiAccent)
                    if let model = usage.model { diagnosticRow(label: "MODEL", value: model, color: Color.scifiTertiary) }
                    if let percent = usage.contextPercent {
                        diagnosticRow(label: "CONTEXT", value: String(format: "%.1f%%", percent), color: percent > 85 ? Color.scifiWarning : Color.scifiSuccess)
                    }
                }
                if let context = control.sessionContext, !context.categories.isEmpty {
                    ForEach(context.categories.prefix(6)) { category in
                        diagnosticRow(label: category.label.uppercased(), value: "(category.tokens) tokens", color: Color.scifiTertiary)
                    }
                }
                HStack(spacing: 8) {
                    TextField("Steer the active turn…", text: $sessionSteerText)
                        .textFieldStyle(.scifiGlass)
                    Button("STEER") {
                        control.steerActiveSession(sessionSteerText)
                        sessionSteerText = ""
                    }
                    .buttonStyle(.scifiPress)
                    .foregroundStyle(Color.scifiAccent)
                    .disabled(sessionSteerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if !control.diagnostics.isEmpty {
                Divider().overlay(Color.scifiBorderLight)
                sectionLabel("READ-ONLY DIAGNOSTICS")
                ForEach(control.diagnostics) { diagnostic in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(diagnostic.isAvailable ? Color.scifiSuccess : Color.scifiWarning)
                            .frame(width: 6, height: 6)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(diagnostic.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.scifiFg)
                            Text(diagnostic.detail)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.scifiTertiary)
                                .lineLimit(3)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            if !control.journeyNodes.isEmpty || control.sessionStoreStatus != nil || control.memoryHealthStatus != nil {
                Divider().overlay(Color.scifiBorderLight)
                sectionLabel("HERMES LEARNING & STORAGE")
                ForEach([control.sessionStoreStatus, control.memoryHealthStatus].compactMap { $0 }) { status in
                    diagnosticRow(label: status.title.uppercased(), value: status.detail, color: status.isAvailable ? Color.scifiSuccess : Color.scifiWarning)
                }
                if !control.journeyNodes.isEmpty {
                    Text("JOURNEY  ·  \(control.journeyNodes.count) NODES")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.scifiTertiary)
                    ForEach(control.journeyNodes.prefix(8)) { node in
                        HStack(spacing: 7) {
                            Circle().fill(node.state == "active" ? Color.scifiSuccess : Color.scifiMuted).frame(width: 5, height: 5)
                            Text(node.label).font(.system(size: 12)).foregroundStyle(Color.scifiFg).lineLimit(1)
                            Spacer()
                            Text([node.kind, node.useCount.map { "\($0)x" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.scifiTertiary)
                        }
                    }
                }
            }
            Divider().overlay(Color.scifiBorderLight)
            sectionLabel("NOTIFICATIONS")
            Toggle(isOn: Binding(
                get: { model.completionNotificationsEnabled },
                set: { model.setCompletionNotificationsEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Completion alerts")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.scifiFg)
                    Text("Notify when Hermes finishes a request while the Dock is hidden.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scifiTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.scifiAccent)
            Divider().overlay(Color.scifiBorderLight)
            sectionLabel("QUICK CAPTURE")
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Hermes Control")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.scifiFg)
                    Text("Global shortcut focuses Ask from any app.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scifiTertiary)
                }
                Spacer()
                KeyboardShortcuts.Recorder("", name: .toggleHermesControl)
                    .frame(width: 120)
            }
            Divider().overlay(Color.scifiBorderLight)
            HStack {
                sectionLabel("HERMES CONFIGURATION")
                Spacer()
                Button(action: { model.refreshRuntimeConfiguration() }) {
                    if model.isLoadingRuntimeConfiguration {
                        ProgressView().controlSize(.small).tint(Color.scifiAccent)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.scifiAccent)
                    }
                }
                .buttonStyle(.scifiPress)
                .disabled(model.isLoadingRuntimeConfiguration)
            }

            if model.isLoadingRuntimeConfiguration && model.runtimeConfiguration == nil {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("READING HERMES RUNTIME…").font(.system(size: 12, design: .monospaced)).tracking(0.6).foregroundStyle(Color.scifiMuted)
                }
            } else if let configuration = model.runtimeConfiguration {
                diagnosticRow(label: "MODEL", value: configuration.model ?? "NOT CONFIGURED", color: configuration.model == nil ? Color.scifiWarning : Color.scifiSuccess)
                diagnosticRow(label: "PROVIDER", value: configuration.provider ?? "NOT CONFIGURED", color: configuration.provider == nil ? Color.scifiWarning : Color.scifiSuccess)
                if model.runtimeModelOptions.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("LOADING HERMES MODEL CATALOG…").font(.system(size: 12, design: .monospaced)).tracking(0.5).foregroundStyle(Color.scifiMuted)
                    }
                } else {
                    Menu {
                        ForEach(model.runtimeModelOptions) { option in
                            Button {
                                selectedModelID = option.id
                            } label: {
                                HStack {
                                    Text(option.displayName)
                                    if option.id == selectedModelID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(selectedModelDisplayName)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.scifiFg)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.scifiMuted)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 36)
                        .background(Color.scifiControlSurface)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.scifiBorder, lineWidth: 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.scifiPress)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: selectedModelID) { _, id in
                        guard let option = model.runtimeModelOptions.first(where: { $0.id == id }),
                              option.model != configuration.model || option.provider != configuration.provider else { return }
                        model.updateRuntimeModel(option)
                    }
                }
                Text("Catalog is supplied live by Hermes. Selection updates provider and model for new sessions.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
                if let error = model.runtimeConfigurationError {
                    Text(error)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.scifiWarning)
                }
                if let path = configuration.configPath {
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.scifiTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Divider().overlay(Color.scifiBorderLight)
                sectionLabel("EXECUTION")
                if let turns = configuration.maxTurns {
                    diagnosticRow(label: "MAX TURNS", value: turns, color: Color.scifiMuted)
                }
                if let timeout = configuration.terminalTimeout {
                    diagnosticRow(label: "TERMINAL TIMEOUT", value: "\(timeout)S", color: Color.scifiMuted)
                }

                Divider().overlay(Color.scifiBorderLight)
                sectionLabel("INSTALLED SKILLS  ·  \(configuration.skills.count)")
                configurationList(configuration.skills, empty: "No enabled skills reported by Hermes.")

                Divider().overlay(Color.scifiBorderLight)
                sectionLabel("MCP SERVERS  ·  \(configuration.mcpServers.count)")
                configurationList(configuration.mcpServers, empty: "No MCP servers configured in Hermes.")
                if control.mcpInventoryAvailable {
                    if control.mcpServers.isEmpty {
                        Text("Hermes reports no configured MCP connections.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.scifiTertiary)
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(control.mcpServers) { server in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(server.isEnabled ? Color.scifiSuccess : Color.scifiMuted)
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Color.scifiFg)
                                        Text("\(server.transport)  ·  \(server.tools)")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(Color.scifiTertiary)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(server.isEnabled ? "ENABLED" : "DISABLED")
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(server.isEnabled ? Color.scifiSuccess : Color.scifiMuted)
                                        if control.capabilityAvailable("mcp.test") {
                                            Button { control.testMCP(server) } label: {
                                                ScifiActionLabel(
                                                    title: "TEST",
                                                    pendingTitle: "TESTING…",
                                                    isPending: control.isActionPending(control.mcpTestActionID(server))
                                                )
                                            }
                                                .buttonStyle(.scifiPress)
                                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(Color.scifiAccent)
                                                .disabled(control.isActionPending(control.mcpTestActionID(server)))
                                        }
                                    }
                                }
                                if let result = control.mcpTestResults[server.id] {
                                    Text(result)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Color.scifiTertiary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
                if model.sessionID != nil {
                    Button { isShowingMCPReloadConfirmation = true } label: {
                        ScifiActionLabel(
                            title: "RELOAD MCP TOOLS",
                            pendingTitle: "RELOADING…",
                            isPending: control.isActionPending(control.reloadMCPActionID)
                        )
                    }
                        .buttonStyle(.scifiPress)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.scifiAccent)
                        .disabled(control.isActionPending(control.reloadMCPActionID))
                }

                if !configuration.plugins.isEmpty {
                    Divider().overlay(Color.scifiBorderLight)
                    sectionLabel("ENABLED PLUGINS  ·  \(configuration.plugins.count)")
                    configurationList(configuration.plugins, empty: "")
                }
            } else {
                emptyState(icon: "exclamationmark.triangle", title: "Runtime unavailable", detail: "Hermes configuration could not be read. Start Hermes, then refresh.")
            }
        }
        .task {
            model.refreshRuntimeConfiguration()
            model.refreshRuntimeModelOptions()
        }
        .onChange(of: model.runtimeConfiguration) { _, configuration in
            guard let configuration,
                  let matching = model.runtimeModelOptions.first(where: { $0.model == configuration.model && $0.provider == configuration.provider }) else { return }
            selectedModelID = matching.id
        }
        .onChange(of: model.runtimeModelOptions) { _, options in
            guard let configuration = model.runtimeConfiguration,
                  let matching = options.first(where: { $0.model == configuration.model && $0.provider == configuration.provider }) else { return }
            selectedModelID = matching.id
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(.body, design: .monospaced).weight(.semibold)).tracking(1.1).foregroundStyle(Color.scifiMuted)
    }

    @ViewBuilder
    private func projectionRefreshNotice(_ projection: String) -> some View {
        if let state = control.refreshState(for: projection) {
            if state.isRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(state.isStale ? "Refreshing — showing last successful data" : "Refreshing Hermes data…")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.scifiTertiary)
            } else if let error = state.error {
                Text(state.isStale ? "Showing last successful data. \(error)" : error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.scifiWarning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let lastSuccess = state.lastSuccess {
                Text("Updated \(HumanDateFormatting.timeOnly(lastSuccess))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
            }
        }
    }

    private func agentRow(_ agent: HermesSubagent, expanded: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(nativeAgentColor(agent.status))
                .frame(width: 7, height: 7)
                .shadow(color: nativeAgentColor(agent.status).opacity(0.7), radius: 4)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.goal)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.scifiFg)
                    .lineLimit(expanded ? 4 : 2)
                if let role = agent.role {
                    Text("ROLE  \(role.uppercased())\(agent.sourceSkill.map { "  ·  \($0)" } ?? "")")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(0.35)
                        .foregroundStyle(Color.scifiAccent)
                }
                Text("\(agent.status.uppercased())  ·  \(agent.toolCount) TOOLS\(agent.model.map { "  ·  \($0.uppercased())" } ?? "")")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(nativeAgentColor(agent.status))
                if expanded, let latest = agent.latestActivity {
                    Text(latest)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.scifiTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Color.scifiBorderLight.opacity(0.7).frame(height: 0.5) }
    }

    private func eventRow(_ event: AgentEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.scifiAccent.opacity(0.75))
                .frame(width: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.type.uppercased()).font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(0.35).foregroundStyle(Color.scifiMuted)
                Text(event.detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.scifiTertiary).lineLimit(2)
            }
        }
    }

    private func diagnosticRow(label: String, value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(0.8).foregroundStyle(Color.scifiTertiary)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(0.35).foregroundStyle(Color.scifiFg).lineLimit(1)
            }
        }
    }

    private var selectedModelDisplayName: String {
        model.runtimeModelOptions.first(where: { $0.id == selectedModelID })?.displayName
            ?? model.runtimeConfiguration.map { "\($0.provider ?? "provider")  /  \($0.model ?? "model")" }
            ?? "Select Hermes model"
    }

    private func configurationList(_ values: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if values.isEmpty {
                Text(empty)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 0), alignment: .leading),
                        GridItem(.flexible(minimum: 0), alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(Array(values.prefix(8).enumerated()), id: \.offset) { _, value in
                        HStack(spacing: 7) {
                            Circle().fill(Color.scifiAccent.opacity(0.65)).frame(width: 4, height: 4)
                            Text(value)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.scifiFg)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if values.count > 8 {
                    Text("+ \(values.count - 8) MORE")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(0.65)
                        .foregroundStyle(Color.scifiTertiary)
                }
            }
        }
    }

    private func capabilityRow(icon: String, title: String, detail: String, state: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.scifiFg)
                Text(detail).font(.system(size: 12)).foregroundStyle(Color.scifiTertiary)
            }
            Spacer(minLength: 3)
            Text(state).font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(0.45).foregroundStyle(color)
        }
    }

    private var latestModelName: String? {
        model.messages.reversed().compactMap(\.modelName).first
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(Color.scifiTertiary)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.scifiFg)
            Text(detail).font(.system(size: 12)).foregroundStyle(Color.scifiMuted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nativeAgentColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "running", "finalizing": .scifiAccent
        case "complete", "completed": .scifiSuccess
        case "blocked", "stalled", "error": .scifiWarning
        default: .scifiMuted
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: .scifiSuccess
        case .working: .scifiAccent
        case .needsApproval: .scifiWarning
        case .offline: .scifiDestructive
        }
    }
}

struct DockPopover: View {
    @ObservedObject var model: DockModel
    var onWorkspaceWidthChange: (CGFloat) -> Void = { _ in }
    @State private var isConversationAtBottom = true
    @State private var isWorkspaceManuallyExpanded = true
    @State private var isNarrowLayout = false
    @State private var isNarrowControlVisible = true
    @State private var isComposerPulsing = false
    @State private var pasteMonitor: Any?
    @State private var showingImagePicker = false
    @FocusState private var isComposerFocused: Bool
    @StateObject private var speechInput = SpeechInput()
    @StateObject private var voiceOutput = VoiceOutput()
    @StateObject private var workspaceStore = WorkspaceStore()
    @StateObject private var controlCenter = ControlCenterModel()
    @State private var inputMode: InputMode = .chat
    @State private var suppressNextVoiceResponse = false

    private enum InputMode {
        case chat, talk
    }

    private enum QuickPrompt: CaseIterable, Identifiable {
        case reminder, notes, research, summarize, automation, review, email, message, search, kanban

        var id: Self { self }
        var label: String {
            switch self {
            case .reminder: "Reminder"
            case .notes: "Save to Notes"
            case .research: "Research"
            case .summarize: "Summarize work"
            case .automation: "Recurring automation"
            case .review: "Review work"
            case .email: "Email"
            case .message: "Message"
            case .search: "Search sources"
            case .kanban: "Kanban task"
            }
        }
        var prompt: String {
            switch self {
            case .reminder: "Create an Apple Reminder for: "
            case .notes: "Save the following to Apple Notes: "
            case .research: "Start research on: "
            case .summarize: "Summarize my active work and list the next actions."
            case .automation: "Help me create a recurring automation for: "
            case .review: "Review my completed work and identify anything that needs follow-up."
            case .email: "Using the Himalaya skill, help me draft or send this email: "
            case .message: "Using the configured messaging skill, help me draft or send this message: "
            case .search: "Search all connected Hermes sources for: "
            case .kanban: "Create or update a Hermes Kanban task for: "
            }
        }

        var requiredCapability: String? {
            switch self {
            case .reminder: "reminders"
            case .notes: "notes"
            case .automation: "rpc-scheduling"
            case .email: "email"
            case .message: "messaging"
            case .kanban: "kanban.create"
            case .research, .summarize, .review, .search: nil
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if inputMode == .talk {
                    voiceMode
                } else {
                    header
                    if model.isShowingSessions {
                        sessionPicker
                        Divider().overlay(Color.scifiBorderLight)
                    }
                    conversation
                    Divider().overlay(Color.scifiBorderLight)
                    composer
                }
            }
            .frame(width: 420, height: 640)

            // The Control workspace belongs to the popup, not to chat mode.
            // Voice swaps only the left-hand surface and keeps this pane live.
            if isWorkspaceVisibleForLayout {
                Rectangle().fill(Color.scifiBorderLight).frame(width: 0.5)
                WorkspaceActivitySidebar(model: model, store: workspaceStore, control: controlCenter, onClose: {
                    if isNarrowLayout {
                        isNarrowControlVisible = false
                    } else {
                        isWorkspaceManuallyExpanded = false
                    }
                })
                    .frame(width: isNarrowLayout ? 420 : 540, height: 640)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: isWorkspaceVisibleForLayout ? (isNarrowLayout ? 420 : 960) : 420, height: 640)
        .background {
            ZStack {
                Color(red: 0.055, green: 0.065, blue: 0.115)
                RadialGradient(
                    colors: [Color.scifiAccent.opacity(0.09), .clear],
                    center: UnitPoint(x: 0.15, y: 0),
                    startRadius: 0,
                    endRadius: 360
                )
            }
            .background(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.scifiBorderLight, lineWidth: 0.5)
        }
        .animation(.scifiEase(duration: 0.35), value: isWorkspaceVisibleForLayout)
        .environment(\.colorScheme, .dark)
        .fileImporter(isPresented: $showingImagePicker, allowedContentTypes: [.png, .jpeg, .image]) { result in
            if case .success(let url) = result {
                model.stageImageFile(at: url)
            }
        }
        .task { model.restoreLatestSessionIfNeeded() }
        .onAppear {
            isNarrowLayout = (NSScreen.main?.visibleFrame.width ?? 1200) < 1000
            onWorkspaceWidthChange(isWorkspaceVisibleForLayout ? (isNarrowLayout ? 420 : 960) : 420)
            synchronizeWorkspace()
            controlCenter.bind(to: model)
            controlCenter.refresh()
        }
        .onChange(of: isWorkspaceVisible) { _, visible in
            if isNarrowLayout { isNarrowControlVisible = visible }
            onWorkspaceWidthChange(isWorkspaceVisibleForLayout ? (isNarrowLayout ? 420 : 960) : 420)
        }
        .onChange(of: model.composerFocusRequest) { _, _ in
            isComposerFocused = true
        }
        .onChange(of: speechInput.completedTranscript) { _, transcript in
            guard let transcript, !transcript.isEmpty, !model.isSending else { return }
            guard !voiceOutput.isSpeaking else {
                speechInput.consumeCompletedTranscript()
                return
            }
            model.draft = transcript
            speechInput.consumeCompletedTranscript()
            model.send()
        }
        .onChange(of: speechInput.isRecording) { _, isRecording in
            if !isRecording, speechInput.errorMessage != nil {
                inputMode = .chat
            }
        }
        .onChange(of: model.status) { _, status in
            synchronizeWorkspace(status: status)
            guard inputMode == .talk, status == .idle, !model.voiceState.isNativeConversationActive else { return }
            if suppressNextVoiceResponse {
                suppressNextVoiceResponse = false
                resumeVoiceConversationIfReady()
                return
            }
            if let response = model.messages.last(where: { $0.role == .hermes }),
               !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                speechInput.stopForAssistantSpeech()
                voiceOutput.speak(messageID: response.id, text: response.text)
            } else {
                resumeVoiceConversationIfReady()
            }
        }
        .onChange(of: voiceOutput.isSpeaking) { _, isSpeaking in
            if !isSpeaking, !model.voiceState.isNativeConversationActive {
                resumeVoiceConversationIfReady()
            }
        }
        .onChange(of: model.voiceState) { _, state in
            if state == .interrupted {
                // The native gateway has accepted a spoken interruption. Stop
                // any fallback playback immediately before it resumes capture.
                voiceOutput.stop()
            }
            if case .localFallback = state {
                resumeVoiceConversationIfReady()
            }
        }
        .onChange(of: model.sessionID) { _, _ in synchronizeWorkspace() }
        .onChange(of: model.currentSessionTitle) { _, _ in synchronizeWorkspace() }
        .onChange(of: model.messages) { _, _ in synchronizeWorkspace() }
    }

    private var isWorkspaceVisible: Bool {
        isWorkspaceManuallyExpanded || !model.activeSubagents.isEmpty
    }

    private var isWorkspaceVisibleForLayout: Bool {
        isNarrowLayout ? isNarrowControlVisible : isWorkspaceVisible
    }

    private func synchronizeWorkspace(status: HermesStatus? = nil) {
        guard let sessionID = model.sessionID else { return }
        let title = model.currentSessionTitle
            ?? model.messages.first(where: { $0.role == .user })?.text
            ?? "Current Hermes task"
        let task = workspaceStore.ensureTask(title: title, sessionID: sessionID)

        switch status ?? model.status {
        case .working:
            workspaceStore.updateStatus(.inProgress, for: task.id)
        case .needsApproval:
            workspaceStore.updateStatus(.awaitingApproval, for: task.id)
        case .idle where task.status == .inProgress || task.status == .awaitingApproval:
            workspaceStore.updateStatus(.readyForReview, for: task.id)
        case .idle, .offline:
            break
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Button(action: { model.toggleSessions() }) {
                HStack(spacing: 9) {
                    ZStack {
                        Circle().fill(connectionColor.opacity(0.13)).frame(width: 24, height: 24)
                        Image(systemName: "link.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(connectionColor)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.currentSessionTitle ?? "Untitled chat")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.scifiFg)
                            .lineLimit(1)
                        Text("HERMES CONSOLE")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .tracking(1.05)
                            .foregroundStyle(Color.scifiTertiary)
                    }
                    Image(systemName: model.isShowingSessions ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.scifiMuted)
                }
            }
            .buttonStyle(.scifiPress)

            Spacer()

            // Keep the visual rhythm compact while the surrounding hit targets stay 44pt.
            HStack(spacing: 4) {
                Button(action: {
                    inputMode = .talk
                    beginVoiceConversation()
                }) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.scifiMuted)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.scifiSurface4))
                }
                .buttonStyle(.scifiPress)
                .dockHitTarget()
                .help("Talk mode")

                Button(action: {
                    if isNarrowLayout {
                        isNarrowControlVisible.toggle()
                    } else {
                        isWorkspaceManuallyExpanded.toggle()
                    }
                }) {
                    Image(systemName: isWorkspaceVisibleForLayout ? "rectangle.compress.vertical" : "rectangle.split.2x1")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isWorkspaceVisibleForLayout ? Color.scifiAccent : Color.scifiMuted)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(isWorkspaceVisibleForLayout ? Color.scifiAccent.opacity(0.1) : Color.scifiSurface4))
                }
                .buttonStyle(.scifiPress)
                .dockHitTarget()
                .help(isWorkspaceVisibleForLayout ? "Hide Control" : "Show Control")

                if model.status == .working || model.isSending {
                    Button(action: stopCurrentRequest) {
                        Image(systemName: "square.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.scifiMuted)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.scifiSurface4))
                    }
                    .buttonStyle(.scifiPress)
                    .dockHitTarget()
                    .help("Stop")
                }

                Button(action: { model.newChat() }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.scifiMuted)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.scifiSurface4))
                }
                .buttonStyle(.scifiPress)
                .dockHitTarget()
                .help("New chat")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(Color.scifiSurface2)
        .overlay(alignment: .bottom) {
            Color.scifiBorderLight.frame(height: 0.5)
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: .scifiSuccess
        case .working: .scifiAccent
        case .needsApproval: .scifiWarning
        case .offline: .scifiDestructive
        }
    }

    private var connectionColor: Color {
        model.isHermesConnected ? .scifiSuccess : .scifiDestructive
    }

    private var sessionPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CONVERSATIONS")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(Color.scifiAccent.opacity(0.8))
                Spacer()
                if model.isLoadingSessions {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Button(action: { model.loadSessions() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.scifiMuted)
                    }
                    .buttonStyle(.scifiPress)
                    .help("Refresh")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if model.sessions.isEmpty && !model.isLoadingSessions {
                Text("No saved conversations")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scifiMuted)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else {
                List {
                    ForEach(model.sessions) { session in
                        Button(action: { model.resumeSession(session) }) {
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(session.displayTitle)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .foregroundStyle(Color.scifiFg)
                                    if !session.preview.isEmpty {
                                        Text(session.preview)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(Color.scifiMuted)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if let date = session.startedAt {
                                    Text(date, style: .relative)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Color.scifiTertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.scifiPress)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 150)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private var conversation: some View {
        if speechInput.isRecording {
            voiceMode
        } else {
            chatScroll
        }
    }

    private var voiceMode: some View {
        VStack(spacing: 0) {
            VoiceModeToolbar(
                onReturnToChat: exitVoiceMode,
                onToggleWorkspace: {
                    if isNarrowLayout {
                        isNarrowControlVisible.toggle()
                    } else {
                        isWorkspaceManuallyExpanded.toggle()
                    }
                },
                isWorkspaceVisible: isWorkspaceVisibleForLayout,
                canStopRequest: model.status == .working || model.isSending,
                onStopRequest: stopCurrentRequest
            )
            .padding(14)
            Spacer()
            Button {
                if model.voiceState.isNativeConversationActive || speechInput.isRecording {
                    exitVoiceMode()
                } else if !model.isSending && !voiceOutput.isSpeaking {
                    voiceOutput.stop()
                    beginVoiceConversation()
                }
            } label: {
                VoiceOrbView(
                    isListening: model.voiceState == .listening || speechInput.isRecording,
                    isResponding: model.voiceState == .preparing || model.voiceState == .interrupted || model.voiceState == .thinking || (model.status == .working && !speechInput.isRecording) || voiceOutput.isSpeaking,
                    audioLevel: speechInput.audioLevel
                )
                    .frame(width: 320, height: 320)
            }
            .buttonStyle(.scifiPress)
            .help(model.voiceState.isNativeConversationActive || speechInput.isRecording ? "End voice conversation" : "Resume listening")
            .overlay(alignment: .bottom) {
                if let detail = model.voiceState.fallbackDetail {
                    Text("LOCAL FALLBACK · \(detail)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .tracking(0.35)
                        .foregroundStyle(Color.scifiWarning)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 270)
                        .offset(y: 42)
                } else if model.voiceState.isNativeConversationActive {
                    VStack(spacing: 5) {
                        Text(model.voiceState.label)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .tracking(0.75)
                            .foregroundStyle(model.voiceState == .listening ? Color.scifiSuccess : Color.scifiAccent)
                        if let timing = model.voiceTelemetry.summary {
                            Text(timing)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .tracking(0.45)
                                .foregroundStyle(Color.scifiTertiary)
                        }
                    }
                    .offset(y: 42)
                } else if model.status == .working && !speechInput.isRecording {
                    voiceActivityIndicator
                        .offset(y: 34)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .animation(.scifiEase(duration: 0.25), value: model.status)
        .onAppear { beginVoiceConversation() }
    }

    private func beginVoiceConversation() {
        if case .localFallback = model.voiceState {
            resumeVoiceConversationIfReady()
        } else {
            model.startVoiceConversation()
        }
    }

    private func resumeVoiceConversationIfReady() {
        guard inputMode == .talk,
              !model.voiceState.isNativeConversationActive,
              model.status == .idle,
              !model.isSending,
              !speechInput.isRecording,
              !speechInput.isStarting,
              !speechInput.isUnavailable,
              speechInput.errorMessage == nil,
              !voiceOutput.isSpeaking else { return }
        speechInput.startListening()
    }

    private func exitVoiceMode() {
        speechInput.stop()
        voiceOutput.stop()
        model.stopVoiceConversation()
        inputMode = .chat
    }

    private func stopCurrentRequest() {
        if inputMode == .talk {
            suppressNextVoiceResponse = true
            voiceOutput.stop()
        }
        model.stop()
    }

    private var voiceActivityIndicator: some View {
        HStack(spacing: 8) {
            ThinkingDots()
            Text(voiceActivityText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .lineLimit(1)
        }
        .foregroundStyle(Color.scifiAccent)
        .padding(.horizontal, 13)
        .frame(height: 32)
        .background(Capsule().fill(Color.scifiSurface6).stroke(Color.scifiAccent.opacity(0.25), lineWidth: 0.5))
        .shadow(color: Color.scifiAccent.opacity(0.12), radius: 10)
    }

    private var voiceActivityText: String {
        if let reasoning = model.reasoningState, !reasoning.text.isEmpty {
            return "HERMES IS REASONING"
        }
        if let tool = model.activeToolCalls.first(where: { !$0.isComplete }) {
            return "RUNNING \(tool.name.uppercased())"
        }
        return "HERMES IS THINKING"
    }

    private var chatScroll: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.messages.isEmpty && model.status != .working {
                            StartupAssistantView()
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: max(300, viewport.size.height - 16))
                        }
                        let msgList = model.messages
                        ForEach(msgList) { message in
                            let isLast = message.id == msgList.last?.id
                            if model.status == .working && message.role == .hermes && isLast {
                                activityView.id("activity")
                            }
                            messageRow(message)
                                .id(message.id)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.97)),
                                    removal: .opacity
                                ))
                        }
                        if model.status == .working && model.messages.last?.role != .hermes {
                            activityView
                                .id("activity")
                        }
                        if let approval = model.approvalText {
                            approvalRow(title: model.approvalTitle ?? "Review requested action", detail: approval)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("conversationBottom")
                            .background(
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: ConversationBottomPreferenceKey.self,
                                        value: geometry.frame(in: .named("conversationScroll")).maxY
                                    )
                                }
                            )
                    }
                    .padding(.vertical, 8)
                }
                .coordinateSpace(name: "conversationScroll")
                .onPreferenceChange(ConversationBottomPreferenceKey.self) { bottomY in
                    isConversationAtBottom = bottomY <= viewport.size.height + 32
                }
                .animation(Animation.scifiEase(duration: 0.4), value: model.messages.count)
                .onChange(of: model.messages.count) { _, _ in
                    if isConversationAtBottom, let last = model.messages.last {
                        withAnimation(.scifiEase(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: model.activeToolCalls) { _, _ in
                    if model.status == .working && isConversationAtBottom {
                        withAnimation(.scifiEase(duration: 0.2)) {
                            proxy.scrollTo("conversationBottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: model.reasoningState) { _, _ in
                    if model.status == .working && isConversationAtBottom {
                        withAnimation(.scifiEase(duration: 0.2)) {
                            proxy.scrollTo("conversationBottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: model.recentEvents.last) { _, _ in
                    if model.status == .working,
                       let event = model.recentEvents.last,
                       isAutoScrollEvent(event.type),
                       isConversationAtBottom {
                        withAnimation(.scifiEase(duration: 0.2)) {
                            proxy.scrollTo("conversationBottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var activityView: some View {
        HStack(spacing: 6) {
            ThinkingDots()
            Text(currentActivityStatus)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.scifiMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The activity row deliberately represents one current state. Showing a
    /// history of streaming events here pushes the conversation out of view.
    private var currentActivityStatus: String {
        if let tool = model.activeToolCalls.last(where: { !$0.isComplete }) {
            return "Running \(activityLabel(for: tool.name))"
        }
        if let reasoning = model.reasoningState, !reasoning.isComplete {
            return reasoning.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Thinking"
                : "Reasoning"
        }
        if let event = model.recentEvents.last(where: isUrgentActivityEvent) {
            return activityLabel(for: event.type)
        }
        return "Thinking"
    }

    private func isUrgentActivityEvent(_ event: AgentEvent) -> Bool {
        let type = event.type.lowercased()
        return type.contains("approval") ||
            type.contains("error") ||
            type.contains("permission") ||
            type.contains("warning")
    }

    private func activityLabel(for rawValue: String) -> String {
        let normalized = rawValue
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.capitalized }
            .joined(separator: " ")
        return normalized.isEmpty ? "Task" : normalized
    }

    private func isAutoScrollEvent(_ type: String) -> Bool {
        let type = type.lowercased()
        return type.contains("tool") ||
            type.contains("reason") ||
            type.contains("think") ||
            type == "message.start"
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.role == .hermes && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.image == nil {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 0) {
                if message.role == .user {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(HumanDateFormatting.timeOnly(message.timestamp))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.scifiTertiary)
                            Text("You")
                                .font(.system(size: 12, weight: .semibold))
                                .tracking(1.0)
                                .textCase(.uppercase)
                                .foregroundStyle(Color.scifiMuted)
                        }
                        .padding(.horizontal, 4)

                        VStack(alignment: .trailing, spacing: 6) {
                            if let image = message.image {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 220, maxHeight: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            if !message.text.isEmpty {
                                Text(message.text)
                                    .font(.system(size: 14))
                                    .textSelection(.enabled)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Color.scifiFg)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.scifiAccentMuted)
                    .clipShape(MessageBubbleShape(isUser: true))
                    .overlay(
                        MessageBubbleShape(isUser: true)
                            .stroke(Color.scifiAccent.opacity(0.15), lineWidth: 0.5)
                    )
                    .shadow(color: Color.scifiAccent.opacity(0.05), radius: 4)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Hermes")
                                .font(.system(size: 12, weight: .semibold))
                                .tracking(1.0)
                                .textCase(.uppercase)
                                .foregroundStyle(Color.scifiMuted)
                            Text(HumanDateFormatting.timeOnly(message.timestamp))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.scifiTertiary)
                            if let modelName = message.modelName {
                                Text("· \(modelName)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Color.scifiTertiary)
                            }
                        }
                        .padding(.horizontal, 4)

                        if message.text.isEmpty {
                            EmptyView()
                        } else {
                            MarkdownMessageView(markdown: message.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .foregroundStyle(Color.scifiFg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.scifiSurface)
                    .clipShape(MessageBubbleShape(isUser: false))
                    .overlay(
                        MessageBubbleShape(isUser: false)
                            .stroke(Color.scifiBorder, lineWidth: 0.5)
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func reasoningBlock(_ reasoning: ReasoningState) -> some View {
        DisclosureGroup(isExpanded: $model.isShowingReasoning) {
            Text(reasoning.text.isEmpty ? "…" : reasoning.text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(Color.scifiMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12))
                Text("Reasoning")
                    .font(.system(size: 12, weight: .medium))
                if !reasoning.isComplete {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                }
            }
            .foregroundStyle(Color.scifiMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.scifiSurface)
                .stroke(Color.scifiBorderLight, lineWidth: 0.5)
        )
    }

    private func approvalRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.scifiWarning)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approval required")
                        .font(.system(size: 14, weight: .semibold))
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.scifiWarning)
                        .lineLimit(2)
                }
                .foregroundStyle(Color.scifiFg)
                Spacer()
                Text("ACTION NEEDED")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Color.scifiWarning)
            }

            Text(detail)
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(Color.scifiFg)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.16))
                        .stroke(Color.scifiBorderLight, lineWidth: 0.5)
                )

            HStack(spacing: 6) {
                Button { model.respondToApproval("deny") } label: {
                    ScifiActionLabel(
                        title: "Deny",
                        pendingTitle: "Working…",
                        isPending: model.isRespondingToApproval,
                        tint: Color.scifiWarning
                    )
                }
                .buttonStyle(.scifiPress)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.scifiWarning)
                .frame(minWidth: 88, minHeight: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.scifiWarning.opacity(0.08))
                        .stroke(Color.scifiWarning.opacity(0.34), lineWidth: 0.5)
                )
                .disabled(model.isRespondingToApproval)
                Button { model.respondToApproval("once") } label: {
                    ScifiActionLabel(
                        title: "Allow once",
                        pendingTitle: "Allowing…",
                        isPending: model.isRespondingToApproval,
                        tint: Color.scifiBg
                    )
                }
                .buttonStyle(.scifiPress)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.scifiBg)
                .frame(minWidth: 112, minHeight: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.scifiAccent)
                )
                .disabled(model.isRespondingToApproval)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.scifiSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.scifiWarning.opacity(0.035))
                }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.scifiWarning.opacity(0.22), lineWidth: 0.6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var composer: some View {
        let draftIsEmpty = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = !draftIsEmpty || model.pendingImage != nil
        return VStack(spacing: 0) {
            if let image = model.pendingImage {
                HStack(spacing: 8) {
                    Image(nsImage: image.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(image.fileName)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.scifiFg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Image")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.scifiMuted)
                    }
                    Spacer(minLength: 4)
                    Button(action: { model.clearPendingImage() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.scifiMuted)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.scifiSurface6))
                    }
                    .buttonStyle(.scifiPress)
                    .help("Remove image")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.scifiSurface)
                )
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }

            if !speechInput.isRecording {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        ForEach(QuickPrompt.allCases) { quickPrompt in
                            quickPromptChip(quickPrompt)
                        }
                    }

                    HStack(spacing: 6) {
                        quickPromptChip(.reminder)
                        quickPromptChip(.notes)
                        quickPromptOverflowMenu
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }

            HStack(alignment: .bottom, spacing: 5) {
                if speechInput.isRecording {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.scifiDestructive)
                            .frame(width: 6, height: 6)
                        Text("Listening")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.scifiMuted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .padding(.horizontal, 10)
                } else {
                    Button(action: { showingImagePicker = true }) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.scifiMuted)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.scifiPress)
                    .dockHitTarget()
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.scifiSurface4)
                            .stroke(Color.scifiBorderLight, lineWidth: 0.5)
                    )
                    .help("Attach image")

                    TextField("Ask Hermes…", text: $model.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($isComposerFocused)
                        .lineLimit(1...4)
                        .font(.system(size: 13))
                        .onSubmit { model.send() }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.scifiSurface4)
                                .stroke(Color.scifiBorder, lineWidth: 0.5)
                        )
                        .foregroundStyle(Color.scifiFg)
                        .environment(\.colorScheme, .dark)
                        .onChange(of: model.draft) { _, draft in
                            DebugLog.write("composer: draft changed (length: \(draft.count))")
                        }
                }

                Button(action: {
                    if speechInput.isRecording {
                        speechInput.stop()
                        model.send()
                    } else {
                        model.send()
                    }
                }) {
                    if speechInput.isRecording {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.scifiDestructive)
                            )
                    } else {
                        Group {
                            if model.isSending {
                                ProgressView().controlSize(.small).tint(Color.scifiBg)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(canSend ? Color.black : Color.scifiMuted)
                            }
                        }
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(canSend && !model.isSending ? Color.scifiAccent : Color.scifiSurface6)
                        )
                    }
                }
                .buttonStyle(.scifiPress)
                .dockHitTarget()
                .disabled(!speechInput.isRecording && (!canSend || model.isSending))
                .keyboardShortcut(.return, modifiers: [.command])
                .help(speechInput.isRecording ? "Send voice prompt" : "Send message")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(speechInput.isRecording ? Color.scifiDestructive.opacity(isComposerPulsing ? 0.12 : 0.05) : Color.scifiSurface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        speechInput.isRecording
                        ? Color.scifiDestructive.opacity(isComposerPulsing ? 0.65 : 0.28)
                        : Color.scifiBorderLight,
                        lineWidth: 0.5
                    )
            )
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isComposerPulsing)
            .onChange(of: speechInput.isRecording) { _, isRecording in
                isComposerPulsing = isRecording
            }
            .onChange(of: speechInput.transcript) { _, transcript in
                if speechInput.isRecording {
                    model.draft = transcript
                }
            }

            if let error = speechInput.errorMessage {
                Text(error)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.scifiWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        .onAppear {
            DebugLog.write("composer: appeared")
            if pasteMonitor == nil {
                let dockModel = model
                pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.modifierFlags.contains(.command),
                          event.charactersIgnoringModifiers?.lowercased() == "v" else {
                        return event
                    }
                    let consumed = MainActor.assumeIsolated { dockModel.pasteImageFromPasteboard() }
                    return consumed ? nil : event
                }
            }
        }
        .onDisappear {
            if let pasteMonitor {
                NSEvent.removeMonitor(pasteMonitor)
                self.pasteMonitor = nil
            }
        }
    }

    private func quickPromptChip(_ quickPrompt: QuickPrompt) -> some View {
        let requiredCapability = quickPrompt.requiredCapability
        let isAvailable = requiredCapability.map(controlCenter.capabilityAvailable) ?? true
        return Button(quickPrompt.label) {
            selectQuickPrompt(quickPrompt)
        }
        .buttonStyle(.scifiPress)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isAvailable ? Color.scifiMuted : Color.scifiTertiary)
        .padding(.horizontal, 9)
        .frame(minHeight: 26)
        .fixedSize(horizontal: true, vertical: false)
        .background(Capsule().fill(Color.scifiSurface4).stroke(Color.scifiBorderLight, lineWidth: 0.5))
        .disabled(!isAvailable)
        .help(isAvailable ? quickPrompt.label : unavailableCapabilityDetail(requiredCapability))
    }

    private var quickPromptOverflowMenu: some View {
        Menu {
            ForEach(QuickPrompt.allCases.dropFirst(2)) { quickPrompt in
                Button(quickPrompt.label) {
                    selectQuickPrompt(quickPrompt)
                }
                .disabled(quickPrompt.requiredCapability.map(controlCenter.capabilityAvailable) == false)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.scifiMuted)
                .padding(.horizontal, 9)
                .frame(minHeight: 26)
                .background(Capsule().fill(Color.scifiSurface4).stroke(Color.scifiBorderLight, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func selectQuickPrompt(_ quickPrompt: QuickPrompt) {
        model.draft = quickPrompt.prompt
        model.requestComposerFocus()
    }

    private func unavailableCapabilityDetail(_ id: String?) -> String {
        guard let id, let capability = controlCenter.capabilities.first(where: { $0.id == id }) else {
            return "This Hermes capability is unavailable. Open Core and refresh capabilities."
        }
        return capability.recovery ?? capability.detail
    }
}

private struct VoiceWavePath: Shape {
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

private struct StartupAssistantView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30.0)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate

            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.scifiSuccess)
                        .frame(width: 5, height: 5)
                        .shadow(color: Color.scifiSuccess.opacity(0.8), radius: 5)
                    Text("HERMES // ONLINE")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(Color.scifiAccent.opacity(0.85))
                }
                .padding(.top, 24)

                Spacer(minLength: 16)

                startupOrb(time: t)
                    .frame(width: 250, height: 250)

                Spacer(minLength: 14)

                VStack(spacing: 5) {
                    Text("Good to see you.")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.scifiFg)
                    Text("All systems nominal. How may I assist you?")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scifiMuted)
                }
                .multilineTextAlignment(.center)

                HStack(spacing: 6) {
                    Capsule().fill(Color.scifiAccent.opacity(0.35)).frame(width: 18, height: 1)
                    Text("AWAITING COMMAND")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .tracking(1.25)
                        .foregroundStyle(Color.scifiTertiary)
                    Capsule().fill(Color.scifiAccent.opacity(0.35)).frame(width: 18, height: 1)
                }
                .padding(.top, 15)
                .padding(.bottom, 22)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hermes online. All systems nominal. Awaiting command.")
    }

    @ViewBuilder
    private func startupOrb(time t: TimeInterval) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.scifiAccent.opacity(0.12), Color.scifiAccent.opacity(0.025), .clear],
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
                        Color.scifiAccent.opacity(index == 1 ? 0.2 : 0.12),
                        style: StrokeStyle(lineWidth: index == 1 ? 0.7 : 0.5, dash: index == 1 ? [2, 5] : [])
                    )
                    .frame(width: CGFloat(158 + index * 35), height: CGFloat(158 + index * 35))
                    .scaleEffect(scale)
                    .opacity(0.5 + 0.25 * sin(phase))
            }

            Circle()
                .trim(from: 0.05, to: 0.28)
                .stroke(Color.scifiAccent.opacity(0.75), style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                .frame(width: 212, height: 212)
                .rotationEffect(.degrees(t * 18))
            Circle()
                .trim(from: 0.57, to: 0.78)
                .stroke(Color.scifiAccent.opacity(0.4), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                .frame(width: 212, height: 212)
                .rotationEffect(.degrees(-t * 12))

            ForEach(0..<18) { index in
                let angle = Double(index) / 18 * .pi * 2 + t * 0.18
                Circle()
                    .fill(Color.scifiAccent.opacity(index.isMultiple(of: 3) ? 0.75 : 0.28))
                    .frame(width: index.isMultiple(of: 3) ? 2.5 : 1.5, height: index.isMultiple(of: 3) ? 2.5 : 1.5)
                    .offset(x: cos(angle) * 98, y: sin(angle) * 98)
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.26), Color.scifiAccent.opacity(0.32), Color.scifiAccent.opacity(0.07)],
                        center: UnitPoint(x: 0.35, y: 0.28),
                        startRadius: 1,
                        endRadius: 62
                    )
                )
                .frame(width: 116, height: 116)
                .overlay(Circle().stroke(Color.scifiAccent.opacity(0.35), lineWidth: 0.7))
                .shadow(color: Color.scifiAccent.opacity(0.24), radius: 20)
                .scaleEffect(1 + 0.025 * sin(t * 1.7))

            Circle()
                .trim(from: 0.08, to: 0.92)
                .stroke(Color.white.opacity(0.26), style: StrokeStyle(lineWidth: 0.5, lineCap: .round))
                .frame(width: 82, height: 82)
                .rotationEffect(.degrees(-t * 20))

            Image(systemName: "mic.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.scifiAccent.opacity(0.9))
                .shadow(color: Color.scifiAccent.opacity(0.7), radius: 8)

            Capsule()
                .fill(Color.scifiAccent.opacity(0.55))
                .frame(width: 58, height: 0.8)
                .offset(y: 42)
                .scaleEffect(x: 0.7 + 0.3 * (sin(t * 2.2) + 1) / 2, y: 1)
        }
    }
}

private struct VoiceOrbView: View {
    let isListening: Bool
    let isResponding: Bool
    let audioLevel: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let isActive = isListening || isResponding
            let animationTime = isActive ? t : 0
            let voiceLevel = Double(audioLevel)
            let waveSpeed = isResponding ? 6.0 : (isListening ? 4.0 : 0)
            let waveAmplitude = isResponding ? 22.0 : (isListening ? 4.0 + voiceLevel * 26.0 : 0)
            ZStack {
                ForEach(0..<4) { i in
                    let size = 140.0 + Double(i) * 60
                    Circle()
                        .stroke(
                            Color.scifiAccent.opacity(i % 2 == 0 ? 0.08 : 0.05),
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
                        .fill(Color.scifiAccent)
                        .frame(width: 2, height: barH)
                        .offset(y: -92)
                        .rotationEffect(.degrees(Double(i) / 48 * 360))
                        .opacity(0.4)
                }

                VoiceWavePath(t: animationTime, amplitude: waveAmplitude)
                    .stroke(Color.scifiAccent.opacity(isActive ? (isResponding ? 0.8 : 0.5) : 0.16), lineWidth: isResponding ? 2 : 1.5)
                    .frame(width: 200, height: 200)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.scifiAccent.opacity(0.3), Color.scifiAccent.opacity(0.12), Color.scifiAccent.opacity(0.04)],
                            center: UnitPoint(x: 0.35, y: 0.35),
                            startRadius: 0,
                            endRadius: 55
                        )
                    )
                    .frame(width: 90, height: 90)
                    .overlay(Circle().stroke(Color.scifiAccent.opacity(0.2), lineWidth: 0.5))
                    .shadow(color: Color.scifiAccent.opacity(0.25), radius: 30)
                    .scaleEffect(
                        1 + (isResponding
                             ? 0.12 * sin(animationTime * .pi)
                             : (isListening ? 0.025 + voiceLevel * 0.1 : 0))
                    )
                    .overlay {
                        Image(systemName: isResponding ? "waveform" : "mic.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.scifiAccent)
                            .scaleEffect(1 - 0.12 * (1 + sin(animationTime * .pi * 1.6)) / 2)
                    }
            }
        }
    }
}

private struct MicWaveform: View {
    let isActive: Bool

    var body: some View {
        TimelineView(.animation) { context in
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    let phase = context.date.timeIntervalSinceReferenceDate * 4 + Double(index) * 0.8
                    Capsule()
                        .frame(width: 2, height: isActive ? 5 + CGFloat(abs(sin(phase)) * 13) : 3)
                }
            }
            .foregroundStyle(Color.scifiAccent)
            .frame(width: 28, height: 28)
        }
    }
}

private struct KanbanMutationEditor: View {
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
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.scifiAccent)
            Text(request.task.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.scifiFg)
            TextField(placeholder, text: $value, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.scifiGlass)
            if (request.kind == .assign || request.kind == .reassign), !assignees.isEmpty {
                Menu("Choose Hermes profile") {
                    ForEach(assignees, id: \.self) { assignee in
                        Button(assignee) { value = assignee }
                    }
                }
                .buttonStyle(.scifiPress)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.scifiAccent)
            }
            if request.kind == .reassign {
                Toggle("Reclaim active worker first", isOn: $reclaimFirst)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scifiMuted)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(request.kind.title) { confirming = true }
                    .buttonStyle(.scifiPrimary)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPending)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Color.scifiBg)
        .environment(\.colorScheme, .dark)
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

private struct CronEditEditor: View {
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
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.scifiAccent)
            if job.editableFields.contains(.name) {
                TextField("Name", text: $draft.name).textFieldStyle(.scifiGlass)
            }
            if job.editableFields.contains(.schedule) {
                TextField("Schedule", text: $draft.schedule).textFieldStyle(.scifiGlass)
            }
            if job.editableFields.contains(.prompt), job.prompt != nil {
                TextField("Prompt", text: $draft.prompt, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.scifiGlass)
            }
            Text("Only values supplied by Hermes are editable. Unchanged values are not sent.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.scifiTertiary)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save Changes") { confirming = true }
                    .buttonStyle(.scifiPrimary)
                    .disabled(draft.changes(comparedTo: job).filter { job.editableFields.contains($0.key) }.isEmpty || isPending)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Color.scifiBg)
        .environment(\.colorScheme, .dark)
        .confirmationDialog("Save scheduled-job changes?", isPresented: $confirming) {
            Button("Save Changes") { submit(draft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            let fields = draft.changes(comparedTo: job).filter { job.editableFields.contains($0.key) }.keys.map(\.title).sorted().joined(separator: ", ")
            Text("Hermes will update \(fields) for ‘\(job.name)’. The scheduler remains authoritative.")
        }
    }
}

private enum DockCommand: Identifiable, CaseIterable {
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
        case .newChat: "square.and.pencil"
        case .focusComposer: "text.cursor"
        case .stop: "stop.circle"
        case .voice: "mic"
        }
    }
}

private struct DockCommandPalette: View {
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
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.scifiAccent)
                Spacer()
                Text("⌘K")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.scifiMuted)
            }
            TextField("Search actions", text: $query)
                .textFieldStyle(.scifiGlass)
            ForEach(commands) { command in
                Button {
                    select(command)
                    dismiss()
                } label: {
                    Label(command.title, systemImage: command.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.scifiFg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.scifiPress)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Color.scifiBg)
        .environment(\.colorScheme, .dark)
    }
}
