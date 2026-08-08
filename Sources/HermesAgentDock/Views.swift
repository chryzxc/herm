import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

extension Color {
    static let scifiBg = Color.black
    static let scifiSurface = Color.white.opacity(0.03)
    static let scifiSurface2 = Color.white.opacity(0.02)
    static let scifiSurface4 = Color.white.opacity(0.04)
    static let scifiSurface6 = Color.white.opacity(0.06)
    static let scifiSurface8 = Color.white.opacity(0.08)
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
            .buttonStyle(.plain)
            .help("Return to chat")

            Spacer()

            HStack(spacing: 8) {
                Button(action: onToggleWorkspace) {
                    Image(systemName: isWorkspaceVisible ? "rectangle.compress.vertical" : "rectangle.split.2x1")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isWorkspaceVisible ? Color.scifiAccent : Color.scifiMuted)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(isWorkspaceVisible ? Color.scifiAccent.opacity(0.1) : Color.scifiSurface4))
                }
                .buttonStyle(.plain)
                .help(isWorkspaceVisible ? "Hide Workspace" : "Show Workspace")

                if canStopRequest {
                    Button(action: onStopRequest) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.scifiDestructive)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.scifiDestructive.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
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
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
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
    @State private var selectedModelID = ""
    @State private var selectedAgentID: String?
    @State private var repository = RepositorySnapshot.empty
    @State private var isRefreshingRepository = false
    @State private var showingRepositoryPicker = false
    @State private var reminderForConfirmation: ReminderSummary?
    @State private var isShowingReminderConfirmation = false
    @State private var cronChangeRequest: CronChangeRequest?
    @State private var isShowingCronConfirmation = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("HERMES CONTROL")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Color.scifiAccent)
                    Text("PERSONAL OPERATING SURFACE")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(Color.scifiTertiary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.scifiMuted)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
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
                     case .core: coreContent
                     }
                }
                .padding(16)
            }
        }
        .background(Color.scifiSurface)
        .environment(\.colorScheme, .dark)
        .fileImporter(isPresented: $showingRepositoryPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            store.attachProject(at: url.path, toSessionID: model.sessionID)
        }
        .task(id: store.projectPath) { await refreshRepository() }
        .task {
            control.bind(to: model)
            control.refresh()
        }
        .onChange(of: model.status) { _, _ in control.rebuildAttention() }
        .onChange(of: model.approvalText) { _, _ in control.rebuildAttention() }
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
    }

    private var modePicker: some View {
        HStack(spacing: 3) {
            ForEach(ControlTab.allCases) { mode in
                Button {
                    withAnimation(.scifiEase(duration: 0.2)) { selectedMode = mode }
                    if mode == .core { model.refreshRuntimeConfiguration(); control.refresh() }
                } label: {
                    Text(mode.rawValue.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.75)
                        .foregroundStyle(selectedMode == mode ? Color.scifiFg : Color.scifiMuted)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(selectedMode == mode ? Color.scifiAccent.opacity(0.11) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
    }

    private var activityContent: some View {
        AgentBoardView(model: model, embedded: true)
    }

    private var inboxContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("ATTENTION  ·  \(control.attention.filter { $0.state == .open }.count)")
            if control.attention.filter({ $0.state == .open }).isEmpty {
                emptyState(icon: "checkmark.circle", title: "Nothing needs your attention", detail: "Approvals, failures, clarifications, and due reminders will appear here.")
            } else {
                ForEach(control.attention.filter { $0.state == .open }) { item in
                    attentionItemRow(item)
                }
            }
            if !control.reminders.isEmpty {
                sectionLabel("DUE REMINDERS  ·  \(control.reminders.count)")
                ForEach(control.reminders) { reminder in
                    Button {
                        reminderForConfirmation = reminder
                        isShowingReminderConfirmation = true
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(reminder.isOverdue ? Color.scifiWarning : Color.scifiAccent).frame(width: 6, height: 6)
                            Text(reminder.title).font(.system(size: 10.5)).foregroundStyle(Color.scifiFg).lineLimit(2)
                            Spacer(minLength: 4)
                            Text(reminder.isOverdue ? "OVERDUE" : (reminder.list ?? "REMINDER"))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(reminder.isOverdue ? Color.scifiWarning : Color.scifiMuted)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let error = control.lastError {
                Text(error).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.scifiWarning)
            }
        }
    }

    private func attentionItemRow(_ item: AttentionItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: item.kind == .approval ? "exclamationmark.triangle" : "circle.dotted")
                    .font(.system(size: 11)).foregroundStyle(item.kind == .approval ? Color.scifiWarning : Color.scifiAccent)
                    .frame(width: 15)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.scifiFg)
                    Text(item.detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.scifiMuted).lineLimit(4)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                ForEach(item.actions.filter { $0 != .dismiss }, id: \.self) { action in
                    Button(action.rawValue.uppercased()) { control.respond(to: item, action: action) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(action == .deny || action == .stop ? Color.scifiWarning : Color.scifiAccent)
                }
                Button("DISMISS") { control.dismiss(item.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
            }
        }
        .padding(11)
        .background(Color.scifiSurface4)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.scifiBorder, lineWidth: 0.5))
    }

    private var nowContent: some View {
        VStack(alignment: .leading, spacing: 17) {
            sectionLabel("CURRENT TASK")
            if let task = currentTask {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top, spacing: 9) {
                        Circle().fill(taskColor(task.status)).frame(width: 7, height: 7).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color.scifiFg)
                                .lineLimit(3)
                            Text(task.status.rawValue.uppercased())
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(0.6)
                                .foregroundStyle(taskColor(task.status))
                        }
                        Spacer(minLength: 0)
                    }
                    HStack {
                        Text("SESSION LINKED")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(0.55)
                            .foregroundStyle(Color.scifiTertiary)
                        Spacer()
                        Button(task.status == .done ? "REOPEN" : "MARK DONE") {
                            store.updateStatus(task.status == .done ? .inProgress : .done, for: task.id)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.scifiAccent)
                    }
                }
                .padding(12)
                .background(Color.scifiSurface4)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.scifiBorder, lineWidth: 0.5))
            } else {
                emptyState(icon: "scope", title: "No active task", detail: "Send a request and the Hermes session will become a durable workspace task.")
            }

            sectionLabel("ATTENTION")
            VStack(alignment: .leading, spacing: 9) {
                attentionRow(
                    icon: model.approvalText == nil ? "checkmark.circle" : "exclamationmark.triangle",
                    title: model.approvalText == nil ? "No decisions waiting" : "Hermes needs approval",
                    detail: model.approvalText ?? "You are clear to continue.",
                    color: model.approvalText == nil ? .scifiSuccess : .scifiWarning
                )
                attentionRow(
                    icon: model.activeSubagents.isEmpty ? "person.2" : "person.2.fill",
                    title: model.activeSubagents.isEmpty ? "No agents running" : "\(model.activeSubagents.count) active agent\(model.activeSubagents.count == 1 ? "" : "s")",
                    detail: model.activeToolCalls.isEmpty ? "No active tools" : "\(model.activeToolCalls.count) tool call\(model.activeToolCalls.count == 1 ? "" : "s") in progress",
                    color: model.activeSubagents.isEmpty ? .scifiMuted : .scifiAccent
                )
            }

            if store.projectPath != nil {
                sectionLabel("DEVELOPMENT CONTEXT")
                repositoryContent
            }

            if !control.reminders.isEmpty {
                sectionLabel("REMINDERS  ·  \(control.reminders.count)")
                ForEach(control.reminders.prefix(3)) { reminder in
                    Button {
                        reminderForConfirmation = reminder
                        isShowingReminderConfirmation = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: reminder.isOverdue ? "exclamationmark.circle" : "checklist")
                                .font(.system(size: 10)).foregroundStyle(reminder.isOverdue ? Color.scifiWarning : Color.scifiAccent)
                            Text(reminder.title).font(.system(size: 10.5)).foregroundStyle(Color.scifiFg).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if !control.cronJobs.isEmpty {
                sectionLabel("SCHEDULED WORK  ·  \(control.cronJobs.count)")
                ForEach(control.cronJobs.prefix(3)) { job in
                    HStack(spacing: 8) {
                        Circle().fill(job.enabled ? Color.scifiAccent : Color.scifiTertiary).frame(width: 5, height: 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.scifiFg)
                            Text(job.schedule).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.scifiTertiary)
                        }
                        Spacer(minLength: 0)
                        if job.sessionID != nil {
                            Button("OPEN") { control.openCronSession(job) }
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.scifiAccent)
                        }
                        Button(job.enabled ? "PAUSE" : "RESUME") {
                            cronChangeRequest = CronChangeRequest(job: job, enable: !job.enabled)
                            isShowingCronConfirmation = true
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(job.enabled ? Color.scifiWarning : Color.scifiAccent)
                    }
                }
            }

            if !store.tasks.isEmpty {
                sectionLabel("RECENT TASKS  ·  \(store.tasks.count)")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.tasks.prefix(4)) { task in
                        HStack(spacing: 8) {
                            Circle().fill(taskColor(task.status)).frame(width: 5, height: 5)
                            Text(task.title).font(.system(size: 10.5)).foregroundStyle(Color.scifiFg).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(task.status.rawValue.uppercased())
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(taskColor(task.status))
                        }
                    }
                }
            }
        }
    }

    private var repositoryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: repository.isGitRepository ? "arrow.triangle.branch" : "folder")
                    .foregroundStyle(repository.isGitRepository ? Color.scifiSuccess : Color.scifiMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(repository.isGitRepository ? repository.branch : "No repository selected")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.scifiFg)
                        .lineLimit(1)
                    if repository.isGitRepository {
                        Text(repository.changedFiles == 0 ? "CLEAN WORKING TREE" : "\(repository.changedFiles) CHANGED FILE\(repository.changedFiles == 1 ? "" : "S")")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(repository.changedFiles == 0 ? Color.scifiSuccess : Color.scifiWarning)
                    } else if let path = store.projectPath {
                        Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.scifiTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isRefreshingRepository { ProgressView().controlSize(.small) }
            }
            if repository.isGitRepository, !repository.latestCommit.isEmpty {
                Text(repository.latestCommit)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
                    .lineLimit(2)
            }
            HStack(spacing: 14) {
                Button(store.projectPath == nil ? "CHOOSE REPOSITORY" : "CHANGE REPOSITORY") {
                    showingRepositoryPicker = true
                }
                if store.projectPath != nil {
                    Button("REFRESH") { Task { await refreshRepository() } }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.scifiAccent)
        }
        .padding(12)
        .background(Color.scifiSurface4)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.scifiBorder, lineWidth: 0.5))
    }

    private func attentionRow(icon: String, title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.scifiFg)
                Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.scifiTertiary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private var currentTask: WorkspaceTask? {
        if let sessionID = model.sessionID {
            return store.task(forSessionID: sessionID)
        }
        return store.activeTask
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
        guard let path = store.projectPath else {
            repository = .empty
            return
        }
        isRefreshingRepository = true
        repository = await RepositoryService.inspect(path: path)
        isRefreshingRepository = false
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
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(Color.scifiFg)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scifiMuted)
                    .lineLimit(1)
            }
            .frame(width: 82, alignment: .leading)
            .padding(8)
            .background(selectedAgentID == id ? color.opacity(0.12) : Color.scifiSurface4)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selectedAgentID == id ? color.opacity(0.5) : Color.scifiBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(status)
    }

    private func activityRow(_ activity: AgentActivity) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.timeFormatter.string(from: activity.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.scifiTertiary)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.kind.replacingOccurrences(of: "subagent.", with: "").uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(Color.scifiAccent)
                Text(activity.text)
                    .font(.system(size: 10, design: .monospaced))
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
            sectionLabel("CAPABILITIES")
            ForEach(control.capabilities) { capability in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(capability.isAvailable ? Color.scifiSuccess : Color.scifiWarning).frame(width: 6, height: 6).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(capability.title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.scifiFg)
                        Text(capability.detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.scifiTertiary).lineLimit(2)
                        if let recovery = capability.recovery {
                            Text(recovery).font(.system(size: 10)).foregroundStyle(Color.scifiWarning).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            Divider().overlay(Color.scifiBorderLight)
            HStack {
                sectionLabel("HERMES CONFIGURATION")
                Spacer()
                Button(action: { model.refreshRuntimeConfiguration() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.scifiAccent)
                }
                .buttonStyle(.plain)
                .disabled(model.isLoadingRuntimeConfiguration)
            }

            if model.isLoadingRuntimeConfiguration && model.runtimeConfiguration == nil {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("READING HERMES RUNTIME…").font(.system(size: 10, design: .monospaced)).tracking(0.6).foregroundStyle(Color.scifiMuted)
                }
            } else if let configuration = model.runtimeConfiguration {
                diagnosticRow(label: "MODEL", value: configuration.model ?? "NOT CONFIGURED", color: configuration.model == nil ? Color.scifiWarning : Color.scifiSuccess)
                diagnosticRow(label: "PROVIDER", value: configuration.provider ?? "NOT CONFIGURED", color: configuration.provider == nil ? Color.scifiWarning : Color.scifiSuccess)
                if model.runtimeModelOptions.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("LOADING HERMES MODEL CATALOG…").font(.system(size: 10, design: .monospaced)).tracking(0.5).foregroundStyle(Color.scifiMuted)
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
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.scifiMuted)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 36)
                        .background(Color.scifiSurface4)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.scifiBorder, lineWidth: 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: selectedModelID) { _, id in
                        guard let option = model.runtimeModelOptions.first(where: { $0.id == id }),
                              option.model != configuration.model || option.provider != configuration.provider else { return }
                        model.updateRuntimeModel(option)
                    }
                }
                Text("Catalog is supplied live by Hermes. Selection updates provider and model for new sessions.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
                if let error = model.runtimeConfigurationError {
                    Text(error)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.scifiWarning)
                }
                if let path = configuration.configPath {
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
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
        Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.1).foregroundStyle(Color.scifiMuted)
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
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.scifiFg)
                    .lineLimit(expanded ? 4 : 2)
                if let role = agent.role {
                    Text("ROLE  \(role.uppercased())\(agent.sourceSkill.map { "  ·  \($0)" } ?? "")")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.35)
                        .foregroundStyle(Color.scifiAccent)
                }
                Text("\(agent.status.uppercased())  ·  \(agent.toolCount) TOOLS\(agent.model.map { "  ·  \($0.uppercased())" } ?? "")")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(nativeAgentColor(agent.status))
                if expanded, let latest = agent.latestActivity {
                    Text(latest)
                        .font(.system(size: 10, design: .monospaced))
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
                Text(event.type.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.35).foregroundStyle(Color.scifiMuted)
                Text(event.detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.scifiTertiary).lineLimit(2)
            }
        }
    }

    private func diagnosticRow(label: String, value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.8).foregroundStyle(Color.scifiTertiary)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(value).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.35).foregroundStyle(Color.scifiFg).lineLimit(1)
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
                    .font(.system(size: 10, design: .monospaced))
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
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
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
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.65)
                        .foregroundStyle(Color.scifiTertiary)
                }
            }
        }
    }

    private func capabilityRow(icon: String, title: String, detail: String, state: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.scifiFg)
                Text(detail).font(.system(size: 10)).foregroundStyle(Color.scifiTertiary)
            }
            Spacer(minLength: 3)
            Text(state).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.45).foregroundStyle(color)
        }
    }

    private var latestModelName: String? {
        model.messages.reversed().compactMap(\.modelName).first
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(Color.scifiTertiary)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.scifiFg)
            Text(detail).font(.system(size: 11)).foregroundStyle(Color.scifiMuted).fixedSize(horizontal: false, vertical: true)
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
    @State private var isWorkspaceManuallyExpanded = false
    @State private var isNarrowLayout = false
    @State private var isNarrowControlVisible = false
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
        case reminder, notes, research, summarize, automation, review

        var id: Self { self }
        var label: String {
            switch self {
            case .reminder: "Reminder"
            case .notes: "Save to Notes"
            case .research: "Research"
            case .summarize: "Summarize work"
            case .automation: "Recurring automation"
            case .review: "Review work"
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
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(connectionColor)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.currentSessionTitle ?? "Untitled chat")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.scifiFg)
                            .lineLimit(1)
                        Text("HERMES CONSOLE")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.05)
                            .foregroundStyle(Color.scifiTertiary)
                    }
                    Image(systemName: model.isShowingSessions ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.scifiMuted)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 7) {
                Button(action: {
                    inputMode = .talk
                    beginVoiceConversation()
                }) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.scifiMuted)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.scifiSurface4))
                }
                .buttonStyle(.plain)
                .help("Talk mode")

                Button(action: {
                    if isNarrowLayout {
                        isNarrowControlVisible.toggle()
                    } else {
                        isWorkspaceManuallyExpanded.toggle()
                    }
                }) {
                    Image(systemName: isWorkspaceVisibleForLayout ? "rectangle.compress.vertical" : "rectangle.split.2x1")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isWorkspaceVisibleForLayout ? Color.scifiAccent : Color.scifiMuted)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(isWorkspaceVisibleForLayout ? Color.scifiAccent.opacity(0.1) : Color.clear))
                }
                .buttonStyle(.plain)
                .help(isWorkspaceVisibleForLayout ? "Hide Control" : "Show Control")

                if model.status == .working || model.isSending {
                    Button(action: stopCurrentRequest) {
                        Image(systemName: "square.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.scifiMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                }

                Button(action: { model.newChat() }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.scifiMuted)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.scifiSurface4))
                }
                .buttonStyle(.plain)
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
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
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
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.scifiMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if model.sessions.isEmpty && !model.isLoadingSessions {
                Text("No saved conversations")
                    .font(.system(size: 11))
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
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(Color.scifiMuted)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if let date = session.startedAt {
                                    Text(date, style: .relative)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Color.scifiTertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
                    isResponding: model.voiceState == .preparing || model.voiceState == .thinking || (model.status == .working && !speechInput.isRecording) || voiceOutput.isSpeaking,
                    audioLevel: speechInput.audioLevel
                )
                    .frame(width: 320, height: 320)
            }
            .buttonStyle(.plain)
            .help(model.voiceState.isNativeConversationActive || speechInput.isRecording ? "End voice conversation" : "Resume listening")
            .overlay(alignment: .bottom) {
                if let detail = model.voiceState.fallbackDetail {
                    Text("LOCAL FALLBACK · \(detail)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(0.35)
                        .foregroundStyle(Color.scifiWarning)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 270)
                        .offset(y: 42)
                } else if model.voiceState.isNativeConversationActive {
                    VStack(spacing: 5) {
                        Text(model.voiceState.label)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(0.75)
                            .foregroundStyle(model.voiceState == .listening ? Color.scifiSuccess : Color.scifiAccent)
                        if let timing = model.voiceTelemetry.summary {
                            Text(timing)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
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
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
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
                            approvalRow(approval)
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
        VStack(alignment: .leading, spacing: 6) {
            if let reasoning = model.reasoningState {
                reasoningBlock(reasoning)
            }
            if !importantEvents.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(importantEvents.suffix(6))) { event in
                        eventRow(event)
                    }
                }
            }
            if model.reasoningState == nil && importantEvents.isEmpty {
                HStack(spacing: 5) {
                    ThinkingDots()
                    Text("Thinking")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scifiMuted)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var importantEvents: [AgentEvent] {
        model.recentEvents.filter { event in
            let type = event.type.lowercased()
            return type.contains("approval") ||
                type.contains("error") ||
                type.contains("permission") ||
                type.contains("warning")
        }
    }

    private func isAutoScrollEvent(_ type: String) -> Bool {
        let type = type.lowercased()
        return type.contains("tool") ||
            type.contains("reason") ||
            type.contains("think") ||
            type == "message.start"
    }

    private func eventRow(_ event: AgentEvent) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Color.scifiBorder)
                .frame(width: 5, height: 5)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.type)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.scifiMuted)
                Text(event.detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

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
                            Text(Self.timeFormatter.string(from: message.timestamp))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.scifiTertiary)
                            Text("You")
                                .font(.system(size: 10, weight: .semibold))
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
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(1.0)
                                .textCase(.uppercase)
                                .foregroundStyle(Color.scifiMuted)
                            Text(Self.timeFormatter.string(from: message.timestamp))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.scifiTertiary)
                            if let modelName = message.modelName {
                                Text("· \(modelName)")
                                    .font(.system(size: 10, design: .monospaced))
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
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(Color.scifiMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 10))
                Text("Reasoning")
                    .font(.system(size: 11, weight: .medium))
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

    private func approvalRow(_ text: String) -> some View {
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
                Text("Approval required")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.scifiFg)
                Spacer()
                Text("ACTION NEEDED")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Color.scifiWarning)
            }

            Text(text)
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
                Button("Deny") { model.respondToApproval("deny") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Allow once") { model.respondToApproval("once") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.scifiFg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Image")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.scifiMuted)
                    }
                    Spacer(minLength: 4)
                    Button(action: { model.clearPendingImage() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.scifiMuted)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.scifiSurface6))
                    }
                    .buttonStyle(.plain)
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(QuickPrompt.allCases) { quickPrompt in
                            Button(quickPrompt.label) {
                                model.draft = quickPrompt.prompt
                                model.requestComposerFocus()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.scifiMuted)
                            .padding(.horizontal, 9)
                            .frame(minHeight: 26)
                            .background(Capsule().fill(Color.scifiSurface4).stroke(Color.scifiBorderLight, lineWidth: 0.5))
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .padding(.top, 6)
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
                    .buttonStyle(.plain)
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
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                canSend && !model.isSending
                                ? Color.black
                                : Color.scifiMuted
                            )
                            .frame(width: 38, height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(
                                        canSend && !model.isSending
                                        ? Color.scifiAccent
                                        : Color.scifiSurface6
                                    )
                            )
                    }
                }
                .buttonStyle(.plain)
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
                    .font(.system(size: 10, design: .monospaced))
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
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
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
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
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
