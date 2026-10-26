import SwiftUI

struct GitHubRepositoryMetadata: View {
    let repository: GitHubRepositorySummary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                language
                visibility
                stars
                archive
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    language
                    visibility
                }
                HStack(spacing: 12) {
                    stars
                    archive
                }
            }
        }
        .font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
    }

    @ViewBuilder private var language: some View {
        if let language = repository.language {
            HStack(spacing: 5) {
                Circle().fill(repository.languageAccent.fill).frame(width: 7, height: 7)
                Text(language)
            }
        }
    }

    private var visibility: some View {
        Label(repository.isPrivate ? "Private" : "Public", systemImage: repository.isPrivate ? "lock" : "globe")
            .foregroundStyle(repository.isPrivate ? DockAccentColor.violet.color : DockAccentColor.teal.color)
    }

    private var stars: some View {
        Label(repository.stars.formatted(), systemImage: "star")
            .foregroundStyle(DockAccentColor.amber.color)
    }

    @ViewBuilder private var archive: some View {
        if repository.archived { Label("Archived", systemImage: "archivebox") }
    }
}

struct GitHubRepositoryOverview: View {
    let repository: GitHubRepositorySummary
    let status: String
    let refreshing: Bool
    let refresh: () -> Void
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        DockExpandedPage(
            title: repository.id, subtitle: status, onRefresh: refresh,
            isRefreshing: refreshing, close: close
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GitHubRepositoryMetadata(repository: repository)
                    if !repository.description.isEmpty {
                        Text(repository.description).textSelection(.enabled)
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                    VStack(spacing: 12) {
                        metric("Stars", value: repository.stars.formatted(), icon: "star", accent: .amber)
                        metric(
                            "Forks", value: repository.forks?.formatted() ?? "Unavailable",
                            icon: "arrow.triangle.branch", accent: .blue)
                        metric(
                            "Open issues & PRs",
                            value: repository.openIssuesAndPullRequests?.formatted() ?? "Unavailable",
                            icon: "circle.dotted", accent: .green)
                    }
                    VStack(spacing: 0) {
                        detail(
                            "Default branch", value: repository.defaultBranch ?? "Unavailable",
                            icon: "arrow.triangle.branch")
                        Divider().overlay(Color.dockBorderLight)
                        detail(
                            "Last push",
                            value: repository.pushedAt?.formatted(date: .abbreviated, time: .shortened)
                                ?? "Unavailable", icon: "clock")
                        Divider().overlay(Color.dockBorderLight)
                        detail("License", value: repository.license ?? "Not specified", icon: "doc.text")
                    }
                    HStack(spacing: 10) {
                        Link(destination: repository.reference.webURL) {
                            Label("Open on GitHub", systemImage: "arrow.up.right")
                        }.buttonStyle(.dockSecondary)
                        Button(copied ? "Copied" : "Copy clone URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(repository.cloneURL, forType: .string)
                            copied = true
                        }.buttonStyle(.dockCompact)
                    }
                }
                .padding(20).frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .font(.system(size: 12)).foregroundStyle(Color.dockPrimaryText)
    }

    private func metric(_ title: String, value: String, icon: String, accent: DockAccentColor) -> some View {
        HStack {
            Label(title, systemImage: icon).foregroundStyle(accent.color)
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
    }

    private func detail(_ title: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Label(title, systemImage: icon).foregroundStyle(Color.dockSecondaryText)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.padding(.vertical, 14)
    }
}
