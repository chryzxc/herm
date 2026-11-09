import Foundation
import SwiftUI

struct PullRequestDetailView: View {
    @ObservedObject var center: PullRequestCenterModel
    let onOpenChat: (PullRequestRecord) -> Void
    var isInspector = false

    init(
        center: PullRequestCenterModel, onOpenChat: @escaping (PullRequestRecord) -> Void, isInspector: Bool = false,
        initialTab: Int = 0
    ) {
        _center = ObservedObject(wrappedValue: center)
        _chats = ObservedObject(wrappedValue: center.details.chats)
        self.onOpenChat = onOpenChat
        self.isInspector = isInspector
        _detailTab = State(initialValue: initialTab)
    }

    @State private var reviewerRecord: PullRequestRecord?
    @State private var commitDiffTarget: PullRequestCommitDiffTarget?
    @State private var readingGuide = false
    @StateObject private var guide = ReviewGuideCoordinator()
    @ObservedObject private var watches = PullRequestWatchStore.shared
    @Environment(\.chatContextRouter) private var contextRouter
    @State private var detailRefreshID = 0
    @State private var detailTab: Int
    @State private var expandedSheet = false
    @Environment(\.expandedReviewRouter) private var reviewRouter
    @State private var inlineTarget: GitHubInlineCommentTarget?
    @StateObject private var reviewPreferences = PullRequestReviewPreferenceStore()
    @State private var selectedFileID: String?
    @State private var fileQuery = ""
    @State private var sourceDiffFileIDs: Set<String> = []
    @State private var checksExpanded = true
    @State private var activityExpanded = true
    @State private var changesExpanded = false
    @State private var chatExpanded = false
    @ObservedObject private var chats: PullRequestChatStore
    private var commentDraft: String { center.commentDrafts[center.selectedID ?? ""] ?? "" }
    @StateObject private var diffPresentationCache = PullRequestDiffPresentationCache()
    @StateObject private var mutationCoordinator = PullRequestMutationCoordinator()
    @Environment(\.dockTitleRow) private var titleRow

    var body: some View {
        detailPane
            .dockSheet(item: $commitDiffTarget) { target in
                PullRequestCommitDiffView(
                    target: target, client: center.api.client,
                    commitCheckEvidence: center.commitCheckEvidence(for: target.repository)
                )
                .frame(minWidth: 700, minHeight: 560).modifier(ReviewSheetContext())
            }
            .dockSheet(item: $reviewerRecord) { record in
                PullRequestReviewerPicker(record: record, client: center.api.client) {
                    Task { await center.refreshSelectedDetail() }
                }
            }
            .dockSheet(isPresented: $expandedSheet) {
                expandedReview { expandedSheet = false }
                    .frame(minWidth: 900, minHeight: 640).modifier(ReviewSheetContext())
            }
            .dockSheet(isPresented: $readingGuide) {
                if let model = contextRouter?.model, let pr = center.selected {
                    ReviewGuideView(
                        coordinator: guide, model: model,
                        currentIdentity: (pr.headRevision ?? "unknown") + ":" + (pr.baseRevision ?? "unknown"),
                        directory: pr.localPath.isEmpty ? nil : pr.localPath
                    ).modifier(ReviewSheetContext())
                }
            }
            .task(id: "\(center.selectedID ?? ""):\(center.isRefreshing):\(detailRefreshID)") {
                guard center.selectedID != nil, !center.isRefreshing else { return }
                await center.loadSelectedDetail()
            }
            .onChange(of: center.selectedID) { _, _ in
                chatExpanded = false
                inlineTarget = nil
                commitDiffTarget = nil
                selectedFileID = nil
                sourceDiffFileIDs.removeAll()
                diffPresentationCache.removeAll()
                checksExpanded = true
                activityExpanded = true
                mutationCoordinator.cancel()
            }
            .confirmationDialog(
                "Confirm GitHub change?",
                isPresented: Binding(
                    get: { mutationCoordinator.pending != nil },
                    set: { if !$0 { mutationCoordinator.cancel() } }
                ),
                presenting: mutationCoordinator.pending
            ) { request in
                switch request {
                case .comment:
                    Button("Post comment") {
                        Task {
                            _ = await mutationCoordinator.confirm(request, using: center)
                        }
                    }
                case .status(_, let status):
                    Button(
                        status == .closed ? "Close pull request" : status.rawValue,
                        role: status == .closed ? .destructive : nil
                    ) {
                        Task { _ = await mutationCoordinator.confirm(request, using: center) }
                    }
                }
                Button("Cancel", role: .cancel) { mutationCoordinator.cancel() }
            } message: { request in
                mutationConfirmationMessage(request)
            }
    }

    private func mutationConfirmationMessage(_ request: PullRequestMutationRequest) -> Text {
        switch request {
        case .comment(let record, let body):
            return Text("Post this comment to \(record.repository.id) pull request #\(record.number)?\n\n\(body)")
        case .status(let record, let status):
            if status == .closed {
                return Text("This will close pull request #\(record.number) in \(record.repository.id).")
            }
            if status == .draft { return Text("Convert \(record.reference.title) to a draft pull request?") }
            if status == .reopened { return Text("Reopen \(record.reference.title) on GitHub?") }
            return Text("This will mark pull request #\(record.number) in \(record.repository.id) ready for review.")
        }
    }

    @ViewBuilder private var detailPane: some View {
        // Search rows carry placeholder refs/stats until the detail fetch
        // lands; a failed fetch stores files so this cannot spin forever.
        if let pr = center.selected, pr.changedFiles == nil, center.filesByID[pr.id] == nil {
            detailLoadingPane
        } else if let pr = center.selected {
            VStack(alignment: .leading, spacing: 0) {
                // Header stays above the scroller so scrolled content never draws over or steals clicks from it.
                detailHeader(pr).zIndex(1)
                if detailTab == 0 {
                    GeometryReader { geometry in
                        ScrollView {
                            summary(pr, wide: geometry.size.width >= 840)
                                .dockPadding(.horizontal, isInspector ? DockSpacing.inspectorInset : 24)
                        }.clipped()
                    }
                } else if detailTab == 2 {
                    PullRequestReviewView(
                        model: center.review(for: pr), record: pr, viewer: center.viewerLogin,
                        onChanged: { Task { await center.refreshSelectedDetail() } },
                        horizontalPadding: isInspector ? DockSpacing.inspectorInset : 20,
                        onReviewCode: { detailTab = 1 },
                        onEditComment: { target in
                            guard center.review(for: pr).beginInline(target, record: pr) else { return }
                            inlineTarget = target
                            detailTab = 1
                            if let file = center.filesByID[pr.id]?.first(where: { $0.path == target.path }) {
                                selectedFileID = file.id
                                if !reviewPreferences.expandedFileIDs.contains(file.id) {
                                    reviewPreferences.toggleExpanded(file.id)
                                }
                                sourceDiffFileIDs.insert(file.id)
                            }
                        }
                    )
                } else {
                    code(pr).dockPadding(.horizontal, isInspector ? DockSpacing.inspectorInset : 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                if !isInspector, let model = contextRouter?.model {
                    PullRequestFloatingChatView(
                        chat: chats.chat(for: pr), runtime: model, record: pr, expanded: $chatExpanded
                    )
                    .id(pr.id)
                    .dockPadding(20)
                }
            }
        } else if center.isInitialLoad {
            detailLoadingPane
        } else {
            VStack(spacing: 12) {
                DockIcon(.gitPullRequest, size: 28, color: Color.dockMetadataText)
                Text(center.isRefreshing ? "Loading pull requests…" : "Select a pull request").dockFont(
                    size: 15, weight: .medium)
            }.foregroundStyle(Color.dockMetadataText).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var detailLoadingPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RepositoryShimmerBlock(width: 72, height: 22, cornerRadius: 7)
                RepositoryShimmerBlock(width: 48, height: 22, cornerRadius: 7)
                Spacer()
                RepositoryShimmerBlock(width: 88, height: 28, cornerRadius: 7)
            }
            .dockPadding(.horizontal, isInspector ? DockSpacing.inspectorInset : 16)
            .frame(height: 52)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading pull request")
                            .dockFont(.body, weight: .medium)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    RepositoryShimmerBlock(width: nil, height: 28, cornerRadius: 7)
                    RepositoryShimmerBlock(width: 390, height: 28, cornerRadius: 7)
                    HStack(spacing: 10) {
                        RepositoryShimmerBlock(width: 32, height: 32, cornerRadius: 16)
                        RepositoryShimmerBlock(width: 126, height: 12, cornerRadius: 4)
                    }
                    RepositoryShimmerBlock(width: nil, height: 1, cornerRadius: 0)
                    ForEach(0..<5, id: \.self) { index in
                        HStack(spacing: 14) {
                            RepositoryShimmerBlock(width: 88, height: 11, cornerRadius: 4)
                            RepositoryShimmerBlock(
                                width: index.isMultiple(of: 2) ? 236 : 176, height: 11, cornerRadius: 4)
                        }
                    }
                    RepositoryShimmerBlock(width: nil, height: 1, cornerRadius: 0)
                    RepositoryShimmerBlock(width: 112, height: 15, cornerRadius: 5)
                    RepositoryShimmerBlock(width: nil, height: 82, cornerRadius: 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dockPadding(.horizontal, isInspector ? DockSpacing.inspectorInset : 24)
                .dockPadding(.top, 24)
                .dockPadding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading pull request")
    }

    private func detailHeader(_ pr: PullRequestRecord) -> some View {
        let fileIDs = Set((center.filesByID[pr.id] ?? []).map(\.id))
        let inset: CGFloat = isInspector ? DockSpacing.inspectorInset : 16
        return VStack(spacing: 0) {
            // One toolbar row: tabs lead, actions trail. Narrow widths stack the actions beneath.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    detailTabs(pr)
                    Spacer(minLength: 0).background { if titleRow != nil { TitlebarDoubleClickArea() } }
                    detailActions(pr, compact: true)
                }
                HStack(spacing: 12) {
                    detailTabs(pr, compact: true)
                    Spacer(minLength: 0).background { if titleRow != nil { TitlebarDoubleClickArea() } }
                    detailActions(pr, compact: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    detailTabs(pr, compact: true)
                    detailActions(pr, compact: true, wraps: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .dockPadding(.horizontal, inset).dockPadding(.vertical, 8)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }

            if detailTab == 1 {
                HStack(spacing: 8) {
                    Text(pr.headBranch).lineLimit(1).truncationMode(.middle)
                    DockIcon(.arrowRight, size: 12, color: Color.dockMetadataText)
                    Text(pr.baseBranch).lineLimit(1).layoutPriority(1)
                    if !center.filesAreCurrent(for: pr) {
                        Text("Diff may be outdated. Refresh to review.")
                            .dockFont(.metadata).foregroundStyle(Color.dockWarning).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    codeToolbar(fileIDs: fileIDs)
                }
                .dockFont(.body, weight: .medium)
                .foregroundStyle(Color.dockMetadataText)
                .dockPadding(.horizontal, inset)
                .frame(height: 38)
                .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
            }
        }
        .background(Color.dockCanvas)
    }
    private func summary(_ pr: PullRequestRecord, wide: Bool) -> some View {
        let layout =
            wide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 36))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
        return VStack(alignment: .leading, spacing: 28) {
            summaryIdentity(pr)
            layout {
                summaryConversation(pr)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        if wide {
                            Color.dockBorderLight.frame(width: DockLayout.hairline)
                                .offset(x: 18)
                                .accessibilityHidden(true)
                        }
                    }
                summarySidebar(pr)
                    .frame(width: wide ? 280 : nil)
                    .frame(maxWidth: wide ? 280 : .infinity, alignment: .leading)
            }
        }
        .dockPadding(.top, 24).dockPadding(.bottom, 28)
        .frame(maxWidth: 1240, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func summaryIdentity(_ pr: PullRequestRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                DockIcon(pr.presentationIcon, size: 14, color: pr.presentationColor)
                Text(pr.repository.id).lineLimit(1).truncationMode(.middle)
                Text("#\(pr.displayNumber)").foregroundStyle(Color.dockMetadataText)
                Spacer(minLength: 0)
                statusPicker(pr)
            }.dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            Text(pr.title)
                .dockFont(.pageTitle).foregroundStyle(Color.dockPrimaryText)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    summaryAuthor(pr)
                    branchRoute(pr)
                }
                VStack(alignment: .leading, spacing: 10) {
                    summaryAuthor(pr)
                    branchRoute(pr)
                }
            }
        }
    }

    private func summaryAuthor(_ pr: PullRequestRecord) -> some View {
        HStack(spacing: 8) {
            authorAvatar(pr)
            Text(pr.author).foregroundStyle(Color.dockPrimaryText)
            if let updatedAt = pr.updatedAt { Text("updated \(pullRequestAge(updatedAt)) ago") }
        }.dockFont(.body).foregroundStyle(Color.dockMetadataText)
    }

    private func summaryConversation(_ pr: PullRequestRecord) -> some View {
        let activity = activityItems(pr)
        return VStack(alignment: .leading, spacing: 28) {
            if pr.body.isEmpty {
                Text("No description provided.").dockFont(.body).foregroundStyle(Color.dockMetadataText)
            } else {
                PullRequestDescription(markdown: pr.body, html: pr.bodyHTML)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            VStack(alignment: .leading, spacing: 16) {
                DockSectionHeader(
                    title: "Activity", count: activity.count, isExpanded: $activityExpanded,
                    style: DockThemePalette(theme: DockThemeRuntime.current), isContentHeader: true)
                if activityExpanded {
                    if activity.isEmpty {
                        Text(center.isLoadingDetail(for: pr.id) ? "Loading activity…" : "No activity loaded.")
                            .dockFont(.body).foregroundStyle(Color.dockMetadataText)
                    } else {
                        GitHubTimelineView(
                            reference: pr.reference, items: activity,
                            commitCheckEvidence: center.commitCheckEvidence(for: pr.repository)
                        ) { sha in
                            if let commit = center.commitsByID[pr.id]?.first(where: { $0.id == sha }) {
                                commitDiffTarget = PullRequestCommitDiffTarget(
                                    repository: pr.repository, commit: commit)
                            }
                        }
                    }
                }
            }
            commentComposer(pr)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summarySidebar(_ pr: PullRequestRecord) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                DockSectionHeader(
                    title: "Changes", isExpanded: $changesExpanded,
                    style: DockThemePalette(theme: DockThemeRuntime.current), isContentHeader: true)
                changeTotals(pr)
                if changesExpanded {
                    PullRequestChangeBreakdownView(
                        files: center.filesByID[pr.id], expectedCount: pr.changedFiles,
                        isCurrent: center.filesAreCurrent(for: pr), isLoading: center.isLoadingDetail(for: pr.id),
                        onReviewFiles: { detailTab = 1 }, embedded: true)
                }
            }
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Reviewers").foregroundStyle(Color.dockMetadataText)
                    Text(
                        pr.requestedReviewers.isEmpty
                            ? "No reviewers requested" : pr.requestedReviewers.joined(separator: ", ")
                    )
                    .foregroundStyle(pr.requestedReviewers.isEmpty ? Color.dockSecondaryText : Color.dockReview)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if pr.state == "open" {
                    Button("Edit") { reviewerRecord = pr }.buttonStyle(.dockCompact)
                        .accessibilityLabel("Edit requested reviewers")
                }
            }.dockFont(.body)
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            VStack(alignment: .leading, spacing: 10) {
                DockSectionHeader(
                    title: "Checks", count: pr.checks.isEmpty ? nil : pr.checks.count, isExpanded: $checksExpanded,
                    style: DockThemePalette(theme: DockThemeRuntime.current), isContentHeader: true)
                if checksExpanded { checksSection(pr) }
            }
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            PullRequestReadinessView(center: center, record: pr, embedded: true)
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            GitHubMetadataView(reference: pr.reference, client: center.api.client, embedded: true) {
                Task { await center.refreshSelectedDetail() }
            }.id(pr.id)
        }
    }

    private func branchRoute(_ pr: PullRequestRecord) -> some View {
        HStack(spacing: 8) {
            DockIcon(.gitBranch, size: 14, color: .dockMerged)
            Text(pr.baseBranch).foregroundStyle(Color.dockPrimaryText)
                .dockPadding(.horizontal, 8).dockPadding(.vertical, 4)
                .dockWell(.sunken)
            DockIcon(.arrowLeft, size: 13, color: .dockMetadataText)
            Text(pr.headBranch).foregroundStyle(Color.dockSecondaryText)
        }.dockFont(.body, weight: .regular, design: .monospaced).lineLimit(1).truncationMode(.middle)
            .help("Merge \(pr.headBranch) into \(pr.baseBranch)")
    }

    private func changeTotals(_ pr: PullRequestRecord) -> some View {
        HStack(spacing: 8) {
            Button {
                detailTab = 1
            } label: {
                Text(pr.changedFiles.map { "\($0) files" } ?? "Changed files")
            }.buttonStyle(.dockLink)
            if let additions = pr.additions { Text("+\(additions)").foregroundStyle(Color.dockSuccess) }
            if let deletions = pr.deletions { Text("−\(deletions)").foregroundStyle(Color.dockDestructive) }
        }.dockFont(.body).monospacedDigit().fixedSize()
    }

    @ViewBuilder
    private func checksSection(_ pr: PullRequestRecord) -> some View {
        if pr.checks.isEmpty {
            HStack(spacing: 12) {
                Text(
                    pr.checksAvailable ? "No checks reported by GitHub." : "Check status unavailable. Refresh to retry."
                )
                .dockFont(.navigation)
                .foregroundStyle(Color.dockMetadataText)
                Spacer()
                DockIconButton(
                    icon: .arrowsClockwise, label: "Refresh checks", isBusy: center.isLoadingDetail, size: 24,
                    style: DockThemePalette(theme: DockThemeRuntime.current)
                ) {
                    center.invalidateSelectedDetail()
                    detailRefreshID += 1
                }
            }
            .dockPadding(.leading, 12)
            .dockPadding(.trailing, 8)
            .frame(minHeight: 44)
        } else {
            VStack(spacing: 0) {
                ForEach(pr.checks) { check in
                    HStack(spacing: 13) {
                        DockIcon(checkIcon(for: check), size: 14, color: checkColor(for: check))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(checkColor(for: check).opacity(0.12)))
                        if let url = check.detailsURL {
                            Link(check.name, destination: url).buttonStyle(.dockLink)
                        } else {
                            Text(check.name)
                        }
                        Spacer()
                        Text(checkPresentation(for: check))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    .dockFont(.navigation, weight: .medium)
                    .dockPadding(.horizontal, 12)
                    .frame(minHeight: 42)
                    if check.id != pr.checks.last?.id { Divider().dockPadding(.leading, 47) }
                }
            }
        }
    }

    private func activityItems(_ pr: PullRequestRecord) -> [GitHubConversationItem] {
        pr.activityItems(
            comments: center.commentsByID[pr.id] ?? [], commits: center.commitsByID[pr.id] ?? [],
            events: center.eventsByID[pr.id] ?? [])
    }

    private func commentComposer(_ pr: PullRequestRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Leave a comment").dockFont(.body, weight: .semibold)
            TextEditor(text: center.commentDraft(for: pr.id))
                .dockFont(.body).scrollContentBackground(.hidden)
                .dockPadding(4).frame(height: 104)
                .accessibilityLabel("Comment body")
            HStack {
                Text("\(commentDraft.count)/10000").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                Spacer()
                Button {
                    mutationCoordinator.requestComment(commentDraft, for: pr)
                } label: {
                    GitHubActionLabel(
                        title: center.isPostingComment ? "Posting…" : "Post comment", isBusy: center.isPostingComment)
                }.buttonStyle(.dockPrimary)
                    .disabled(
                        commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || commentDraft.count > 10_000 || center.isPostingComment)
            }
        }
        .dockPadding(16)
        .background(DockThemeShape(cornerRadius: DockLayout.paneRadius).dockSurfaceFill(Color.dockCanvas))
        .overlay(
            DockThemeShape(cornerRadius: DockLayout.paneRadius).stroke(Color.dockBorder, lineWidth: DockLayout.hairline)
        )
    }

    private func checkIcon(for check: GitHubCheckSummary) -> Ph {
        checkColor(for: check) == Color.dockSuccess
            ? .check : (checkColor(for: check) == Color.dockDestructive ? .x : .clock)
    }
    private func checkColor(for check: GitHubCheckSummary) -> Color {
        let conclusion = check.conclusion?.lowercased()
        if ["neutral", "skipped"].contains(conclusion) { return Color.dockMetadataText }
        if conclusion == "success" { return Color.dockSuccess }
        if ["failure", "cancelled", "timed_out", "action_required"].contains(conclusion) {
            return Color.dockDestructive
        }
        return check.isPending ? DockStatusTone.working.color : Color.dockSecondaryText
    }
    private func checkPresentation(for check: GitHubCheckSummary) -> String {
        guard check.status.lowercased() == "completed" else {
            return check.status.lowercased() == "in_progress"
                ? "Running" : (check.isPending ? "Pending" : "Status unknown")
        }
        switch check.conclusion?.lowercased() {
        case "success": return "Passed"
        case "failure": return "Failed"
        case "cancelled": return "Cancelled"
        case "skipped", "neutral": return "Skipped"
        case "timed_out": return "Timed out"
        case "action_required": return "Action required"
        default: return "Status unknown"
        }
    }

    @ViewBuilder
    private func authorAvatar(_ pr: PullRequestRecord) -> some View {
        if let url = pr.authorAvatarURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { avatarFallback }
            }
            .frame(width: 26, height: 26)
            .clipShape(Circle())
        } else {
            avatarFallback
        }
    }
    private var avatarFallback: some View {
        DockIcon(.user, size: 15, color: Color.dockMetadataText)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.dockSurface2))
    }
    @ViewBuilder
    private func statusPicker(_ pr: PullRequestRecord) -> some View {
        let current: PullRequestStatus = pr.state == "closed" ? .closed : (pr.isDraft ? .draft : .readyForReview)
        if pr.availableStatusActions.isEmpty || pr.viewerCanUpdate != true {
            Label {
                Text(pr.mergedAt != nil ? "Merged" : current.rawValue)
            } icon: {
                DockIcon(pr.presentationIcon, size: 12, color: pr.presentationColor)
            }
            .dockFont(.body).dockPill(tint: pr.presentationColor)
        } else {
            DockMenu {
                ForEach(pr.availableStatusActions) { status in
                    Button(status.rawValue) { mutationCoordinator.requestStatus(status, for: pr) }
                }
            } label: {
                HStack(spacing: 7) {
                    if center.updatingStatusID == pr.id { ProgressView().controlSize(.mini) }
                    if center.updatingStatusID != pr.id {
                        DockIcon(pr.presentationIcon, size: 12, color: pr.presentationColor)
                    }
                    Text(center.updatingStatusID == pr.id ? "Updating status…" : current.rawValue)
                    DockIcon(.caretDown, size: 12, color: Color.dockSecondaryText)
                }
                .dockPadding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    DockThemeShape(cornerRadius: DockLayout.controlRadius - 1).dockSurfaceFill(
                        pr.presentationColor.opacity(0.12)))
            }
            .disabled(center.isUpdatingStatus)
            .help("Change pull request status")
            .accessibilityLabel("Pull request status: \(current.rawValue)")
        }
    }
    private func pullRequestAge(_ updatedAt: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(updatedAt))
        if seconds >= 86_400 { return "\(Int(seconds / 86_400))d" }
        if seconds >= 3_600 { return "\(Int(seconds / 3_600))h" }
        return "\(max(1, Int(seconds / 60)))m"
    }
    private func detailTabs(_ pr: PullRequestRecord, compact: Bool = false) -> some View {
        HStack(spacing: 4) {
            detailTabButton("Summary", selected: detailTab == 0) { detailTab = 0 }
            Button {
                detailTab = 1
            } label: {
                HStack(spacing: 6) {
                    Text("Changes")
                    if !compact {
                        if let additions = pr.additions { Text("+\(additions)").foregroundStyle(Color.dockSuccess) }
                        if let deletions = pr.deletions { Text("−\(deletions)").foregroundStyle(Color.dockDestructive) }
                    }
                }.dockFont(.metadata).monospacedDigit()
                    .dockPadding(.horizontal, 10).frame(height: 28)
                    .background(Capsule().fill(detailTab == 1 ? Color.dockSurface4 : Color.clear))
                    .contentShape(Capsule())
            }.buttonStyle(.dockHover).accessibilityAddTraits(detailTab == 1 ? .isSelected : [])
            detailTabButton("Reviews", selected: detailTab == 2) { detailTab = 2 }
        }.dockPadding(4)
            .background(Capsule().fill(Color.dockSurface))
            .overlay(Capsule().stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline))
            .fixedSize(horizontal: true, vertical: false)
    }

    private func detailActions(_ pr: PullRequestRecord, compact: Bool = false, wraps: Bool = false) -> some View {
        let layout = wraps ? AnyLayout(DockChipFlow(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            DockIconButton(
                icon: watches.contains(pr) ? .pushPinSlash : .pushPin,
                label: watches.contains(pr) ? "Stop watching pull request" : "Watch pull request", size: 28,
                style: DockThemePalette(theme: DockThemeRuntime.current)
            ) { watches.toggle(pr) }
            if let url = pr.webURL {
                GitHubLinkButton(destination: url, accessibilityLabel: "Open pull request on GitHub")
            }
            DockIconButton(
                icon: .arrowsClockwise, label: "Refresh pull request details",
                isBusy: center.isLoadingDetail(for: pr.id), style: DockThemePalette(theme: DockThemeRuntime.current)
            ) {
                center.invalidateSelectedDetail()
                detailRefreshID += 1
            }
            GitHubAuthoringMenu(
                reference: pr.reference, client: center.api.client, isAdditionalActionPending: guide.requesting,
                additionalActions: {
                    if contextRouter?.model != nil {
                        Button(
                            guide.requesting
                                ? "Generating review guide…"
                                : (hasCurrentGuide(pr) ? "Read review guide" : "Generate review guide")
                        ) {
                            openReviewGuide(pr)
                        }
                        .disabled(
                            guide.requesting
                                || (!hasCurrentGuide(pr)
                                    && (guide.uncertain || !center.filesAreCurrent(for: pr)
                                        || !(center.filesByID[pr.id] ?? []).contains { $0.patch?.isEmpty == false }))
                        )
                        .help(ReviewGuideCoordinator.skillTooltip)
                        Divider()
                    }
                }
            ) {
                Task { await center.refreshSelectedDetail() }
            }.id(pr.id)
            if isInspector, let contextRouter, contextRouter.model != nil {
                if compact {
                    DockIconButton(
                        icon: .chatCircleText, label: "Attach to chat", size: 28,
                        style: DockThemePalette(theme: DockThemeRuntime.current)
                    ) { contextRouter.attachToCurrentChat(ChatContext(pullRequest: pr)) }
                } else {
                    Button("Attach to chat", icon: .chatCircleText) {
                        contextRouter.attachToCurrentChat(ChatContext(pullRequest: pr))
                    }.buttonStyle(.dockSecondary)
                }
            } else if !isInspector {
                AttachToChatMenu(icon: true) { ChatContext(pullRequest: pr) }
            }
            if pr.isOpenForWork || pr.mergedAt != nil {
                PullRequestLandingView(
                    record: pr, client: center.api.client, toolbar: true,
                    onLanded: { center.applyLandingSnapshot($0, for: pr) }
                ) {
                    Task { await center.refreshSelectedDetail() }
                }
                .id(pr.id)
            }
        }.controlSize(.small)
            .fixedSize(horizontal: !wraps, vertical: false)
    }

    private func hasCurrentGuide(_ pr: PullRequestRecord) -> Bool {
        guide.session != nil
            && guide.sourceIdentity == (pr.headRevision ?? "unknown") + ":" + (pr.baseRevision ?? "unknown")
    }

    private func openReviewGuide(_ pr: PullRequestRecord) {
        if !hasCurrentGuide(pr), let model = contextRouter?.model {
            guide.start(
                model: model, reviewerProfileID: "default", directory: pr.localPath.isEmpty ? nil : pr.localPath,
                identity: (pr.headRevision ?? "unknown") + ":" + (pr.baseRevision ?? "unknown"),
                documents: (center.filesByID[pr.id] ?? []).compactMap { file in
                    file.patch.map { DiffDocument(path: file.path, patch: $0) }
                },
                partial: (center.filesByID[pr.id] ?? []).contains { $0.patch == nil })
        }
        readingGuide = true
    }

    private func detailTabButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        DockTabButton(title: title, isSelected: selected, action: action)
    }
    private func code(_ pr: PullRequestRecord) -> some View {
        let projection = PullRequestFilesProjection.state(
            files: center.filesByID[pr.id],
            isLoading: center.isLoadingDetail(for: pr.id),
            expectedFileCount: pr.changedFiles
        )
        return VStack(alignment: .leading, spacing: 10) {
            switch projection {
            case .loading:
                ProgressView("Loading changed files…").foregroundStyle(Color.dockMetadataText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            case .unavailable:
                codeState(
                    title: "Changed files unavailable",
                    detail: "GitHub did not return the expected file data.",
                    actionTitle: "Retry"
                )
            case .empty:
                codeState(
                    title: "No changed files",
                    detail: "GitHub reports that this pull request currently has no changed files.",
                    actionTitle: "Refresh"
                )
            case .loaded(let files):
                HStack(alignment: .top, spacing: 14) {
                    if reviewPreferences.showsFileTree { fileTree(files) }
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(files) { file in
                                    fileSection(file)
                                        .id(file.id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: selectedFileID, initial: true) { _, id in
                            if let id { withAnimation(.dockEase(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) } }
                        }
                        .onChange(of: inlineTarget?.id, initial: true) { _, id in
                            guard let id, let target = inlineTarget,
                                let file = files.first(where: { $0.path == target.path })
                            else { return }
                            proxy.scrollTo(file.id, anchor: .top)
                            Task { @MainActor in
                                await Task.yield()
                                guard inlineTarget?.id == id else { return }
                                withAnimation(.dockEase(duration: 0.2)) {
                                    proxy.scrollTo("inline-review:" + target.path, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
        .dockPadding(.top, 14)
        .dockPadding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func codeState(title: String, detail: String, actionTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
            Text(detail)
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
            Button(actionTitle) {
                center.invalidateSelectedDetail()
                detailRefreshID += 1
            }
            .buttonStyle(.dockSecondary)
            .controlSize(.small)
            .disabled(center.isLoadingDetail(for: center.selectedID ?? ""))
            .dockPadding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
    }

    /// The inspector's code review, full window: the same pull request on its Code tab.
    private func expandedReview(close: @escaping () -> Void) -> some View {
        DockExpandedPage(
            title: "Code review", subtitle: center.selected.map { "#\($0.number) · \($0.title)" } ?? "", close: close
        ) {
            PullRequestDetailView(center: center, onOpenChat: onOpenChat, isInspector: isInspector, initialTab: 1)
        }
    }

    /// One private note store per PR; the header button and every file diff share it.
    private func revisionNotes(_ pr: PullRequestRecord) -> RevisionNoteStore {
        ReviewDraftStore.shared.notes(
            key: (contextRouter?.model.map { WorkspaceIdentity.session($0) } ?? "global") + ":pr:" + pr.id)
    }

    private func codeToolbar(fileIDs: Set<String>) -> some View {
        HStack(spacing: 4) {
            if let pr = center.selected {
                RevisionNotesButton(store: revisionNotes(pr), canSend: contextRouter?.model != nil) {
                    guard let contextRouter else { return }
                    let store = revisionNotes(pr)
                    contextRouter.attach(
                        store.chatContext(
                            repository: pr.repository.id, projectPath: pr.localPath.isEmpty ? nil : pr.localPath),
                        to: contextRouter.model?.workflowSession)
                    store.notes = []
                }
                DockMenu {
                    DockMenuSection("Pull request") {
                        Button(watches.contains(pr) ? "Stop watching" : "Watch pull request") { watches.toggle(pr) }
                    }
                    Divider()
                    DockMenuSection("Review guide") {
                        ReviewGuideGenerateAction(requesting: guide.requesting, menuRow: true) { reviewerProfileID in
                            guard let model = contextRouter?.model else { return }
                            guide.start(
                                model: model, reviewerProfileID: reviewerProfileID,
                                directory: pr.localPath.isEmpty ? nil : pr.localPath,
                                identity: (pr.headRevision ?? "unknown") + ":" + (pr.baseRevision ?? "unknown"),
                                documents: (center.filesByID[pr.id] ?? []).compactMap { file in
                                    file.patch.map { DiffDocument(path: file.path, patch: $0) }
                                },
                                partial: (center.filesByID[pr.id] ?? []).contains { $0.patch == nil })
                            readingGuide = true
                        }.disabled(
                            guide.requesting || guide.uncertain || !center.filesAreCurrent(for: pr)
                                || contextRouter?.model == nil)
                        if guide.session != nil || guide.requesting { Button("Read guide") { readingGuide = true } }
                        if let session = guide.session {
                            Button("Open review conversation") {
                                contextRouter?.model?.resumeSession(session)
                                contextRouter?.onOpened(session.id)
                            }
                        }
                        if guide.requesting {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Starting review…").dockFont(.body)
                            }.foregroundStyle(Color.dockSecondaryText).dockPadding(8)
                        }
                    }
                    if watches.error != nil { Text("Watch unavailable. Try again.").dockFont(.body).dockPadding(8) }
                } label: {
                    PullRequestReviewToolbarIcon(
                        name: .dotsThree, accessibilityLabel: "Review actions", tooltip: "Review actions")
                }
                .fixedSize()
                .help("Review actions")
            }
            DockMenu {
                Toggle("Enable word wrap", isOn: $reviewPreferences.wordWrap)
                Toggle("Enable rich preview", isOn: $reviewPreferences.richPreview)
                Toggle("Enable word diffs", isOn: $reviewPreferences.wordDiffs)
            } label: {
                PullRequestReviewToolbarIcon(
                    name: .sliders, accessibilityLabel: "Review options", tooltip: "Review options")
            }
            // `.borderlessButton` drops custom-shape labels on macOS, leaving only the indicator.
            .buttonStyle(.dockHover)
            .fixedSize()
            .help("Review options")

            Button {
                reviewPreferences.setAllExpanded(fileIDs)
            } label: {
                PullRequestReviewToolbarIcon(
                    name: reviewPreferences.expandedFileIDs.isSuperset(of: fileIDs)
                        ? .arrowsInLineVertical : .caretUpDown,
                    accessibilityLabel: reviewPreferences.expandedFileIDs.isSuperset(of: fileIDs)
                        ? "Collapse all diffs" : "Expand all diffs",
                    tooltip: reviewPreferences.expandedFileIDs.isSuperset(of: fileIDs)
                        ? "Collapse all diffs" : "Expand all diffs"
                )
            }
            .buttonStyle(.dockHover)
            .help(reviewPreferences.expandedFileIDs.isSuperset(of: fileIDs) ? "Collapse all diffs" : "Expand all diffs")

            Button {
                reviewPreferences.diffMode = reviewPreferences.diffMode == .unified ? .split : .unified
            } label: {
                PullRequestReviewToolbarIcon(
                    name: reviewPreferences.diffMode == .unified ? .columns : .rows,
                    accessibilityLabel:
                        "Switch to \(reviewPreferences.diffMode == .unified ? "split" : "unified") diff",
                    tooltip: "Switch to \(reviewPreferences.diffMode == .unified ? "split" : "unified") diff"
                )
            }
            .buttonStyle(.dockHover)
            .help("Switch to \(reviewPreferences.diffMode == .unified ? "split" : "unified") diff")

            if isInspector {
                Button {
                    if reviewRouter?.present(expandedReview { reviewRouter?.close() }) != true { expandedSheet = true }
                } label: {
                    PullRequestReviewToolbarIcon(
                        name: .arrowsOutSimple, accessibilityLabel: "Expand review", tooltip: "Expand review")
                }
                .buttonStyle(.dockHover)
                .help("Expand review")
            }

            DockSidebarToggle(isCollapsed: !reviewPreferences.showsFileTree, edge: .leading, panel: "file tree") {
                reviewPreferences.showsFileTree.toggle()
            }
        }
        .frame(height: 34)
    }

    private func fileTree(_ files: [PullRequestFile]) -> some View {
        let filesByID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Changed files")
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                Text("\(files.count)")
                    .dockFont(.metadata, weight: .regular)
                    .foregroundStyle(Color.dockMetadataText)
                    .dockPadding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Capsule().fill(Color.dockSurface4))
                Spacer(minLength: 4)
                PullRequestDiffStat(
                    additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions })
            }
            .dockPadding(.horizontal, 12)
            .frame(height: 36)

            TextField("Find changed file", text: $fileQuery).textFieldStyle(.dockGlass).dockPadding(8)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(
                        PullRequestFileTreeBuilder.make(
                            files: files.filter {
                                fileQuery.isEmpty || $0.path.localizedCaseInsensitiveContains(fileQuery)
                            })
                    ) { node in
                        PullRequestFileTreeRow(
                            node: node,
                            file: node.fileID.flatMap { filesByID[$0] },
                            // Folders have no fileID; comparing optionals would highlight them all when nothing is selected.
                            isSelected: node.fileID != nil && selectedFileID == node.fileID
                        ) {
                            guard let fileID = node.fileID else { return }
                            selectedFileID = fileID
                            if !reviewPreferences.expandedFileIDs.contains(fileID) {
                                reviewPreferences.toggleExpanded(fileID)
                            }
                        }
                    }
                }
                .dockPadding(.horizontal, 6)
                .dockPadding(.bottom, 8)
            }
        }
        .frame(width: 240, alignment: .leading)
        .overlay(alignment: .trailing) { Color.dockBorderLight.frame(width: 0.5) }
    }

    private func fileSection(_ file: PullRequestFile) -> some View {
        let expanded = reviewPreferences.expandedFileIDs.contains(file.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                selectedFileID = file.id
                reviewPreferences.toggleExpanded(file.id)
            } label: {
                HStack(spacing: 8) {
                    DockIcon(expanded ? .caretDown : .caretRight, size: 13, color: Color.dockMetadataText)
                    PullRequestFileIcon(path: file.path, size: 15)
                    Text(file.path).dockFont(.body, weight: .semibold, design: .monospaced).lineLimit(1)
                    Text(file.status.uppercased())
                        .dockFont(.metadata, weight: .bold, design: .monospaced)
                        .foregroundStyle(Color.dockMetadataText)
                    Spacer()
                    HStack(spacing: 8) {
                        Text("+\(file.additions)").foregroundStyle(Color.dockSuccess)
                        Text("−\(file.deletions)").foregroundStyle(Color.dockDestructive)
                    }.dockFont(.metadata, weight: .regular, design: .monospaced)
                }
                .foregroundStyle(Color.dockPrimaryText)
                .dockPadding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            if expanded {
                fileContent(file)
                if let pr = center.selected {
                    PullRequestThreadListView(model: center.review(for: pr), record: pr, path: file.path).dockPadding(8)
                }
            }
        }
        .background(Color.dockCanvas)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).stroke(
                Color.dockBorderLight, lineWidth: 0.5))
    }

    @ViewBuilder
    private func fileContent(_ file: PullRequestFile) -> some View {
        if reviewPreferences.richPreview, !sourceDiffFileIDs.contains(file.id), let patch = file.patch,
            isMarkdown(file.path)
        {
            VStack(alignment: .leading, spacing: 6) {
                Text("CHANGED LINES PREVIEW · OMITTED CONTENT IS NOT SHOWN").dockFont(
                    size: 9, weight: .bold, design: .monospaced
                ).foregroundStyle(Color.dockMetadataText)
                MarkdownMessageView(markdown: previewMarkdown(from: patch)).dockPadding(12).frame(
                    maxWidth: .infinity, alignment: .leading
                ).background(Color.dockSurface2)
                Button("Show source diff") { sourceDiffFileIDs.insert(file.id) }.buttonStyle(.dockCompact).dockFont(
                    .compactStatus, weight: .semibold)
            }.dockPadding(8)
        } else if reviewPreferences.richPreview, !sourceDiffFileIDs.contains(file.id), isImage(file.path),
            let url = file.webURL
        {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: imagePreviewURL(for: url)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().frame(maxHeight: 420)
                    } else {
                        Text("Image preview unavailable. Open on GitHub to view this file.").foregroundStyle(
                            Color.dockMetadataText)
                    }
                }
                Button("Show source diff") { sourceDiffFileIDs.insert(file.id) }.buttonStyle(.dockCompact).dockFont(
                    .compactStatus, weight: .semibold)
            }.dockPadding(8)
        } else if let patch = file.patch {
            diffPatch(patch, file: file)
        } else {
            HStack {
                Text("Binary or truncated patch").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                Spacer()
                if let url = file.webURL { Link("Open on GitHub", destination: url).buttonStyle(.dockLink) }
            }.dockPadding(12)
        }
    }

    private func isMarkdown(_ path: String) -> Bool {
        ["md", "markdown", "mdown"].contains((path as NSString).pathExtension.lowercased())
    }
    private func isImage(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains((path as NSString).pathExtension.lowercased())
    }
    private func imagePreviewURL(for url: URL) -> URL {
        guard url.host?.lowercased() == "github.com" else { return url }
        let components = url.path.split(separator: "/").map(String.init)
        guard components.count > 4, components[2] == "blob" else { return url }
        let rawPath = Array(components[0...1]) + Array(components.dropFirst(3))
        return URL(string: "https://raw.githubusercontent.com/\(rawPath.joined(separator: "/"))") ?? url
    }
    private func previewMarkdown(from patch: String) -> String {
        PullRequestDiffPresentation.lines(patch).filter {
            $0.kind != .deletion && $0.kind != .hunk && $0.kind != .metadata
        }.map { $0.kind == .addition ? String($0.text.dropFirst()) : $0.text }.joined(separator: "\n")
    }

    @ViewBuilder
    private func diffPatch(_ patch: String, file: PullRequestFile) -> some View {
        let capturedRecord = center.selected
        SharedDiffView(
            patch: patch, path: file.path, preferredSplit: reviewPreferences.diffMode == .split,
            wraps: reviewPreferences.wordWrap, wordDiffs: reviewPreferences.wordDiffs,
            onComment: (capturedRecord.map {
                $0.state == "open" && $0.headRevision != nil && center.filesAreCurrent(for: $0)
            } ?? false)
                ? { line in
                    if let pr = capturedRecord, center.selected?.id == pr.id,
                        center.selected?.headRevision == pr.headRevision, center.filesAreCurrent(for: pr),
                        let revision = pr.headRevision, pr.state == "open", let number = line.newLine ?? line.oldLine
                    {
                        let target = GitHubInlineCommentTarget(
                            path: file.path, line: number,
                            side: line.newLine == nil ? "LEFT" : "RIGHT", revision: revision)
                        if center.review(for: pr).beginInline(target, record: pr) { inlineTarget = target }
                    }
                } : nil,
            contextLoader: { lines in
                guard let pr = center.selected, center.filesAreCurrent(for: pr) else {
                    throw GitHubRequestError.changed
                }
                let service = PullRequestContextService(client: center.review(for: pr).service.client)
                let value = try await service.expand(record: pr, file: file, patch: patch, lines: lines)
                guard center.selected?.id == pr.id, center.filesAreCurrent(for: pr),
                    center.selected?.headRevision == pr.headRevision
                else { throw GitHubRequestError.changed }
                return value
            }, comparison: center.selected.map(DiffComparisonIdentity.pullRequest),
            revisionNotes: center.selected.map(revisionNotes),
            reviewAccessory: capturedRecord.map { pr in
                AnyView(
                    PullRequestInlineReview(
                        model: center.review(for: pr), record: pr,
                        document: DiffDocument(path: file.path, patch: patch), target: $inlineTarget))
            }
        )
        .environment(\.revisionNotesInHeader, true)
        .id(
            (contextRouter?.model.map { WorkspaceIdentity.session($0) } ?? "global") + ":" + (center.selected?.id ?? "")
                + ":" + file.path)
    }

}
