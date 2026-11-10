import SwiftUI

struct SessionInspectorEmptyView: View {
    let sections: [SessionInspector.Section]
    let onOpen: (SessionInspector.Section) -> Void
    /// Conversations that can open in a split column beside this one.
    var bots: [BotSummary] = []
    var botAvatars: [String: Data] = [:]
    /// Every pickable session; the menu shows the most recent until a search narrows it.
    var sessions: [HermesSession] = []
    @State private var botQuery = ""
    @State private var sessionQuery = ""

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
                    if !bots.isEmpty || !sessions.isEmpty {
                        // A small menu of sources; each opens its list in a side submenu.
                        DockMenu {
                            if !bots.isEmpty {
                                DockMenu("Bot chat", icon: .robot) { botRows }
                            }
                            if !sessions.isEmpty {
                                DockMenu("Recent session", icon: .chatCircle) { sessionRows }
                            }
                        } label: {
                            card(
                                title: "Conversation", detail: "Open a session or Bot chat in split view",
                                icon: .columnsPlusRight)
                        }
                        .accessibilityLabel("Open a conversation in split view")
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

    @ViewBuilder
    private var botRows: some View {
        DockSearchField(placeholder: "Search Bots", text: $botQuery).frame(width: 240).dockPadding(.bottom, 4)
        let query = botQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? bots : bots.filter { $0.name.localizedCaseInsensitiveContains(query) }
        if matches.isEmpty { noMatches }
        ForEach(matches) { bot in
            if let item = SessionPaneDrag(bot: bot) {
                Button {
                    SessionPaneStore.shared.open(item)
                } label: {
                    HStack(spacing: 8) {
                        BotAvatarView(bot: bot, imageData: botAvatars[bot.id], size: 18, animated: false)
                        Text(bot.name)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sessionRows: some View {
        DockSearchField(placeholder: "Search sessions", text: $sessionQuery).frame(width: 240)
            .dockPadding(.bottom, 4)
        let matches = SessionSidebarSearch.sessions(matching: sessionQuery, in: sessions, projects: [:])
            .prefix(sessionQuery.isEmpty ? 10 : 30)
        if matches.isEmpty { noMatches }
        ForEach(Array(matches)) { session in
            Button {
                SessionPaneStore.shared.open(SessionPaneDrag(session: session))
            } label: {
                HStack(spacing: 8) {
                    Text(session.displayTitle).lineLimit(1).frame(maxWidth: 280, alignment: .leading)
                    if let date = session.lastUpdatedAt {
                        Spacer(minLength: 12)
                        Text(SidebarSessionTime.short(date))
                            .foregroundStyle(Color.dockMetadataText).monospacedDigit()
                    }
                }
            }
        }
    }

    private var noMatches: some View {
        Text("No matches")
            .dockFont(.body)
            .foregroundStyle(Color.dockMetadataText)
            .dockPadding(.horizontal, 8)
            .dockPadding(.vertical, 6)
    }
}
