import SwiftUI
import Foundation

// MARK: - Markdown Renderer

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
                                    .font(.system(size: 13))
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
                                .foregroundStyle(.secondary)
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
                            .fill(Color.primary.opacity(0.06))
                            .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
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
            str.font = .system(size: 13)
            str.foregroundColor = .primary
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

// MARK: - Main Popover

struct DockPopover: View {
    @ObservedObject var model: DockModel
    @State private var isConversationAtBottom = true
    @State private var isComposerPulsing = false
    @StateObject private var speechInput = SpeechInput()

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isShowingSessions {
                sessionPicker
            }
            Divider()
            conversation
            Divider()
            composer
        }
        .frame(width: 420, height: 540)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
        .task {
            model.restoreLatestSessionIfNeeded()
        }
        .onAppear {
            model.markPopoverVisible()
        }
        .onDisappear {
            model.markPopoverHidden()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            Button(action: { model.toggleSessions() }) {
                HStack(spacing: 3) {
                    Text(model.currentSessionTitle ?? "Hermes")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: model.isShowingSessions ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 10) {
                if model.status == .working || model.isSending {
                    Button(action: { model.stop() }) {
                        Image(systemName: "square.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                }

                Button(action: { model.newChat() }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New chat")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Session Picker

    private var sessionPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversations")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isLoadingSessions {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Button(action: { model.loadSessions() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
                                        .foregroundStyle(.primary)
                                    if !session.preview.isEmpty {
                                        Text(session.preview)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if let date = session.startedAt {
                                    Text(date, style: .relative)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 150)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.messages) { message in
                            if model.status == .working,
                               message.role == .hermes,
                               message.id == model.messages.last?.id {
                                activityView
                                    .id("activity")
                            }
                            messageRow(message)
                                .id(message.id)
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
                .onChange(of: model.messages.count) { _, _ in
                    if isConversationAtBottom, let last = model.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: model.activeToolCalls) { _, _ in
                    if model.status == .working && isConversationAtBottom {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("conversationBottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: model.reasoningState) { _, _ in
                    if model.status == .working && isConversationAtBottom {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("conversationBottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: model.recentEvents.last) { _, _ in
                    if model.status == .working,
                       let event = model.recentEvents.last,
                       isAutoScrollEvent(event.type),
                       isConversationAtBottom {
                        withAnimation(.easeOut(duration: 0.2)) {
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
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text("Working…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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
                type.contains("warning") ||
                type == "message.start" ||
                type == "message.complete"
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
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 5, height: 5)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.type)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(event.detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.role == .hermes && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 0) {
                if message.role == .user {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(message.text.isEmpty ? "…" : message.text)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Color.accentColor.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 280, alignment: .trailing)

                        Text(Self.timeFormatter.string(from: message.timestamp))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if message.text.isEmpty {
                            EmptyView()
                        } else {
                            MarkdownMessageView(markdown: message.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !(model.status == .working && message.id == model.messages.last?.id) {
                            HStack(spacing: 4) {
                                Text(Self.timeFormatter.string(from: message.timestamp))
                                if let modelName = message.modelName {
                                    Text("·")
                                    Text(modelName)
                                }
                            }
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                            .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    // MARK: Activity helpers

    private func reasoningBlock(_ reasoning: ReasoningState) -> some View {
        DisclosureGroup(isExpanded: $model.isShowingReasoning) {
            Text(reasoning.text.isEmpty ? "…" : reasoning.text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
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
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func toolCallRow(_ call: ActiveToolCall) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(call.isComplete ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(call.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            if !call.input.isEmpty {
                Text(call.input)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if call.isComplete {
                if let result = call.result {
                    Text(result)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                } else {
                    Text("done")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11))
                Text("Approval required")
                    .font(.system(size: 11, weight: .semibold))
            }

            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .foregroundStyle(.primary)

            HStack(spacing: 6) {
                Button("Deny", role: .cancel) { model.respondToApproval("deny") }
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
                .fill(Color.primary.opacity(0.03))
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 5) {
            if speechInput.isRecording {
                MicWaveform(isActive: true)
                    .frame(maxWidth: .infinity, minHeight: 38)
            } else {
                Button(action: { speechInput.toggle() }) {
                    Group {
                        if speechInput.isStarting {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: speechInput.isUnavailable ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(speechInput.isUnavailable ? Color.orange : Color.secondary)
                                .frame(width: 28, height: 28)
                        }
                    }
                }
                .buttonStyle(.plain)
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
                    .frame(minHeight: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
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
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.red)
                        )
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(
                            model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending
                            ? Color.secondary
                            : Color.white
                        )
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending
                                    ? Color.primary.opacity(0.06)
                                    : Color.accentColor
                                )
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(!speechInput.isRecording && (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending))
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.red.opacity(speechInput.isRecording ? (isComposerPulsing ? 0.12 : 0.05) : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(
                    speechInput.isRecording
                    ? Color.red.opacity(isComposerPulsing ? 0.65 : 0.28)
                    : Color.clear,
                    lineWidth: 1
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
            .foregroundStyle(Color.red)
            .frame(width: 28, height: 28)
        }
    }
}
