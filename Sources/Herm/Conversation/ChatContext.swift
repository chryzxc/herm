import SwiftUI

/// A block of context (a Kanban card, a pull request, an issue) attached to
/// the composer. It renders as a chip and is prepended to the next prompt.
struct ChatContext: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case general, terminal, diff, conversation, file, capture }
    var kind = Kind.general
    var inlineToken: String? = nil
    /// Stable source identity, so attaching the same item twice is a no-op.
    let id: String
    let title: String
    let body: String
    /// Project a new chat should be scoped to, when the source has one.
    var attachmentURL: URL? = nil
    var projectPath: String? = nil

    static func prompt(_ text: String, contexts: [ChatContext]) -> String {
        var rendered = text
        for context in contexts {
            if let token = context.inlineToken {
                rendered = rendered.replacingOccurrences(of: token, with: context.body)
            }
        }
        return (contexts.filter { $0.inlineToken == nil }.map(\.body) + [rendered]).filter { !$0.isEmpty }.joined(
            separator: "\n\n")
    }

    init(id: String, title: String, body: String, projectPath: String? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.projectPath = projectPath
    }

    init(kanbanTask task: KanbanTaskSummary) {
        var lines = ["Kanban task \(task.id): \"\(task.title)\"", "Status: \(task.status)"]
        if let priority = task.priority, !priority.isEmpty { lines.append("Priority: \(priority)") }
        if let assignee = task.assignee, !assignee.isEmpty { lines.append("Assignee: \(assignee)") }
        if let board = task.boardSlug, !board.isEmpty { lines.append("Board: \(board)") }
        if let detail = task.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            lines += ["", detail]
        }
        self.init(id: "kanban:\(task.id)", title: task.title, body: lines.joined(separator: "\n"))
    }

    init(pullRequest pr: PullRequestRecord) {
        self.init(
            id: pr.id,
            title: "PR #\(pr.displayNumber) \(pr.title)",
            body: """
                Pull request #\(pr.displayNumber), "\(pr.title)", in \(pr.repository.id).
                PR: \(pr.webURL?.absoluteString ?? "Unavailable")
                Branch: \(pr.headBranch) → \(pr.baseBranch)
                Head: \(pr.headRevision ?? "unknown")
                Readiness: \(pr.readinessLabel)
                Description:
                \(String(pr.body.prefix(12_000)))
                """,
            projectPath: pr.localPath.isEmpty ? nil : pr.localPath
        )
    }

    init(issue: GitHubIssueRecord) {
        self.init(
            id: "github:\(issue.repository.id)#\(issue.number)",
            title: "Issue #\(issue.number) \(issue.title)",
            body: """
                Issue #\(issue.number), "\(issue.title)", in \(issue.repository.id).
                Issue: \(issue.webURL?.absoluteString ?? "Unavailable")
                Description:
                \(String(issue.body.prefix(12_000)))
                """,
            projectPath: issue.localPath.isEmpty ? nil : issue.localPath
        )
    }

    init(repository: GitHubRepositorySummary) {
        var lines = [
            "GitHub repository \(repository.id).", "Repository: \(repository.reference.webURL.absoluteString)",
        ]
        if let branch = repository.defaultBranch { lines.append("Default branch: \(branch)") }
        if let language = repository.language { lines.append("Language: \(language)") }
        if !repository.description.isEmpty { lines += ["Description:", repository.description] }
        self.init(id: "github:\(repository.id)", title: repository.id, body: lines.joined(separator: "\n"))
    }
}

/// Stable, app-wide handle for "attach to chat". A class (not a closure) in
/// the environment so equatable views like the Kanban board don't re-render
/// every time the host view re-evaluates.
@MainActor
final class ChatContextRouter {
    weak var model: DockModel?
    weak var bots: BotModeModel?
    /// Called once the target session is active, so the host can navigate to it.
    var onOpened: (String?) -> Void = { _ in }

    func attachToCurrentChat(_ context: ChatContext) {
        guard let model else { return }
        model.attachedContexts.removeAll { $0.id == context.id }
        model.attachedContexts.append(context)
        model.requestComposerFocus()
    }

    var recentSessions: [HermesSession] {
        (model?.sessions ?? [])
            .filter { !$0.isHidden }
            .sorted { ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast) }
            .prefix(10)
            .map { $0 }
    }

    /// `nil` session starts a new chat.
    func attach(_ context: ChatContext, to session: HermesSession?) {
        guard let model else { return }
        Task {
            await model.attachContext(context, to: session)
            onOpened(model.sessionID)
        }
    }
}

private struct ChatContextRouterKey: EnvironmentKey {
    static let defaultValue: ChatContextRouter? = nil
}

extension EnvironmentValues {
    var chatContextRouter: ChatContextRouter? {
        get { self[ChatContextRouterKey.self] }
        set { self[ChatContextRouterKey.self] = newValue }
    }
}

/// "Attach to chat" submenu: a new chat or one of the recent sessions.
/// Hidden when no router is installed (previews, detached windows).
struct AttachToChatMenu: View {
    /// Header pill matching `GitHubLinkButton`; off for context menus.
    var pill = false
    /// Icon-only button for rows of `DockIconButton` actions; wins over `pill`.
    var icon = false
    let context: () -> ChatContext
    @Environment(\.chatContextRouter) private var router

    var body: some View {
        if let router {
            if icon {
                DockMenu {
                    items(router)
                } label: {
                    DockIconButtonLabel(icon: .chatCircleText)
                }
                .buttonStyle(.dockHover)
                .fixedSize()
                .help("Attach to chat")
                .accessibilityLabel("Attach to chat")
            } else if pill {
                DockMenu {
                    items(router)
                } label: {
                    HStack(spacing: 5) {
                        DockIcon(.chatCircleText, size: 12, color: Color.dockSecondaryText)
                        Text("Attach to chat")
                        DockIcon(.caretDown, size: 10, color: Color.dockMetadataText)
                    }
                    .dockFont(.body, weight: .medium)
                    .foregroundStyle(Color.dockSecondaryText)
                    .dockPadding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous)
                            .dockSurfaceFill(Color.dockControlSurface.opacity(0.6))
                    )
                }
                .buttonStyle(.dockHover)
                .fixedSize()
            } else {
                DockMenu("Attach to chat", icon: .chatCircleText) { items(router) }
            }
        }
    }

    @ViewBuilder
    private func items(_ router: ChatContextRouter) -> some View {
        Button("New chat") { router.attach(context(), to: nil) }
        let sessions = router.recentSessions
        if !sessions.isEmpty {
            Divider()
            ForEach(sessions) { session in
                Button(session.title.isEmpty ? "Untitled chat" : session.title) {
                    router.attach(context(), to: session)
                }
            }
        }
    }
}
