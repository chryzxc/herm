import Foundation
import SwiftUI

struct IssueDetailView: View {
    @ObservedObject var center: IssueCenterModel
    let onOpenChat: (GitHubIssueRecord) -> Void
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.dockMetadataText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.dockCanvas)
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
            .padding(.horizontal, 24)
            .frame(height: 52)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading issue")
                            .font(.system(size: 12, weight: .medium))
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
                .padding(.horizontal, 28)
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
                    Text("#\(displayedIssue.number)").foregroundStyle(Color.dockAccent)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                DockIconButton(icon: .arrowsClockwise, label: "Refresh issue details", isBusy: center.loadingDetailID == issue.id, style: DockThemePalette(theme: DockThemeRuntime.current)) { Task { await center.refreshSelectedDetail() } }
                GitHubAuthoringMenu(reference: displayedIssue.reference, client: center.api.client, onIssueStateChanged: { center.applyIssueState($0) }) { Task { await center.refreshSelectedDetail() } }.id(displayedIssue.id)
                DockMenu {
                    Button(PullRequestChatLinkStore().sessionID(for: displayedIssue.id) == nil ? "Prepare in Hermes" : "Open linked Hermes chat") { onOpenChat(displayedIssue) }
                } label: { DockIcon(.chatCircleText, size: 14, color: Color.dockSecondaryText).frame(width: 28, height: 28)
                    .background(Color.dockControlSurface.opacity(0.6), in: DockThemeShape(cornerRadius: DockLayout.controlRadius - 1)) }
                AttachToChatMenu(pill: true) { ChatContext(issue: displayedIssue) }
            }
            .padding(.horizontal, 24)
            .frame(height: 52)
            .background(titleRow != nil ? Color.dockSidebar : .clear)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            if let error = center.detailErrorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayedIssue.title)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 28)

                    issueMetadata(displayedIssue)
                        .padding(.top, 14)
                        .padding(.bottom, 22)

                    Color.dockBorderLight.frame(height: 0.5)

                    GitHubMetadataView(reference: displayedIssue.reference, client: center.api.client) { Task { await center.refreshSelectedDetail() } }.id(issue.id).padding(.top, 16)
                    GitHubConversationView(model: center.conversation(for: displayedIssue), description: displayedIssue.body)
                        .id("conversation:" + issue.id).padding(.top, 24)


                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
            }
        }
    }

    private func issueMetadata(_ issue: GitHubIssueRecord) -> some View {
        let metadata = GitHubIssueRowMetadata.make(
            repository: issue.repository.id,
            assignees: issue.assignees,
            updated: issue.updatedAt.map { "updated " + HumanDateFormatting.relative($0) },
            viewer: center.viewerLogin
        )
        return HStack(spacing: 10) {
            DockStatusPill(tone: issue.isOpen ? .complete : .inactive, text: issue.state.capitalized)
            HStack(spacing: 5) {
                Text(issue.author).fontWeight(.medium).foregroundStyle(Color.dockSecondaryText)
                Text("opened this")
                Text("·")
                Text(metadata.assignment)
                if let updated = metadata.updated {
                    Text("·")
                    Text(updated)
                }
            }
            .lineLimit(1)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.dockMetadataText)
    }
}

