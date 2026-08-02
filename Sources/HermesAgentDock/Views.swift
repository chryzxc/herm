import SwiftUI
import Foundation

/// A small native Markdown surface for assistant replies. Foundation's
/// Markdown parser handles emphasis, headings, links, lists, and inline code;
/// fenced blocks get a deliberately simple monospaced treatment here.
private struct MarkdownMessageView: View {
    let markdown: String

    private enum Block {
        case markdown(String)
        case code(String, language: String?)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let text):
                    if let rendered = renderedMarkdown(text) {
                        Text(rendered)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .code(let code, _):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                    }
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
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
            if !text.isEmpty { result.append(.markdown(text)) }
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
            return try AttributedString(
                markdown: value,
                options: .init(interpretedSyntax: .full)
            )
        } catch {
            return AttributedString(value)
        }
    }
}

struct DockPopover: View {
    @ObservedObject var model: DockModel

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
            footer
        }
        .frame(width: 420, height: 600)
        .task {
            model.restoreLatestSessionIfNeeded()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { model.toggleSessions() } label: {
                HStack(spacing: 5) {
                    Text(model.currentSessionTitle ?? "Hermes Agent")
                        .font(.system(size: 16, weight: .semibold))
                    Image(systemName: model.isShowingSessions ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button("New chat") { model.newChat() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var sessionPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversations")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.isLoadingSessions {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.loadSessions() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh conversations")
                }
            }
            .padding(.bottom, 7)

            if model.sessions.isEmpty && !model.isLoadingSessions {
                Text("No saved conversations")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 7)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.sessions) { session in
                            Button { model.resumeSession(session) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(session.displayTitle)
                                            .lineLimit(1)
                                        Spacer()
                                        if let date = session.startedAt {
                                            Text(date, style: .relative)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    if !session.preview.isEmpty {
                                        Text(session.preview)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(model.messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                    if model.status == .working {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let approval = model.approvalText {
                        approvalRow(approval)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .onChange(of: model.messages.count) { _, _ in
                if let last = model.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.role == .user {
            VStack(alignment: .trailing, spacing: 5) {
                Text(message.text.isEmpty ? "…" : message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: 300, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                if message.text.isEmpty {
                        Text("…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarkdownMessageView(markdown: message.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
            }
        }
    }

    private func approvalRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hermes is waiting for approval")
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 11))
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Button("Allow") { model.respondToApproval("once") }
                    .buttonStyle(.borderedProminent)
                Button("Deny", role: .cancel) { model.respondToApproval("deny") }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.top, 4)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Hermes…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { model.send() }
            Button { model.send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            if model.isSending {
                Button("Stop", role: .destructive) { model.stop() }
                    .buttonStyle(.borderless)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}
