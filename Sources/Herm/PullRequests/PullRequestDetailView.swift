import Foundation
import SwiftUI

struct PullRequestDetailView: View {
    @ObservedObject var center: PullRequestCenterModel
    let onOpenChat: (PullRequestRecord) -> Void

    @State private var detailRefreshID = 0
    @State private var detailTab = 0
    @State private var inlineTarget: GitHubInlineCommentTarget?
    @StateObject private var reviewPreferences = PullRequestReviewPreferenceStore()
    @State private var selectedFileID: String?
    @State private var fileQuery = ""
    @State private var viewedFiles = Set<String>()
    @State private var sourceDiffFileIDs: Set<String> = []
    @State private var descriptionExpanded = false
    @State private var checksExpanded = true
    @State private var activityExpanded = true
    private var commentDraft: String { center.commentDrafts[center.selectedID ?? ""] ?? "" }
    @StateObject private var diffPresentationCache = PullRequestDiffPresentationCache()
    @StateObject private var mutationCoordinator = PullRequestMutationCoordinator()
    @Environment(\.dockTitleRow) private var titleRow

    var body: some View {
        detailPane
            .task(id: "\(center.selectedID ?? ""):\(center.isRefreshing):\(detailRefreshID)") {
                guard center.selectedID != nil, !center.isRefreshing else { return }
                await center.loadSelectedDetail()
            }
            .task(id: viewedKey) { viewedFiles = Set(UserDefaults.standard.stringArray(forKey: viewedKey) ?? []) }
            .sheet(item: $inlineTarget) { target in
                if let record = center.selected { GitHubInlineCommentEditor(model: center.review(for: record), record: record, target: target) }
            }
            .onChange(of: center.selectedID) { _, _ in
                inlineTarget = nil
                selectedFileID = nil
                sourceDiffFileIDs.removeAll()
                diffPresentationCache.removeAll()
                descriptionExpanded = false
                checksExpanded = true
                activityExpanded = true
                viewedFiles = Set(UserDefaults.standard.stringArray(forKey: viewedKey) ?? [])
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
                            _ = await mutationCoordinator.confirm(using: center)
                        }
                    }
                case let .status(_, status):
                    Button(status == .closed ? "Close pull request" : status.rawValue, role: status == .closed ? .destructive : nil) {
                        Task { _ = await mutationCoordinator.confirm(using: center) }
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
        detailHeader(pr)
        if detailTab == 0 {
            ScrollView { summary(pr).padding(.horizontal, 24) }
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
                } label: { DockIcon(.chatCircleText, size: 14, color: Color.dockSecondaryText).frame(width: 28, height: 28) }
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
    private func summary(_ pr: PullRequestRecord) -> some View { VStack(alignment: .leading, spacing: 0) {
        Text(pr.title)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Color.dockPrimaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 26)

        HStack(spacing: 10) {
            authorAvatar(pr)
            Text(pr.author).font(.system(size: 13, weight: .medium))
            if let updatedAt = pr.updatedAt {
                Text("•")
                Text(pullRequestAge(updatedAt))
            }
        }
        .foregroundStyle(Color.dockMetadataText)
        .padding(.top, 12)
        .padding(.bottom, 22)

        VStack(alignment: .leading, spacing: 12) {
            summaryDetailRow(icon: .gitBranch, title: "Branch") {
                HStack(spacing: 8) {
                    Text(pr.headBranch).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    DockIcon(.arrowRight, size: 13, color: Color.dockMetadataText)
                    Text(pr.baseBranch).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    if let additions = pr.additions { Text("+\(additions)").foregroundStyle(Color.dockSuccess).fixedSize(horizontal: true, vertical: false) }
                    if let deletions = pr.deletions { Text("−\(deletions)").foregroundStyle(Color.dockDestructive).fixedSize(horizontal: true, vertical: false) }
                }
            }
            summaryDetailRow(icon: .users, title: "Reviewers") {
                Text(pr.requestedReviewers.isEmpty ? "No reviewers requested" : pr.requestedReviewers.joined(separator: ", "))
            }
            summaryDetailRow(icon: .chats, title: "Comments") {
                Text(pr.comments == 0 ? "No comments" : "\(pr.comments) comment\(pr.comments == 1 ? "" : "s")")
            }
            summaryDetailRow(icon: .checkCircle, title: "Checks", color: checksColor(for: pr)) {
                Text(checksLabel(for: pr))
                    .foregroundStyle(checksColor(for: pr))
            }
            summaryDetailRow(icon: .gitPullRequest, title: "Status") {
                statusPicker(pr)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.dockSecondaryText)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).fill(Color.dockSurface2))
        .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))

        PullRequestReadinessView(center: center, record: pr).padding(.top, 16)
        PullRequestLandingView(record: pr, client: center.api.client) { Task { await center.refreshSelectedDetail() } }.padding(.top, 12)
        GitHubMetadataView(reference: pr.reference, client: center.api.client) { Task { await center.refreshSelectedDetail() } }
            .id(pr.id).padding(.top, 16)

        summarySectionHeader("Description", isExpanded: $descriptionExpanded).padding(.top, 20)
        if descriptionExpanded {
            if pr.body.isEmpty {
                Text("No description provided.").font(.system(size: 13)).foregroundStyle(Color.dockMetadataText).padding(.top, 12)
            } else {
                MarkdownMessageView(markdown: pr.body).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            }
        }

        summarySectionHeader("Checks", count: pr.checks.isEmpty ? nil : pr.checks.count, isExpanded: $checksExpanded)
            .padding(.top, 20)
        if checksExpanded { checksSection(pr).padding(.top, 12) }

        let activityCount = (center.commitsByID[pr.id] ?? []).count + (center.commentsByID[pr.id] ?? []).count + (center.eventsByID[pr.id] ?? []).filter { $0.presentation != nil }.count + 1
        summarySectionHeader("Activity", count: activityCount, isExpanded: $activityExpanded)
            .padding(.top, 20)
        if activityExpanded {
            activitySection(pr).padding(.top, 12)
            commentComposer(pr).padding(.top, 18).padding(.bottom, 40)
        }
    }.frame(maxWidth: .infinity, alignment: .leading) }

    private func summarySectionHeader(_ title: String, count: Int? = nil, isExpanded: Binding<Bool>) -> some View {
        Button { isExpanded.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                DockIcon(isExpanded.wrappedValue ? .caretDown : .caretRight, size: 13, color: Color.dockMetadataText)
                Text(title).font(.system(size: 13, weight: .semibold))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.dockMetadataText)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Capsule().fill(Color.dockSurface4))
                }
                Spacer()
            }
            .foregroundStyle(Color.dockPrimaryText)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
        .accessibilityLabel("\(isExpanded.wrappedValue ? "Collapse" : "Expand") \(title)")
    }

    @ViewBuilder
    private func checksSection(_ pr: PullRequestRecord) -> some View {
        if pr.checks.isEmpty {
            HStack(spacing: 12) {
            Text("No checks reported by GitHub.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dockMetadataText)
                Spacer()
                Button {
                    center.invalidateSelectedDetail()
                    detailRefreshID += 1
                } label: {
                    DockIcon(.arrowsClockwise, size: 15, color: Color.dockSecondaryText)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.dockHover)
                .disabled(center.isLoadingDetail)
                .help("Refresh checks")
                .accessibilityLabel("Refresh checks")
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).fill(Color.dockSurface2))
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
            .background(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).fill(Color.dockSurface2))
            .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
        }
    }

    private func activitySection(_ pr: PullRequestRecord) -> some View {
        var items = (center.commentsByID[pr.id] ?? []).map { GitHubConversationItem(id: "comment:" + $0.id, author: $0.author, summary: "commented", body: $0.body, date: $0.createdAt, url: $0.webURL, avatarURL: $0.authorAvatarURL) }
        items += (center.commitsByID[pr.id] ?? []).map { GitHubConversationItem(id: "commit:" + $0.id, author: $0.author, summary: $0.message, body: "", date: $0.committedAt, url: $0.webURL, avatarURL: $0.authorAvatarURL) }
        items += pr.reviews.map { GitHubConversationItem(id: "review:" + $0.id, author: $0.author, summary: $0.state.replacingOccurrences(of: "_", with: " ").capitalized, body: $0.body, date: $0.submittedAt, url: $0.webURL, avatarURL: $0.authorAvatarURL) }
        items += (center.eventsByID[pr.id] ?? []).compactMap { event in event.presentation.map { GitHubConversationItem(id: "event:" + event.id, author: event.actor, summary: $0.text, body: "", date: event.createdAt, url: nil, avatarURL: event.actorAvatarURL) } }
        return GitHubTimelineView(reference: pr.reference, items: items.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
    }

    private func activityRow(icon: Ph, iconColor: Color, title: String, detail: String? = nil, trailing: String? = nil, avatarURL: URL? = nil, age: String? = nil) -> some View {
        HStack(spacing: 10) {
            DockIcon(icon, size: 14, color: iconColor)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.dockSurface4.opacity(0.55)))
            VStack(alignment: .leading, spacing: detail == nil ? 0 : 5) {
                Text(title).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText).lineLimit(2) }
            }
            Spacer(minLength: 12)
            if let trailing { Text(trailing).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dockMetadataText) }
            if let avatarURL { AsyncImage(url: avatarURL) { phase in if let image = phase.image { image.resizable().scaledToFill() } else { avatarFallback } }.frame(width: 24, height: 24).clipShape(Circle()) }
            if let age { Text(age).foregroundStyle(Color.dockMetadataText) }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.dockSecondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).fill(Color.dockSurface2))
        .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
    }

    private func commentComposer(_ pr: PullRequestRecord) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: center.commentDraft(for: pr.id))
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 104)
                .background(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).fill(Color.dockSurface2))
                .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
            if commentDraft.isEmpty {
                Text("Leave a comment")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dockMetadataText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
            HStack {
                avatarFallback
                Spacer()
                Button {
                    let draft = commentDraft
                    mutationCoordinator.requestComment(draft, for: pr)
                } label: {
                    if center.isPostingComment { ProgressView().controlSize(.small).frame(width: 34, height: 34) }
                    else { DockIcon(.arrowUp, size: 17, color: commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.dockMetadataText : Color.dockPrimaryText).frame(width: 34, height: 34).background(Circle().fill(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.dockSurface4 : Color.dockAccent)) }
                }
                .buttonStyle(.dockHover)
                .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || commentDraft.count > 10_000 || center.isPostingComment)
                .help("Add comment")
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func checkIcon(for check: GitHubCheckSummary) -> Ph { checkColor(for: check) == Color.dockSuccess ? .check : (checkColor(for: check) == Color.dockDestructive ? .x : .clock) }
    private func checkColor(for check: GitHubCheckSummary) -> Color {
        let conclusion = check.conclusion?.lowercased()
        if ["success", "neutral", "skipped"].contains(conclusion) { return Color.dockSuccess }
        if ["failure", "cancelled", "timed_out", "action_required"].contains(conclusion) { return Color.dockDestructive }
        return Color.dockWarning
    }
    private func checkPresentation(for check: GitHubCheckSummary) -> String {
        guard check.status.lowercased() == "completed" else { return "Running" }
        switch check.conclusion?.lowercased() {
        case "success": return "Passed"
        case "failure": return "Failed"
        case "cancelled": return "Cancelled"
        case "skipped", "neutral": return "Skipped"
        default: return "Completed"
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
    private func statusPicker(_ pr: PullRequestRecord) -> some View {
        let current: PullRequestStatus = pr.state == "closed" ? .closed : (pr.isDraft ? .draft : .readyForReview)
        return DockMenu {
            ForEach(PullRequestStatus.allCases) { status in
                Button {
                    mutationCoordinator.requestStatus(status, for: pr)
                } label: {
                    HStack {
                        Text(status.rawValue)
                        Spacer()
                        if status == current { Ph.check.image(size: 14) }
                    }
                }
                .disabled(status == .reopened && pr.state != "closed")
            }
            .disabled(pr.mergedAt != nil)
        } label: {
            HStack(spacing: 7) {
                if center.isUpdatingStatus { ProgressView().controlSize(.mini) }
                Text(pr.mergedAt != nil ? "Merged" : current.rawValue)
                DockIcon(.caretDown, size: 15, color: Color.dockSecondaryText)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.dockSurface2))
        }
        .disabled(center.isUpdatingStatus)
        .help("Change pull request status")
        .accessibilityLabel("Pull request status: \(current.rawValue)")
    }
    private func checksLabel(for pr: PullRequestRecord) -> String {
        if pr.checks.contains(where: { $0.isFailure }) { return "Failed" }
        if pr.checks.contains(where: { $0.isPending }) { return "In progress" }
        return !pr.checksAvailable ? "Some checks unavailable" : (pr.checks.isEmpty ? "No checks" : (pr.checks.allSatisfy(\.isSuccess) ? "Passed" : "Status unknown"))
    }
    private func checksColor(for pr: PullRequestRecord) -> Color {
        if pr.checks.contains(where: { $0.isFailure }) { return Color.dockDestructive }
        if pr.checks.contains(where: { $0.isPending }) { return Color.dockWarning }
        return !pr.checksAvailable || pr.checks.isEmpty || !pr.checks.allSatisfy(\.isSuccess) ? Color.dockMetadataText : Color.dockSuccess
    }
    private func pullRequestAge(_ updatedAt: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(updatedAt))
        if seconds >= 86_400 { return "\(Int(seconds / 86_400))d" }
        if seconds >= 3_600 { return "\(Int(seconds / 3_600))h" }
        return "\(max(1, Int(seconds / 60)))m"
    }
    private func detailTabButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.dockEase(duration: 0.18)) { action() }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.dockPrimaryText : Color.dockMetadataText)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).fill(selected ? Color.dockSurface4 : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    private var viewedKey: String { "hermes.pull-request-review.viewed." + (center.selectedID ?? "") + "." + (center.selected?.headRevision ?? "unknown") }

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
            HStack {
                Toggle("Viewed", isOn: Binding(get: { viewedFiles.contains(file.path) }, set: { value in
                    if value { viewedFiles.insert(file.path) } else { viewedFiles.remove(file.path) }
                    UserDefaults.standard.set(Array(viewedFiles).sorted(), forKey: viewedKey)
                })).toggleStyle(.dockSwitch)
                Text("\(viewedFiles.count) viewed at this revision").foregroundStyle(Color.dockMetadataText)
                Spacer()
            }.font(DockTypography.body).padding(.horizontal, 10).padding(.vertical, 4)
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
        let rows = diffPresentationCache.rows(for: patch)
        Group {
            if reviewPreferences.diffMode == .split {
                // Split reviews must always start with both sides visible. Each
                // pane shares the available viewport instead of sizing itself to
                // the longest line in the patch.
                diffRows(rows, file: file)
            } else if reviewPreferences.wordWrap {
                diffRows(rows, file: file)
            } else {
                ScrollView(.horizontal, showsIndicators: true) { diffRows(rows, file: file).fixedSize(horizontal: true, vertical: false) }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous))
    }

    @ViewBuilder
    private func diffRows(_ rows: [PullRequestDiffSplitRow], file: PullRequestFile) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                if reviewPreferences.diffMode == .split, row.left?.kind == .hunk {
                    diffLineView(row.left, counterpart: nil, file: file)
                } else if reviewPreferences.diffMode == .split {
                    HStack(spacing: 0) {
                        splitDiffColumn(row.left, counterpart: row.right?.text, file: file)
                        Color.dockBorderLight.frame(width: 0.5)
                        splitDiffColumn(row.right, counterpart: row.left?.text, file: file)
                    }
                } else if let left = row.left, let right = row.right, left.kind == .deletion, right.kind == .addition {
                    diffLineView(left, counterpart: right.text, file: file)
                    diffLineView(right, counterpart: left.text, file: file)
                } else {
                    diffLineView(row.left ?? row.right, counterpart: nil, file: file)
                }
            }
        }
    }

    private func splitDiffColumn(_ line: PullRequestDiffLine?, counterpart: String?, file: PullRequestFile) -> some View {
        diffLineView(line, counterpart: counterpart, file: file)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)
    }

    @ViewBuilder
    private func diffLineView(_ line: PullRequestDiffLine?, counterpart: String?, file: PullRequestFile) -> some View {
        if let line {
            HStack(spacing: 0) {
                Text(line.oldLine.map(String.init) ?? " ").frame(width: 38, alignment: .trailing)
                Text(line.newLine.map(String.init) ?? " ").frame(width: 38, alignment: .trailing).padding(.trailing, 8)
                PullRequestDiffLineView(
                line: line,
                counterpart: counterpart,
                wordDiffsEnabled: reviewPreferences.wordDiffs && (line.kind == .addition || line.kind == .deletion)
                )
            }.foregroundStyle(Color.dockMetadataText)
            .contextMenu {
                if let pr = center.selected, center.filesAreCurrent(for: pr), let revision = pr.headRevision, pr.state == "open", let number = line.newLine ?? line.oldLine {
                    Button("Comment on line \(number)") { inlineTarget = GitHubInlineCommentTarget(path: file.path, line: number, side: line.newLine == nil ? "LEFT" : "RIGHT", revision: revision) }
                }
            }
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: 19)
        }
    }
}

