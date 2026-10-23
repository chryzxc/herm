import SwiftUI

struct PullRequestFloatingChatView: View {
    @ObservedObject var chat: PullRequestChatModel
    @ObservedObject var runtime: DockModel
    let record: PullRequestRecord
    @Environment(\.chatContextRouter) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State var expanded = false
    @State private var reviewingDelivery = false
    private var style: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }
    private var unavailable: String? { runtime.quickMessageUnavailableReason(for: chat.destination?.session) }

    var body: some View {
        VStack(spacing: 0) {
            if expanded {
                HStack(spacing: 8) {
                    DockIcon(.chatCircleText, size: 16, color: .dockSecondaryText)
                    Text("Chat").dockFont(.body, weight: .semibold)
                    Text("· #\(record.displayNumber)").dockFont(.body).foregroundStyle(Color.dockMetadataText)
                    Spacer(minLength: 0)
                    if chat.destination?.session != nil {
                        DockIconButton(
                            icon: .arrowSquareOut, label: "Open PR conversation", size: 28, style: style,
                            action: openConversation)
                    }
                    DockIconButton(icon: .caretDown, label: "Minimize PR chat", size: 28, style: style) {
                        expanded = false
                        focused = false
                    }
                }.padding(.horizontal, 14).padding(.vertical, 10)
                Color.dockBorderLight.frame(height: DockLayout.hairline)
                transcript
                Color.dockBorderLight.frame(height: DockLayout.hairline)
            }
            HStack(alignment: .center, spacing: 8) {
                if !expanded {
                    DockIconButton(icon: .chatCircleText, label: "Show PR chat", size: 28, style: style) {
                        expanded = true
                        focused = true
                    }
                }
                DockTextField("Ask about this pull request", text: $chat.text, axis: .vertical)
                    .textFieldStyle(.plain).dockFont(.body).lineLimit(1...4).focused($focused)
                    .disabled(chat.sending || chat.needsReview)
                    .onSubmit(submit)
                    .accessibilityLabel("Ask about this pull request")
                    .padding(.vertical, 7)
                Button(action: submit) {
                    Group {
                        if chat.sending {
                            ProgressView().controlSize(.small)
                        } else {
                            DockIcon(.arrowUp, size: 18, color: .dockPrimaryText)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.dockSurface4))
                    .contentShape(Circle())
                }
                .buttonStyle(.dockHover)
                .disabled(!chat.canSend || unavailable != nil)
                .accessibilityLabel(chat.sending ? "Sending message" : "Send message")
                .help(unavailable ?? (chat.running ? "Wait for the current reply" : "Send message"))
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
        }
        .foregroundStyle(Color.dockPrimaryText)
        .background(
            DockThemeShape(cornerRadius: expanded ? DockLayout.paneRadius : 28).dockSurfaceFill(Color.dockCanvas)
        )
        .clipShape(DockThemeShape(cornerRadius: expanded ? DockLayout.paneRadius : 28))
        .overlay(
            DockThemeShape(cornerRadius: expanded ? DockLayout.paneRadius : 28)
                .stroke(focused ? Color.dockAccent : Color.dockBorder, lineWidth: DockLayout.hairline)
        )
        .shadow(color: Color.dockPrimaryText.opacity(0.08), radius: 16, y: 4)
        .frame(idealWidth: 520, maxWidth: 620)
        .animation(reduceMotion ? nil : .dockEase(duration: 0.2), value: expanded)
        .onChange(of: focused) { _, focused in if focused { expanded = true } }
        .task(id: chat.destination?.sessionKey) {
            while !Task.isCancelled, chat.destination?.session != nil {
                await chat.refresh(client: runtime.controlRPCClient)
                do { try await Task.sleep(for: .seconds(expanded || chat.running ? 2 : 10)) } catch { return }
            }
        }
        .confirmationDialog("Have you checked this message in its conversation?", isPresented: $reviewingDelivery) {
            Button("I checked; allow deliberate retry") { chat.allowDeliberateRetry() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The last submission was not confirmed. If it arrived, continue in its conversation. Only retry here if it did not arrive."
            )
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if chat.messages.isEmpty {
                        Text("Ask about this pull request").dockFont(.body, weight: .semibold)
                        Text("This pull request is included as context.").dockFont(.body).foregroundStyle(
                            Color.dockSecondaryText)
                    }
                    ForEach(chat.messages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.isUser ? "You" : "Hermes").dockFont(.body, weight: .semibold)
                                .foregroundStyle(Color.dockMetadataText)
                            MarkdownMessageView(markdown: message.text)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(message.id)
                    }
                    if chat.running || chat.sending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(
                                chat.needsAttention
                                    ? "Your response is needed in the conversation"
                                    : chat.sending ? "Sending…" : "Working…")
                        }.dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    }
                    if let error = chat.error ?? unavailable {
                        Text(error).dockFont(.body).foregroundStyle(Color.dockWarning)
                        Button("Refresh conversation") { Task { await chat.refresh(client: runtime.controlRPCClient) } }
                            .buttonStyle(.dockCompact).disabled(chat.sending || chat.destination == nil)
                    }
                    if chat.needsReview {
                        Button("Review interrupted delivery") { reviewingDelivery = true }.buttonStyle(.dockCompact)
                    }
                    if chat.needsAttention || chat.needsReview {
                        Button("Open conversation", action: openConversation).buttonStyle(.dockSecondary)
                            .disabled(chat.destination?.session == nil)
                    }
                    Color.clear.frame(height: 1).id("tail")
                }.padding(16)
            }
            .frame(height: 280)
            .onChange(of: chat.messages) { _, _ in proxy.scrollTo("tail", anchor: .bottom) }
            .onAppear { proxy.scrollTo("tail", anchor: .bottom) }
        }
    }

    private func submit() {
        guard chat.canSend, unavailable == nil else { return }
        expanded = true
        Task {
            await chat.submit(record, client: runtime.controlRPCClient, remember: runtime.rememberQuickSession)
            runtime.loadSessions()
            await chat.refresh(client: runtime.controlRPCClient)
        }
    }

    private func openConversation() {
        guard let session = chat.destination?.session else { return }
        runtime.resumeSession(session)
        router?.onOpened(session.id)
    }
}
