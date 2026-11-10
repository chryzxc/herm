import SwiftUI

struct SessionInspectorEmptyView: View {
    let sections: [SessionInspector.Section]
    let onOpen: (SessionInspector.Section) -> Void
    /// Conversations that can open in a split column beside this one.
    var botChats: [SessionPaneDrag] = []
    var sessions: [SessionPaneDrag] = []
    @State private var isPickingConversation = false

    private func detail(_ section: SessionInspector.Section) -> String {
        switch section {
        case .browser: "Open a page or search the web"
        case .terminal: "Run commands in your workspace"
        case .files: "Browse project files"
        case .artifacts: "Explore this session’s outputs"
        case .changes: "Review repository changes"
        case .timeline: "Inspect session activity"
        case .diff: "Review the attached diff"
        case .github: "Follow the linked pull request or issue"
        case .iosSimulator: "Run the app in an iOS Simulator"
        case .androidEmulator: "Run the app in an Android Emulator"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open a new tab")
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("Choose a tool to use alongside your conversation.")
                        .dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                    ForEach(sections) { section in
                        Button {
                            onOpen(section)
                        } label: {
                            card(title: section.navigationTitle, detail: detail(section), icon: section.icon)
                        }
                        .buttonStyle(.dockHover)
                        .accessibilityLabel("Open \(section.navigationTitle) tab")
                    }
                    if !botChats.isEmpty || !sessions.isEmpty {
                        Button {
                            isPickingConversation = true
                        } label: {
                            card(
                                title: "Conversation", detail: "Open a session or Bot chat in split view",
                                icon: .columnsPlusRight)
                        }
                        .buttonStyle(.dockHover)
                        .accessibilityLabel("Open a conversation in split view")
                        .dockPopover(isPresented: $isPickingConversation, arrowEdge: .bottom) { conversationPicker }
                    }
                }
            }
            .frame(maxWidth: 480)
            .dockPadding(DockSpacing.inspectorInset)
            .dockPadding(.top, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.dockCanvas)
    }

    private func card(title: String, detail: String, icon: Ph) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DockIcon(icon, size: 16, color: .dockSecondaryText)
                Text(title)
                    .dockFont(.body, weight: .semibold)
                Spacer(minLength: 0)
                DockIcon(.plus, size: 12, color: .dockSecondaryText)
            }
            Text(detail)
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.dockPrimaryText)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dockCard(padding: 12)
        .contentShape(Rectangle())
    }

    private var conversationPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !botChats.isEmpty { pickerSection("Bot chats", botChats, icon: .robot) }
                if !sessions.isEmpty { pickerSection("Recent sessions", sessions, icon: .chatCircle) }
            }
            .dockPadding(6)
        }
        .frame(width: 260)
        .frame(maxHeight: 360)
    }

    private func pickerSection(_ title: String, _ items: [SessionPaneDrag], icon: Ph) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .dockFont(.metadata, weight: .semibold)
                .foregroundStyle(Color.dockSecondaryText)
                .dockPadding(.horizontal, 8)
                .dockPadding(.top, 6)
            ForEach(items, id: \.sessionID) { item in
                Button {
                    isPickingConversation = false
                    SessionPaneStore.shared.open(item)
                } label: {
                    HStack(spacing: 8) {
                        DockIcon(icon, size: 14, color: .dockSecondaryText)
                        Text(item.title).dockFont(.body, weight: .medium).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .dockPadding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
            }
        }
    }
}
