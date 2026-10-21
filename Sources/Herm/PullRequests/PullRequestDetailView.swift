import Foundation
import SwiftUI

struct PullRequestDetailView: View {
    @ObservedObject var center: PullRequestCenterModel
    let onOpenChat: (PullRequestRecord) -> Void

    @State private var readingGuide = false
    @StateObject private var guide = ReviewGuideCoordinator()
    @ObservedObject private var watches = PullRequestWatchStore.shared
    @Environment(\.chatContextRouter) private var contextRouter
    @State private var detailRefreshID = 0
    @State private var detailTab = 0
    @State private var inlineTarget: GitHubInlineCommentTarget?
    @StateObject private var reviewPreferences = PullRequestReviewPreferenceStore()
    @State private var selectedFileID: String?
    @State private var fileQuery = ""
    @State private var sourceDiffFileIDs: Set<String> = []
    @State private var descriptionExpanded = true
    @State private var checksExpanded = true
    @State private var activityExpanded = true
    private var commentDraft: String { center.commentDrafts[center.selectedID ?? ""] ?? "" }
    @StateObject private var diffPresentationCache = PullRequestDiffPresentationCache()
    @StateObject private var mutationCoordinator = PullRequestMutationCoordinator()
    @Environment(\.dockTitleRow) private var titleRow

    var body: some View {
        detailPane
            .sheet(isPresented: $readingGuide) {
                if let model = contextRouter?.model, let pr = center.selected {
                    ReviewGuideView(coordinator: guide, model: model,
                        currentIdentity: (pr.headRevision ?? "unknown") + ":" + (pr.baseRevision ?? "unknown"), directory: pr.localPath.isEmpty ? nil : pr.localPath).modifier(ReviewSheetContext())
                }
            }
            .task(id: "\(center.selectedID ?? ""):\(center.isRefreshing):\(detailRefreshID)") {
                guard center.selectedID != nil, !center.isRefreshing else { return }
                await center.loadSelectedDetail()
            }
            .sheet(item: $inlineTarget) { target in
                if let record = center.selected { GitHubInlineCommentEditor(model: center.review(for: record), record: record, target: target) }
            }
            .onChange(of: center.selectedID) { _, _ in
                inlineTarget = nil
                selectedFileID = nil
                sourceDiffFileIDs.removeAll()
                diffPresentationCache.removeAll()
                descriptionExpanded = true
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
                case let .status(_, status):
                    Button(status == .closed ? "Close pull request" : status.rawValue, role: status == .closed ? .destructive : nil) {
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
        case let .comment(record, body):
            return Text("Post this comment to \(record.repository.id) pull request #\(record.number)?\n\n\(body)")
        case let .status(record, status):
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
        } else if let pr = center.selected { VStack(alignment: .leading, spacing: 0) {
        // Header stays above the scroller so scrolled content never draws over or steals clicks from it.
        detailHeader(pr).zIndex(1)
        if detailTab == 0 {
            ScrollView { summary(pr).padding(.horizontal, 24) }.clipped()
        } else if detailTab == 2 {
            PullRequestReviewView(model: center.review(for: pr), record: pr, viewer: center.viewerLogin) { Task { await center.refreshSelectedDetail() } }
        } else {
            code(pr).padding(.horizontal, 16)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else if center.isInitialLoad {
        detailLoadingPane
    } else { VStack(spacing: 12) { DockIcon(.gitPullRequest, size: 28, color: Color.dockMetadataText); Text(center.isRefreshing ? "Loading pull requests…" : "Select a pull request").font(.system(size: 15, weight: .medium)) }.foregroundStyle(Color.dockMetadataText).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private var detailLoadingPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RepositoryShimmerBlock(width: 72, height: 22, cornerRadius: 7)
                RepositoryShimmerBlock(width: 48, height: 22, cornerRadius: 7)
                Spacer()
                RepositoryShimmerBlock(width: 88, height: 28, cornerRadius: 7)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading pull request")
                            .font(.system(size: 12, weight: .medium))
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
                            RepositoryShimmerBlock(width: index.isMultiple(of: 2) ? 236 : 176, height: 11, cornerRadius: 4)
                        }
                    }
                    RepositoryShimmerBlock(width: nil, height: 1, cornerRadius: 0)
                    RepositoryShimmerBlock(width: 112, height: 15, cornerRadius: 5)
                    RepositoryShimmerBlock(width: nil, height: 82, cornerRadius: 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading pull request")
    }

    private func detailHeader(_ pr: PullRequestRecord) -> some View {
        let fileIDs = Set((center.filesByID[pr.id] ?? []).map(\.id))
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                detailTabButton("Summary", selected: detailTab == 0) { detailTab = 0 }
                detailTabButton("Code", selected: detailTab == 1) { detailTab = 1 }
                detailTabButton("Reviews", selected: detailTab == 2) { detailTab = 2 }
                Spacer()
                    .frame(maxHeight: .infinity)
                    .background { if titleRow != nil { TitlebarDoubleClickArea() } }
                HStack(spacing: 6) {
                    if let url = pr.webURL {
                        GitHubLinkButton(
                            destination: url,
                            accessibilityLabel: "Open pull request on GitHub"
                        )
                        Divider().frame(height: 16)
                    }
                    DockIconButton(icon: .arrowsClockwise, label: "Refresh pull request details", isBusy: center.isLoadingDetail(for: pr.id), style: DockThemePalette(theme: DockThemeRuntime.current)) {
                    center.invalidateSelectedDetail(); detailRefreshID += 1
                }
                GitHubAuthoringMenu(reference: pr.reference, client: center.api.client) { Task { await center.refreshSelectedDetail() } }.id(pr.id)
                DockMenu {
                    Button(PullRequestChatLinkStore().sessionID(for: pr.id) == nil ? "Prepare review in Hermes" : "Open linked Hermes chat") { onOpenChat(pr) }
                } label: { DockIcon(.chatCircleText, size: 14, color: Color.dockSecondaryText).frame(width: 28, height: 28)
                    .background(DockThemeShape(cornerRadius: DockLayout.controlRadius - 1).dockSurfaceFill(Color.dockControlSurface.opacity(0.6))) }
                AttachToChatMenu(pill: true) { ChatContext(pullRequest: pr) }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(titleRow != nil ? Color.dockSidebar : .clear)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            if detailTab == 1 {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pr.headBranch).lineLimit(1)
                        if !center.filesAreCurrent(for: pr) {
                            Text("Diff may be outdated · refresh to review")
                                .font(DockTypography.metadata).foregroundStyle(Color.dockWarning)
                                .lineLimit(1)
                        }
                    }
                    DockIcon(.arrowRight, size: 14, color: Color.dockMetadataText)
                    Text(pr.baseBranch)
                        .lineLimit(1)
                    Spacer(minLength: 16)
                    codeToolbar(fileIDs: fileIDs)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.dockMetadataText)
                .padding(.horizontal, 16)
                .frame(height: 62)
                .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
            }
        }
        .background(Color.dockCanvas)
    }
    private func summary(_ pr: PullRequestRecord) -> some View {
        let activity = activityItems(pr)
        return LazyVStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(pr.repository.id).lineLimit(1).truncationMode(.middle)
                    Text("#\(pr.displayNumber)").foregroundStyle(Color.dockInfo)
                    Spacer(minLength: 0)
                    statusPicker(pr).foregroundStyle(pr.presentationColor)
                }.font(DockTypography.body).foregroundStyle(Color.dockSecondaryText)
                Text(pr.title)
                    .font(DockTypography.pageTitle)
                    .foregroundStyle(Color.dockPrimaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    authorAvatar(pr)
                    Text(pr.author).foregroundStyle(Color.dockPrimaryText)
                    if let updatedAt = pr.updatedAt { Text("· Updated \(pullRequestAge(updatedAt)) ago") }
                }.font(DockTypography.body).foregroundStyle(Color.dockMetadataText)
                Color.dockBorderLight.frame(height: DockLayout.hairline)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { branchRoute(pr); Spacer(minLength: 8); changeTotals(pr) }
                    VStack(alignment: .leading, spacing: 10) { branchRoute(pr); changeTotals(pr) }
                }
                summaryDetailRow(icon: .users, title: "Reviewers", color: .dockInfo) {
                    Text(pr.requestedReviewers.isEmpty ? "No reviewers requested" : pr.requestedReviewers.joined(separator: ", "))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.font(DockTypography.body).foregroundStyle(Color.dockSecondaryText).dockCard(padding: 16)

            VStack(alignment: .leading, spacing: 8) {
                DockSectionHeader(title: "Description", isExpanded: $descriptionExpanded, style: DockThemePalette(theme: DockThemeRuntime.current))
                if descriptionExpanded {
                    if pr.body.isEmpty { Text("No description provided.").foregroundStyle(Color.dockMetadataText) }
                    else { MarkdownMessageView(markdown: pr.body).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.font(DockTypography.body).dockCard(padding: 12)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                PullRequestReadinessView(center: center, record: pr)
                changeBreakdown(pr)
            }
            if pr.isOpenForWork || pr.mergedAt != nil {
                PullRequestLandingView(record: pr, client: center.api.client, onLanded: { center.applyLandingSnapshot($0, for: pr) }) { Task { await center.refreshSelectedDetail() } }.id(pr.id)
            }
            GitHubMetadataView(reference: pr.reference, client: center.api.client) { Task { await center.refreshSelectedDetail() } }.id(pr.id)

            VStack(alignment: .leading, spacing: 8) {
                DockSectionHeader(title: "Checks", count: pr.checks.isEmpty ? nil : pr.checks.count, isExpanded: $checksExpanded, style: DockThemePalette(theme: DockThemeRuntime.current))
                if checksExpanded { checksSection(pr) }
            }.dockCard(padding: 12)
            VStack(alignment: .leading, spacing: 8) {
                DockSectionHeader(title: "Activity", count: activity.count, isExpanded: $activityExpanded, style: DockThemePalette(theme: DockThemeRuntime.current))
                if activityExpanded { GitHubTimelineView(reference: pr.reference, items: activity, grouped: true) }
            }.dockCard(padding: 12)
            commentComposer(pr)
        }
        .padding(.top, 20).padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func branchRoute(_ pr: PullRequestRecord) -> some View {
        HStack(spacing: 8) {
            DockIcon(.gitBranch, size: 14, color: .dockInfo)
            Text(pr.baseBranch).foregroundStyle(Color.dockInfo)
            DockIcon(.arrowLeft, size: 13, color: .dockMetadataText)
            Text(pr.headBranch).foregroundStyle(Color.dockSecondaryText)
        }.font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            .help("Merge \(pr.headBranch) into \(pr.baseBranch)")
    }

    private func changeTotals(_ pr: PullRequestRecord) -> some View {
        HStack(spacing: 8) {
            Button { detailTab = 1 } label: {
                Text(pr.changedFiles.map { "\($0) files" } ?? "Changed files")
            }.buttonStyle(.dockLink)
            if let additions = pr.additions { Text("+\(additions)").foregroundStyle(Color.dockSuccess) }
            if let deletions = pr.deletions { Text("−\(deletions)").foregroundStyle(Color.dockDestructive) }
        }.font(DockTypography.body).monospacedDigit().fixedSize()
    }

    private func changeBreakdown(_ pr: PullRequestRecord) -> some View {
        PullRequestChangeBreakdownView(
            files: center.filesByID[pr.id], expectedCount: pr.changedFiles,
            isCurrent: center.filesAreCurrent(for: pr), isLoading: center.isLoadingDetail(for: pr.id)
        ) { detailTab = 1 }
    }

    @ViewBuilder
    private func checksSection(_ pr: PullRequestRecord) -> some View {
        if pr.checks.isEmpty {
            HStack(spacing: 12) {
            Text(pr.checksAvailable ? "No checks reported by GitHub." : "Check status unavailable. Refresh to retry.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dockMetadataText)
                Spacer()
                DockIconButton(icon: .arrowsClockwise, label: "Refresh checks", isBusy: center.isLoadingDetail, size: 24, style: DockThemePalette(theme: DockThemeRuntime.current)) {
                    center.invalidateSelectedDetail()
                    detailRefreshID += 1
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(minHeight: 44)
        } else {
            VStack(spacing: 0) {
                ForEach(pr.checks) { check in
                    HStack(spacing: 13) {
                        DockIcon(checkIcon(for: check), size: 14, color: checkColor(for: check))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(checkColor(for: check).opacity(0.12)))
                        if let url = check.detailsURL { Link(check.name, destination: url).buttonStyle(.dockLink) } else { Text(check.name) }
                        Spacer()
                        Text(checkPresentation(for: check))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 42)
                    if check.id != pr.checks.last?.id { Divider().padding(.leading, 47) }
                }
            }
        }
    }

    private func activityItems(_ pr: PullRequestRecord) -> [GitHubConversationItem] {
        pr.activityItems(comments: center.commentsByID[pr.id] ?? [], commits: center.commitsByID[pr.id] ?? [], events: center.eventsByID[pr.id] ?? [])
    }

    private func commentComposer(_ pr: PullRequestRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Leave a comment").font(.system(size: 12, weight: .semibold))
            TextEditor(text: center.commentDraft(for: pr.id))
                .font(DockTypography.body).scrollContentBackground(.hidden)
                .padding(8).frame(minHeight: 104)
                .background(DockThemeShape(cornerRadius: DockLayout.controlRadius).dockInputFill())
                .accessibilityLabel("Comment body")
            HStack {
                Text("\(commentDraft.count)/10000").font(DockTypography.metadata).foregroundStyle(Color.dockMetadataText)
                Spacer()
                Button { mutationCoordinator.requestComment(commentDraft, for: pr) } label: {
                    GitHubActionLabel(title: center.isPostingComment ? "Posting…" : "Post comment", isBusy: center.isPostingComment)
                }.buttonStyle(.dockPrimary)
                    .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || commentDraft.count > 10_000 || center.isPostingComment)
            }
        }.dockCard(padding: 12)
    }

    private func checkIcon(for check: GitHubCheckSummary) -> Ph { checkColor(for: check) == Color.dockSuccess ? .check : (checkColor(for: check) == Color.dockDestructive ? .x : .clock) }
    private func checkColor(for check: GitHubCheckSummary) -> Color {
        let conclusion = check.conclusion?.lowercased()
        if ["neutral", "skipped"].contains(conclusion) { return Color.dockMetadataText }
        if conclusion == "success" { return Color.dockSuccess }
        if ["failure", "cancelled", "timed_out", "action_required"].contains(conclusion) { return Color.dockDestructive }
        return Color.dockWarning
    }
    private func checkPresentation(for check: GitHubCheckSummary) -> String {
        guard check.status.lowercased() == "completed" else {
            return check.status.lowercased() == "in_progress" ? "Running" : (check.isPending ? "Pending" : "Status unknown")
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
                if let image = phase.image { image.resizable().scaledToFill() }
                else { avatarFallback }
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
    private func summaryDetailRow<Content: View>(icon: Ph, title: String, color: Color = Color.dockMetadataText, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 13) {
            DockIcon(icon, size: 14, color: color).frame(width: 18)
            Text(title).foregroundStyle(Color.dockMetadataText).frame(width: 84, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder
    private func statusPicker(_ pr: PullRequestRecord) -> some View {
        let current: PullRequestStatus = pr.state == "closed" ? .closed : (pr.isDraft ? .draft : .readyForReview)
        if pr.availableStatusActions.isEmpty || pr.viewerCanUpdate != true {
            Text(pr.mergedAt != nil ? "Merged" : current.rawValue)
        } else {
            DockMenu {
                ForEach(pr.availableStatusActions) { status in
                    Button(status.rawValue) { mutationCoordinator.requestStatus(status, for: pr) }
                }
            } label: {
                HStack(spacing: 7) {
                    if center.updatingStatusID == pr.id { ProgressView().controlSize(.mini) }
                    Text(center.updatingStatusID == pr.id ? "Updating status…" : current.rawValue)
                    DockIcon(.caretDown, size: 12, color: Color.dockSecondaryText)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(DockThemeShape(cornerRadius: DockLayout.controlRadius - 1).dockSurfaceFill(Color.dockControlSurface.opacity(0.6)))
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
                        .onChange(of: selectedFileID) { _, id in
                            if let id { withAnimation(.dockEase(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) } }
                        }
                    }
                }
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func codeState(title: String, detail: String, actionTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Text(detail)
                .font(DockTypography.body)
                .foregroundStyle(Color.dockSecondaryText)
            Button(actionTitle) {
                center.invalidateSelectedDetail()
                detailRefreshID += 1
            }
            .buttonStyle(.dockSecondary)
            .controlSize(.small)
            .disabled(center.isLoadingDetail(for: center.selectedID ?? ""))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
    }

    private func codeToolbar(fileIDs: Set<String>) -> some View {
        HStack(spacing: 4) {
            if let pr = center.selected {
                DockMenu {
                    Button(watches.contains(pr) ? "Stop watching" : "Watch pull request") { watches.toggle(pr) }
                    Button("Generate review guide") {
                        guard let model = contextRouter?.model else { return }
                        guide.start(model: model, directory: pr.localPath.isEmpty ? nil : pr.localPath,
                            identity: (pr.headRevision ?? "unknown") + ":" + (pr.baseRevision ?? "unknown"),
                            documents: (center.filesByID[pr.id] ?? []).compactMap { file in file.patch.map { DiffDocument(path: file.path, patch: $0) } },
                            partial: (center.filesByID[pr.id] ?? []).contains { $0.patch == nil })
                    }.disabled(guide.requesting || guide.uncertain || !center.filesAreCurrent(for: pr) || contextRouter?.model == nil)
                    if guide.session != nil { Button("Read guide") { readingGuide = true } }
                    if let session = guide.session {
                        Button("Open review conversation") { contextRouter?.model?.resumeSession(session); contextRouter?.onOpened(session.id) }
                    }
                    if let message = guide.message { Text(message) }
                    if let error = watches.error { Text(error) }
                } label: {
                    PullRequestReviewToolbarIcon(name: .dotsThree, accessibilityLabel: "Review actions", tooltip: "Review actions")
                }
                .fixedSize()
                .help("Review actions")
            }
            DockMenu {
                Toggle("Enable word wrap", isOn: $reviewPreferences.wordWrap)
                Toggle("Enable rich preview", isOn: $reviewPreferences.richPreview)
                Toggle("Enable word diffs", isOn: $reviewPreferences.wordDiffs)
            } label: {
                PullRequestReviewToolbarIcon(name: .sliders, accessibilityLabel: "Review options", tooltip: "Review options")
            }
            // `.borderlessButton` drops custom-shape labels on macOS, leaving only the indicator.
            .buttonStyle(.dockHover)
            .fixedSize()
            .help("Review options")

            Button {
                reviewPreferences.setAllExpanded(fileIDs)
            } label: {
                PullRequestReviewToolbarIcon(
                    name: reviewPreferences.expandedFileIDs.isSuperset(of: fileIDs) ? .arrowsInLineVertical : .caretUpDown,
                    accessibilityLabel: reviewPreferences.expandedFileIDs.isSuperset(of: fileIDs) ? "Collapse all diffs" : "Expand all diffs",
                    tooltip: reviewPreferences.expandedFileIDs.isSuperset(of: fileIDs) ? "Collapse all diffs" : "Expand all diffs"
                )
            }
            .buttonStyle(.dockHover)
            .help(reviewPreferences.expandedFileIDs.isSuperset(of: fileIDs) ? "Collapse all diffs" : "Expand all diffs")

            Button {
                reviewPreferences.diffMode = reviewPreferences.diffMode == .unified ? .split : .unified
            } label: {
                PullRequestReviewToolbarIcon(
                    name: reviewPreferences.diffMode == .unified ? .columns : .rows,
                    accessibilityLabel: "Switch to \(reviewPreferences.diffMode == .unified ? "split" : "unified") diff",
                    tooltip: "Switch to \(reviewPreferences.diffMode == .unified ? "split" : "unified") diff"
                )
            }
            .buttonStyle(.dockHover)
            .help("Switch to \(reviewPreferences.diffMode == .unified ? "split" : "unified") diff")

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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Text("\(files.count)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.dockMetadataText)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Capsule().fill(Color.dockSurface4))
                Spacer(minLength: 4)
                PullRequestDiffStat(additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions })
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            TextField("Find changed file", text: $fileQuery).textFieldStyle(.dockGlass).padding(8)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(PullRequestFileTreeBuilder.make(files: files.filter { fileQuery.isEmpty || $0.path.localizedCaseInsensitiveContains(fileQuery) })) { node in
                        PullRequestFileTreeRow(
                            node: node,
                            file: node.fileID.flatMap { filesByID[$0] },
                            // Folders have no fileID; comparing optionals would highlight them all when nothing is selected.
                            isSelected: node.fileID != nil && selectedFileID == node.fileID
                        ) {
                            guard let fileID = node.fileID else { return }
                            selectedFileID = fileID
                            if !reviewPreferences.expandedFileIDs.contains(fileID) { reviewPreferences.toggleExpanded(fileID) }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
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
                    Text(file.path).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                    Text(file.status.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                    Spacer()
                    HStack(spacing: 8) {
                        Text("+\(file.additions)").foregroundStyle(Color.dockSuccess)
                        Text("−\(file.deletions)").foregroundStyle(Color.dockDestructive)
                    }.font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(Color.dockPrimaryText)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            if expanded {
                fileContent(file)
                if let pr = center.selected { PullRequestThreadListView(model: center.review(for: pr), record: pr, path: file.path).padding(8) }
            }
        }
        .background(Color.dockCanvas)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
    }

    @ViewBuilder
    private func fileContent(_ file: PullRequestFile) -> some View {
        if reviewPreferences.richPreview, !sourceDiffFileIDs.contains(file.id), let patch = file.patch, isMarkdown(file.path) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CHANGED LINES PREVIEW · OMITTED CONTENT IS NOT SHOWN").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Color.dockMetadataText)
                MarkdownMessageView(markdown: previewMarkdown(from: patch)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.dockSurface2)
                Button("Show source diff") { sourceDiffFileIDs.insert(file.id) }.buttonStyle(.dockCompact).font(.system(size: 10, weight: .semibold))
            }.padding(8)
        } else if reviewPreferences.richPreview, !sourceDiffFileIDs.contains(file.id), isImage(file.path), let url = file.webURL {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: imagePreviewURL(for: url)) { phase in
                    if let image = phase.image { image.resizable().scaledToFit().frame(maxHeight: 420) }
                    else { Text("Image preview unavailable. Open on GitHub to view this file.").foregroundStyle(Color.dockMetadataText) }
                }
                Button("Show source diff") { sourceDiffFileIDs.insert(file.id) }.buttonStyle(.dockCompact).font(.system(size: 10, weight: .semibold))
            }.padding(8)
        } else if let patch = file.patch {
            diffPatch(patch, file: file)
        } else {
            HStack { Text("Binary or truncated patch").font(.system(size: 11)).foregroundStyle(Color.dockMetadataText); Spacer(); if let url = file.webURL { Link("Open on GitHub", destination: url).buttonStyle(.dockLink) } }.padding(12)
        }
    }

    private func isMarkdown(_ path: String) -> Bool { ["md", "markdown", "mdown"].contains((path as NSString).pathExtension.lowercased()) }
    private func isImage(_ path: String) -> Bool { ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains((path as NSString).pathExtension.lowercased()) }
    private func imagePreviewURL(for url: URL) -> URL {
        guard url.host?.lowercased() == "github.com" else { return url }
        let components = url.path.split(separator: "/").map(String.init)
        guard components.count > 4, components[2] == "blob" else { return url }
        let rawPath = Array(components[0...1]) + Array(components.dropFirst(3))
        return URL(string: "https://raw.githubusercontent.com/\(rawPath.joined(separator: "/"))") ?? url
    }
    private func previewMarkdown(from patch: String) -> String { PullRequestDiffPresentation.lines(patch).filter { $0.kind != .deletion && $0.kind != .hunk && $0.kind != .metadata }.map { $0.kind == .addition ? String($0.text.dropFirst()) : $0.text }.joined(separator: "\n") }

    @ViewBuilder
    private func diffPatch(_ patch: String, file: PullRequestFile) -> some View {
        SharedDiffView(patch: patch, path: file.path, preferredSplit: reviewPreferences.diffMode == .split,
                       wraps: reviewPreferences.wordWrap, wordDiffs: reviewPreferences.wordDiffs,
                       onComment: (center.selected?.state == "open" && center.selected?.headRevision != nil) ? { line in
            if let pr = center.selected, center.filesAreCurrent(for: pr), let revision = pr.headRevision,
               pr.state == "open", let number = line.newLine ?? line.oldLine {
                inlineTarget = GitHubInlineCommentTarget(path: file.path, line: number,
                    side: line.newLine == nil ? "LEFT" : "RIGHT", revision: revision)
            }
        } : nil, contextLoader: { lines in
            guard let pr = center.selected, center.filesAreCurrent(for: pr) else { throw GitHubRequestError.changed }
            let service = PullRequestContextService(client: center.review(for: pr).service.client)
            let value = try await service.expand(record: pr, file: file, patch: patch, lines: lines)
            guard center.selected?.id == pr.id, center.filesAreCurrent(for: pr), center.selected?.headRevision == pr.headRevision else { throw GitHubRequestError.changed }
            return value
        }, comparison: center.selected.map(DiffComparisonIdentity.pullRequest), revisionNotes: center.selected.map { pr in ReviewDraftStore.shared.notes(key: (contextRouter?.model.map { WorkspaceIdentity.session($0) } ?? "global") + ":pr:" + pr.id) })
        .id((contextRouter?.model.map { WorkspaceIdentity.session($0) } ?? "global") + ":" + (center.selected?.id ?? "") + ":" + file.path)
    }

}
