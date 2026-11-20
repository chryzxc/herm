import SwiftUI

struct HermChangelogView: View {
    @State private var selected = HermReleaseHighlights.latest

    var body: some View {
        SettingsSection(title: "Herm changelog", subtitle: "", tint: .dockAccent) {
            HStack {
                DockMenuPicker(title: "Herm \(selected.version)", selection: $selected) {
                    ForEach(HermReleaseHighlights.history, id: \.version) { release in
                        DockMenuOption("Herm \(release.version)", value: release)
                    }
                }
                Text(selected.date)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
            }
            Divider()
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 320), spacing: 24, alignment: .topLeading)],
                alignment: .leading, spacing: 16
            ) {
                ForEach(selected.notes, id: \.self) { note in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.title)
                            .dockFont(.body, weight: .semibold)
                        Text(note.detail)
                            .dockFont(.body)
                            .foregroundStyle(Color.dockSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            }
            if let url = URL(
                string: "https://github.com/\(HermAppUpdater.repository)/releases/tag/v\(selected.version)")
            {
                Link("Full release notes on GitHub", destination: url)
                    .buttonStyle(.dockLink)
            }
        }
    }
}

struct HermReleaseHighlights: Hashable {
    struct Note: Hashable {
        let title: String
        let detail: String

        init(_ title: String, _ detail: String) {
            self.title = title
            self.detail = detail
        }
    }

    let version: String
    let date: String
    let notes: [Note]

    static let latest = Self(
        version: "0.4.0", date: "November 18, 2026",
        notes: [
            Note(
                "Find chats across profiles",
                "Choose All profiles in the session sidebar to browse conversations together. Drag profiles in the picker to arrange them in the order you use them."
            ),
            Note(
                "Separate automation runs",
                "Automation sessions have their own sidebar section. You can move that section to keep scheduled work close at hand or give conversations priority."
            ),
            Note(
                "Review requests in context",
                "Approval requests appear inside the conversation that raised them. Once you make a decision, the pending approval card clears from the chat."
            ),
            Note(
                "Switch Kanban boards",
                "Open Kanban to create a board or switch to an existing one. Herm now loads the available boards through the dashboard API."
            ),
            Note(
                "Send several PDFs together",
                "Attach multiple PDFs in the chat composer and send them in one message, so the conversation has all the documents for your question."
            ),
            Note(
                "Scroll busy conversations",
                "Herm reuses more of the Markdown layout and pauses decorative motion while you scroll. An open browser tab also skips redraws caused solely by incoming chat text."
            ),
        ])
    static let history = [
        latest,
        Self(
            version: "0.3.0", date: "November 17, 2026",
            notes: [
                Note(
                    "Organize conversations by project",
                    "Choose a project when you start a conversation, or move an existing chat to another project later."
                ),
                Note(
                    "Pick up where you left off",
                    "Switching sessions restores the loaded transcript and your reading position. Drag sessions into tabs or columns to work on them side by side."
                ),
                Note(
                    "Update Herm in the app",
                    "Stable and nightly builds support signed in-app updates. Herm checks on activation and marks the Settings row when an update is available."
                ),
                Note(
                    "Type with an input method",
                    "While you compose text with an input method, Return and the arrow keys stay available to confirm or navigate candidates in the composer."
                ),
            ]),
        Self(
            version: "0.2.1", date: "November 14, 2026",
            notes: [
                Note(
                    "Pause while speaking",
                    "Voice capture keeps words spoken before a pause and avoids repeating replies. Leaving full voice mode keeps the Talk tab open."
                ),
                Note(
                    "Use Talk in a narrow pane",
                    "Call controls share one row, and the Talk layout avoids overlapping controls. Voice activity cards stay visible until each step finishes."
                ),
                Note(
                    "Reconnect a remote gateway",
                    "If the connection drops, Herm retries the remote gateway. After you sign in again, Herm reconnects to the gateway."
                ),
            ]),
        Self(
            version: "0.2.0", date: "November 13, 2026",
            notes: [
                Note(
                    "Reuse a prompt",
                    "The chat composer can capture context and reuse saved prompt drafts, so you can start another conversation with the same instructions."
                ),
                Note(
                    "Review a pull request",
                    "Review changes inline and open a chat scoped to the pull request. Repository tools also include stash controls and a commit graph."
                ),
                Note(
                    "Plan work in the calendar",
                    "Search the agenda for an event and use overlap indicators to see which events compete for the same time."
                ),
            ]),
    ]
}
