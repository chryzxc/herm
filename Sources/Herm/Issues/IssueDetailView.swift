import Foundation
import SwiftUI

struct IssueDetailView: View {
    @ObservedObject var center: IssueCenterModel
    let onOpenChat: (GitHubIssueRecord) -> Void
    var isInspector = false
    @State private var descriptionExpanded = true
    @Environment(\.dockTitleRow) private var titleRow

    var body: some View {
        Group {
            if let issue = center.selected {
                Group {
                    if shouldShowLoadingState(for: issue) {
                        detailLoadingPane
                    } else {
                        issueContent(issue)
                    }
                }
                .task(id: "\(issue.id):\(center.isRefreshing)") { await center.loadSelectedDetail() }
            } else if center.isRefreshing && center.records.isEmpty {
                detailLoadingPane
            } else {
                VStack(spacing: 10) {
                    DockIcon(.fileText, size: 28, color: Color.dockMetadataText)
                    Text("Select an issue")
                }
                .dockFont(.navigation, weight: .medium)
                .foregroundStyle(Color.dockMetadataText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.dockCanvas)
        .onChange(of: center.selectedIssueID) { _, _ in descriptionExpanded = true }
    }

    private func shouldShowLoadingState(for issue: GitHubIssueRecord) -> Bool {
        center.detailByID[issue.id] == nil && center.detailErrorMessage == nil
    }

    private var detailLoadingPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RepositoryShimmerBlock(width: 188, height: 11, cornerRadius: 4)
                Spacer(minLength: 12)
                RepositoryShimmerBlock(width: 76, height: 26, cornerRadius: 7)
                RepositoryShimmerBlock(width: 104, height: 28, cornerRadius: 7)
            }
            .padding(.horizontal, isInspector ? 12 : 24)
            .frame(height: 52)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading issue")
                            .dockFont(.body, weight: .medium)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    .padding(.top, 28)

                    RepositoryShimmerBlock(width: nil, height: 26, cornerRadius: 7)
                        .padding(.top, 14)
                    RepositoryShimmerBlock(width: 420, height: 26, cornerRadius: 7)
                        .padding(.top, 8)

                    HStack(spacing: 10) {
                        RepositoryShimmerBlock(width: 64, height: 22, cornerRadius: 11)
                        RepositoryShimmerBlock(width: 248, height: 11, cornerRadius: 4)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 22)

                    RepositoryShimmerBlock(width: nil, height: 1, cornerRadius: 0)

                    VStack(alignment: .leading, spacing: 9) {
                        RepositoryShimmerBlock(width: nil, height: 11, cornerRadius: 4)
                        RepositoryShimmerBlock(width: nil, height: 11, cornerRadius: 4)
                        RepositoryShimmerBlock(width: 520, height: 11, cornerRadius: 4)
                        RepositoryShimmerBlock(width: 370, height: 11, cornerRadius: 4)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 48)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, isInspector ? 12 : 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading issue")
    }

    @ViewBuilder
    private func issueContent(_ issue: GitHubIssueRecord) -> some View {
        let displayedIssue = center.detailByID[issue.id] ?? issue
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    DockIcon(.folder, size: 12, color: Color.dockMetadataText)
                    Text(displayedIssue.repository.id)
                        .foregroundStyle(Color.dockSecondaryText)
                        .truncationMode(.middle)
                    Text("/").foregroundStyle(Color.dockMetadataText)
                    Text("#\(displayedIssue.number)").foregroundStyle(Color.dockMetadataText)
                }
                .dockFont(.metadata, weight: .medium, design: .monospaced)
                .lineLimit(1)
                Spacer(minLength: 12)
                    .frame(maxHeight: .infinity)
                    .background { if titleRow != nil { TitlebarDoubleClickArea() } }
                if let url = displayedIssue.webURL {
                    GitHubLinkButton(
                        destination: url,
                        accessibilityLabel: "Open issue on GitHub"
                    )
                }
                DockIconButton(
                    icon: .arrowsClockwise, label: "Refresh issue details", isBusy: center.loadingDetailID == issue.id,
                    style: DockThemePalette(theme: DockThemeRuntime.current)
                ) { Task { await center.refreshSelectedDetail() } }
                GitHubAuthoringMenu(
                    reference: displayedIssue.reference, client: center.api.client,
                    onIssueStateChanged: { center.applyIssueState($0) }
                ) { Task { await center.refreshSelectedDetail() } }.id(displayedIssue.id)
                DockMenu {
                    Button(
                        PullRequestChatLinkStore().sessionID(for: displayedIssue.id) == nil
                            ? "Prepare in Hermes" : "Open linked Hermes chat"
                    ) { onOpenChat(displayedIssue) }
                } label: {
                    DockIcon(.chatCircleText, size: 14, color: Color.dockSecondaryText).frame(width: 28, height: 28)
                        .background(
                            DockThemeShape(cornerRadius: DockLayout.controlRadius - 1).dockSurfaceFill(
                                Color.dockControlSurface.opacity(0.6)))
                }
                AttachToChatMenu(pill: true) { ChatContext(issue: displayedIssue) }
            }
            .padding(.horizontal, isInspector ? 12 : 24)
            .frame(height: 52)
            .background(titleRow != nil ? Color.dockSidebar : .clear)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
            .background(Color.dockCanvas)
            .zIndex(1)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            DockIcon(displayedIssue.presentationIcon, size: 16, color: displayedIssue.presentationColor)
                            Text(displayedIssue.repository.id).lineLimit(1).truncationMode(.middle)
                            Text("#\(displayedIssue.displayNumber)").foregroundStyle(Color.dockMetadataText)
                            Spacer(minLength: 0)
                            Text(displayedIssue.state.capitalized)
                                .foregroundStyle(displayedIssue.presentationColor)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(displayedIssue.presentationColor.opacity(0.12)))
                        }.foregroundStyle(Color.dockSecondaryText)
                        Text(displayedIssue.title)
                            .dockFont(.pageTitle)
                            .foregroundStyle(Color.dockPrimaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        issueMetadata(displayedIssue)
                        if let error = center.detailErrorMessage {
                            Text(error).foregroundStyle(Color.dockWarning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.dockFont(.body).dockCard(padding: 16)

                    VStack(alignment: .leading, spacing: 8) {
                        DockSectionHeader(
                            title: "Description", isExpanded: $descriptionExpanded,
                            style: DockThemePalette(theme: DockThemeRuntime.current))
                        if descriptionExpanded {
                            if displayedIssue.body.isEmpty {
                                Text("No description provided.").foregroundStyle(Color.dockSecondaryText)
                            } else {
                                MarkdownMessageView(markdown: displayedIssue.body)
                                    .frame(maxWidth: 820, alignment: .leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.dockFont(.body).dockCard(padding: 16)
                    GitHubMetadataView(reference: displayedIssue.reference, client: center.api.client) {
                        Task { await center.refreshSelectedDetail() }
                    }.id(issue.id)
                    GitHubConversationView(model: center.conversation(for: displayedIssue))
                        .id("conversation:" + issue.id)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, isInspector ? 12 : 16).padding(.top, 20).padding(.bottom, 32)
            }
            .clipped()
        }
    }

    private func issueMetadata(_ issue: GitHubIssueRecord) -> some View {
        let metadata = GitHubIssueRowMetadata.make(
            repository: issue.repository.id,
            assignees: issue.assignees,
            updated: issue.updatedAt.map { "updated " + HumanDateFormatting.relative($0) },
            viewer: center.viewerLogin
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                DockIcon(.user, size: 14, color: Color.dockSecondaryText)
                Text(issue.author).foregroundStyle(Color.dockPrimaryText)
                Text("opened this").foregroundStyle(Color.dockSecondaryText)
            }
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    assignment(metadata.assignment, issue: issue)
                    Spacer(minLength: 8)
                    if let updated = metadata.updated {
                        Text(updated).foregroundStyle(Color.dockMetadataText).fixedSize()
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    assignment(metadata.assignment, issue: issue)
                    if let updated = metadata.updated { Text(updated).foregroundStyle(Color.dockMetadataText) }
                }
            }
        }.dockFont(.body)
    }

    private func assignment(_ title: String, issue: GitHubIssueRecord) -> some View {
        HStack(spacing: 6) {
            DockIcon(.users, size: 14, color: .dockReview)
            Text(title).foregroundStyle(issue.assignees.isEmpty ? Color.dockSecondaryText : Color.dockReview)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
