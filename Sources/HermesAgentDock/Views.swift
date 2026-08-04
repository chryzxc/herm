import AppKit
import SwiftUI
import Foundation

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
        case prose([String])
        case code(String, language: String?)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let paragraphs):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            if let rendered = renderedMarkdown(paragraph) {
                                Text(rendered)
                                    .font(.system(size: 13, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .code(let code, let language):
                    VStack(alignment: .leading, spacing: 2) {
                        if let lang = language {
                            Text(lang)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.scifiMuted)
                                .textCase(.uppercase)
                                .padding(.horizontal, 8)
                                .padding(.top, 6)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code)
                                .font(.system(size: 12, design: .monospaced))
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
                }
            }
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inCode = false

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
            if !paragraphs.isEmpty { result.append(.prose(paragraphs)) }
            prose.removeAll()
        }

        func flushCode() {
            result.append(.code(code.joined(separator: "\n"), language: language))
            code.removeAll()
            language = nil
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    flushCode()
                } else {
                    flushProse()
                    let marker = line.trimmingCharacters(in: .whitespaces)
                    let suffix = String(marker.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    language = suffix.isEmpty ? nil : suffix
                }
                inCode.toggle()
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode { flushCode() } else { flushProse() }
        return result
    }

    private func renderedMarkdown(_ value: String) -> AttributedString? {
        do {
            var str = try AttributedString(
                markdown: groupedNumbers(in: value),
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
            str.font = .system(size: 13, design: .monospaced)
            str.foregroundColor = .scifiFg
            return str
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

struct DockPopover: View {
    @ObservedObject var model: DockModel
    @Environment(\.openWindow) private var openWindow
    @State private var isConversationAtBottom = true
    @State private var isComposerPulsing = false
    @State private var pasteMonitor: Any?
    @State private var showingImagePicker = false
    @StateObject private var speechInput = SpeechInput()

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isShowingSessions {
                sessionPicker
                Divider().overlay(Color.scifiBorderLight)
            }
            conversation
            Divider().overlay(Color.scifiBorderLight)
            composer
        }
        .frame(width: 420, height: 560)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .fileImporter(isPresented: $showingImagePicker, allowedContentTypes: [.png, .jpeg, .image]) { result in
            if case .success(let url) = result {
                model.stageImageFile(at: url)
            }
        }
        .task { model.restoreLatestSessionIfNeeded() }
        .onAppear { model.markPopoverVisible() }
        .onDisappear { model.markPopoverHidden() }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Button(action: { model.toggleSessions() }) {
                HStack(spacing: 3) {
                    Text(model.currentSessionTitle ?? "Hermes")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.scifiFg)
                        .lineLimit(1)
                    Image(systemName: model.isShowingSessions ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.scifiMuted)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 10) {
                Button(action: { openWindow(id: "workspace") }) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.scifiMuted)
                }
                .buttonStyle(.plain)
                .help("Open Workspace")

                if model.status == .working || model.isSending {
                    Button(action: { model.stop() }) {
                        Image(systemName: "square.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.scifiMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                }

                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                Button(action: { model.newChat() }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.scifiMuted)
                }
                .buttonStyle(.plain)
                .help("New chat")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
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

    private var sessionPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversations")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.scifiMuted)
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
            Spacer()
            VStack(spacing: 6) {
                if !speechInput.transcript.isEmpty {
                    Text(speechInput.transcript)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.scifiFg)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                } else {
                    Text("Listening")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(1.0)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.scifiAccent)
                }
            }
            .padding(.top, 16)
            Spacer()
            VoiceOrbView()
                .frame(width: 320, height: 320)
            Spacer()
            VStack(spacing: 4) {
                Text("Speak now")
                    .font(.system(size: 13, weight: .medium))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.scifiAccent)
                Text("tap stop when done")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.scifiMuted.opacity(0.6))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    private var chatScroll: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.messages.isEmpty && model.status != .working {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Good to see you.")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.scifiFg)
                                Text("All systems nominal. How may I assist you?")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.scifiMuted)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
            if !model.activeToolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.activeToolCalls) { call in
                        toolCallRow(call)
                    }
                }
            }
            if !importantEvents.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(importantEvents.suffix(6))) { event in
                        eventRow(event)
                    }
                }
            }
            if model.reasoningState == nil && model.activeToolCalls.isEmpty && importantEvents.isEmpty {
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
                    .font(.system(size: 9, design: .monospaced))
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
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Color.scifiTertiary)
                            Text("You")
                                .font(.system(size: 9.5, weight: .semibold))
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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .foregroundStyle(Color.scifiFg)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 310, alignment: .trailing)
                        .background(Color.scifiAccentMuted)
                        .clipShape(MessageBubbleShape(isUser: true))
                        .overlay(
                            MessageBubbleShape(isUser: true)
                                .stroke(Color.scifiAccent.opacity(0.15), lineWidth: 0.5)
                        )
                        .shadow(color: Color.scifiAccent.opacity(0.05), radius: 4)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Hermes")
                                .font(.system(size: 9.5, weight: .semibold))
                                .tracking(1.0)
                                .textCase(.uppercase)
                                .foregroundStyle(Color.scifiMuted)
                            Text(Self.timeFormatter.string(from: message.timestamp))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Color.scifiTertiary)
                            if let modelName = message.modelName {
                                Text("· \(modelName)")
                                    .font(.system(size: 9.5, design: .monospaced))
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

    private func toolCallRow(_ call: ActiveToolCall) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(call.isComplete ? Color.scifiSuccess : Color.scifiAccent)
                .frame(width: 6, height: 6)
            Text(call.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.scifiFg)
            if !call.input.isEmpty {
                Text(call.input)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.scifiMuted)
                    .lineLimit(1)
            }
            if call.isComplete {
                if let result = call.result {
                    Text(result)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.scifiTertiary)
                        .lineLimit(2)
                } else {
                    Text("done")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.scifiTertiary)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func approvalRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.scifiWarning)
                    .font(.system(size: 11))
                Text("Approval required")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.scifiFg)
            }

            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .foregroundStyle(Color.scifiFg)

            HStack(spacing: 6) {
                Button("Deny") { model.respondToApproval("deny") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Allow") { model.respondToApproval("once") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.scifiSurface)
                .stroke(Color.scifiBorderLight, lineWidth: 0.5)
        )
        .padding(.vertical, 4)
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
                            .font(.system(size: 9))
                            .foregroundStyle(Color.scifiMuted)
                    }
                    Spacer(minLength: 4)
                    Button(action: { model.clearPendingImage() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
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
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.scifiSurface4)
                    )
                    .help("Attach image")

                    Button(action: { speechInput.toggle() }) {
                        Group {
                            if speechInput.isStarting {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 36, height: 36)
                            } else {
                                Image(systemName: speechInput.isUnavailable ? "mic.slash.fill" : "mic.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(speechInput.isUnavailable ? Color.scifiWarning : Color.scifiMuted)
                                    .frame(width: 36, height: 36)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.scifiSurface4)
                    )
                    .help(
                        speechInput.isUnavailable
                        ? "Dictation requires the bundled app"
                        : "Dictate message"
                    )

                    TextField("Ask Hermes…", text: $model.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(minHeight: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.scifiSurface)
                                .stroke(Color.scifiBorder, lineWidth: 0.5)
                        )
                        .foregroundStyle(Color.scifiFg)
                        .environment(\.colorScheme, .dark)
                        .onSubmit { model.send() }
                }

                Button(action: {
                    if speechInput.isRecording {
                        speechInput.stop()
                    } else {
                        model.send()
                    }
                }) {
                    if speechInput.isRecording {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                            .frame(width: 36, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.scifiDestructive.opacity(speechInput.isRecording ? (isComposerPulsing ? 0.12 : 0.05) : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        speechInput.isRecording
                        ? Color.scifiDestructive.opacity(isComposerPulsing ? 0.65 : 0.28)
                        : Color.clear,
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
        }
        .onAppear {
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

private struct VoiceOrbView: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<4) { i in
                    let size = 140.0 + Double(i) * 60
                    Circle()
                        .stroke(
                            Color.scifiAccent.opacity(i % 2 == 0 ? 0.08 : 0.05),
                            style: StrokeStyle(lineWidth: i % 2 == 0 ? 1 : 0.5, dash: i % 2 == 0 ? [] : [3, 4])
                        )
                        .frame(width: size, height: size)
                        .scaleEffect(1 + 0.1 * sin(t * 0.8 + Double(i) * 0.5))
                        .opacity(0.25 + 0.15 * sin(t * 0.8 + Double(i) * 0.5))
                }

                ForEach(0..<48) { i in
                    let barH = 4 + 16 * (1 + sin(t * 4 + Double(i) * 0.4)) / 2
                    Capsule()
                        .fill(Color.scifiAccent)
                        .frame(width: 2, height: barH)
                        .offset(y: -92)
                        .rotationEffect(.degrees(Double(i) / 48 * 360))
                        .opacity(0.4)
                }

                VoiceWavePath(t: t)
                    .stroke(Color.scifiAccent.opacity(0.5), lineWidth: 1.5)
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
                    .scaleEffect(1 + 0.08 * sin(t * .pi))
                    .overlay {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.scifiAccent)
                            .scaleEffect(1 - 0.12 * (1 + sin(t * .pi * 1.6)) / 2)
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
