import SwiftUI

/// Calm inline facts for a repository list row: language, stars and archive state.
struct GitHubRepositoryFacts: View {
    let repository: GitHubRepositorySummary
    @Environment(\.dockWorkspaceScale) private var workspaceScale

    var body: some View {
        HStack(spacing: 12) {
            if let language = repository.language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
                HStack(spacing: 4) {
                    if let image = ArtifactFileIcon.image(forLanguage: language) {
                        Image(nsImage: image)
                            .renderingMode(
                                DockThemeRuntime.current == .mono || DockThemeRuntime.current == .eInk
                                    ? .template : .original
                            )
                            .resizable().interpolation(.high).scaledToFit()
                            .frame(
                                width: DockWorkspaceScale.points(12, scale: workspaceScale),
                                height: DockWorkspaceScale.points(12, scale: workspaceScale)
                            )
                            .accessibilityHidden(true)
                    }
                    Text(language)
                }
            }
            if repository.stars > 0 {
                HStack(spacing: 3) {
                    DockIcon(.star, size: 11, color: .dockMetadataText)
                    Text(repository.stars.formatted()).monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(repository.stars) stars")
            }
            if repository.archived {
                HStack(spacing: 3) {
                    DockIcon(.archive, size: 11, color: .dockMetadataText)
                    Text("Archived")
                }
            }
        }
        .dockFont(.metadata).foregroundStyle(Color.dockMetadataText).lineLimit(1)
    }
}

struct GitHubRepositoryOverview: View {
    let repository: GitHubRepositorySummary
    let close: () -> Void
    @StateObject private var details: GitHubRepositoryDetailsModel
    @StateObject private var activity: GitHubRepositoryActivityModel
    @State private var tab = "Overview"
    @State private var refreshID = 0
    @Environment(\.openGitHubRepository) private var openRepository

    init(repository: GitHubRepositorySummary, client: GitHubClient, close: @escaping () -> Void) {
        self.repository = repository
        self.close = close
        _details = StateObject(wrappedValue: GitHubRepositoryDetailsModel(client: client))
        _activity = StateObject(
            wrappedValue: GitHubRepositoryActivityModel(repository: repository.reference, client: client))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DockTabBar(options: ["Overview", "Activity"], selection: $tab, title: { $0 })
                Spacer(minLength: 8)
                DockIconButton(
                    icon: .arrowsClockwise, label: "Refresh repository activity and details",
                    isBusy: tab == "Activity" ? activity.loading : details.loading,
                    style: palette
                ) {
                    if tab == "Activity" { activity.reload() } else { refreshID += 1 }
                }.disabled(tab == "Activity" ? activity.loading : details.loading)
                DockIconButton(icon: .x, label: "Close repository details", style: palette, action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).frame(height: 52)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
            if tab == "Activity" {
                GitHubRepositoryActivityView(model: activity)
            } else {
                overviewContent
            }
        }
        .dockFont(.body).foregroundStyle(Color.dockPrimaryText).background(Color.dockCanvas)
        .task(id: refreshID) { await details.refresh(repository) }
    }

    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                detailsCard
                latestRelease
                recentCommits
                recentActivity
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 24).padding(.vertical, 20)
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                (Text("\(repository.owner) / ").foregroundStyle(Color.dockMetadataText)
                    + Text(repository.name).fontWeight(.semibold).foregroundStyle(Color.dockPrimaryText))
                    .dockFont(.navigation).textSelection(.enabled).lineLimit(2)
                Spacer(minLength: 8)
                DockCopyButton(
                    repository.id, accessibilityLabel: "Copy repository name \(repository.id)", presentation: .icon
                ).buttonStyle(.dockHover)
            }
            if !repository.description.isEmpty {
                Text(repository.description).foregroundStyle(Color.dockSecondaryText)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            DockChipFlow(spacing: 6) {
                if let language = repository.language, !language.trimmingCharacters(in: .whitespaces).isEmpty {
                    DockMetadataPill(text: language, language: language)
                }
                DockMetadataPill(text: repository.isPrivate ? "Private" : "Public")
                if repository.archived { DockMetadataPill(text: "Archived") }
            }
            HStack(spacing: 16) {
                statistic(.star, value: repository.stars.formatted(), label: repository.stars == 1 ? "star" : "stars")
                statistic(
                    .gitFork, value: repository.forks?.formatted() ?? "—",
                    label: repository.forks == 1 ? "fork" : "forks"
                )
                statistic(
                    .gitPullRequest, value: repository.openIssuesAndPullRequests?.formatted() ?? "—",
                    label: "open issues & PRs")
            }
            .dockFont(.body).padding(.top, 2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    actions
                    Spacer(minLength: 0)
                    navigationLinks
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { actions }
                    HStack(spacing: 8) { navigationLinks }
                }
                VStack(alignment: .leading, spacing: 8) {
                    actions
                    navigationLinks
                }
            }
            .dockButtonSize(.compact).padding(.top, 4)
        }
    }

    private func statistic(_ icon: Ph, value: String, label: String) -> some View {
        HStack(spacing: 5) {
            DockIcon(icon, size: 13, color: .dockMetadataText)
            Text(value).fontWeight(.semibold).monospacedDigit()
            Text(label).foregroundStyle(Color.dockMetadataText)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actions: some View {
        Link(destination: repository.reference.webURL) {
            DockIconLabel("Open on GitHub", icon: .arrowUpRight)
        }.buttonStyle(.dockPrimary)
        DockCopyButton(
            repository.cloneURL, label: "Copy clone URL", accessibilityLabel: "Copy repository HTTPS clone URL"
        )
        .buttonStyle(.dockSecondary)
    }

    @ViewBuilder private var navigationLinks: some View {
        if repository.hasIssues != false { repositoryWork("Issues", kind: .issue, path: "issues") }
        repositoryWork("Pull requests", kind: .pullRequest, path: "pulls")
        repositoryLink("Actions", path: "actions")
    }

    @ViewBuilder private func repositoryWork(_ title: String, kind: GitHubItemKind, path: String) -> some View {
        if let openRepository {
            Button {
                openRepository(repository.reference, kind)
            } label: {
                DockIconLabel(title, icon: kind == .issue ? .record : .gitPullRequest)
            }
            .buttonStyle(.dockSecondary)
            .help("Browse \(title.lowercased()) in \(repository.id)")
        } else {
            repositoryLink(title, path: path)
        }
    }

    private func repositoryLink(_ title: String, path: String) -> some View {
        Link(destination: repository.reference.webURL.appendingPathComponent(path)) {
            DockIconLabel(title, icon: .arrowUpRight)
        }.buttonStyle(.dockSecondary)
    }

    // MARK: Details

    private var detailsCard: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .topLeading)], spacing: 14) {
            detail("Default branch", value: repository.defaultBranch ?? "Unavailable", icon: .gitBranch, mono: true)
            detail("Your access", value: repository.access ?? "Unavailable", icon: .user)
            detail("License", value: repository.license ?? "Not specified", icon: .scales)
            detail("Last push", date: repository.pushedAt, icon: .gitCommit)
            detail("Last updated", date: repository.updatedAt, icon: .clock)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 14, isQuiet: true)
    }

    private func detail(_ title: String, date: Date?, icon: Ph) -> some View {
        detail(title, value: date.map { HumanDateFormatting.relative($0) } ?? "Unavailable", icon: icon)
            .help(date?.formatted(date: .abbreviated, time: .shortened) ?? "")
    }

    private func detail(_ title: String, value: String, icon: Ph, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DockIconLabel(title, icon: icon).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
            Text(value).dockFont(mono ? .machineMetadata : .body, weight: .medium)
                .foregroundStyle(Color.dockPrimaryText).textSelection(.enabled).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Sections

    private func sectionHeader(_ title: String) -> some View {
        DockSectionHeader(title: title, style: palette, isContentHeader: true)
    }

    private var latestRelease: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Latest release")
            if let error = details.releaseError { sectionError(error, retained: details.release != nil) }
            if let release = details.release {
                Link(destination: release.url) {
                    HStack(alignment: .top, spacing: 10) {
                        DockIcon(.tag, size: 14, color: .dockSecondaryText).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(release.name).dockFont(.body, weight: .semibold)
                                    .foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                                if release.draft {
                                    DockMetadataPill(text: "Draft")
                                } else if release.prerelease {
                                    DockMetadataPill(text: "Pre-release")
                                }
                            }
                            HStack(spacing: 8) {
                                if release.name != release.tag { Text(release.tag).dockFont(.machineMetadata) }
                                if let date = release.publishedAt {
                                    Text("Published \(date.formatted(date: .abbreviated, time: .omitted))")
                                }
                            }.dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text("Release notes").dockFont(.metadata).foregroundStyle(Color.dockAccent).underline()
                        DockIcon(.arrowUpRight, size: 12, color: .dockAccent)
                    }
                    .multilineTextAlignment(.leading).contentShape(Rectangle())
                    .dockListRow()
                }
                .buttonStyle(.dockHover)
                .help("Open release notes on GitHub")
            } else if details.releaseError == nil {
                placeholder(details.hasLoaded ? "No releases published yet." : "Loading release…")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recentCommits: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionHeader("Recent commits")
                if let branch = repository.defaultBranch {
                    HStack(spacing: 4) {
                        DockIcon(.gitBranch, size: 11, color: .dockMetadataText)
                        Text(branch).dockFont(.machineMetadata)
                    }.foregroundStyle(Color.dockMetadataText)
                }
                Spacer(minLength: 8)
                Link(destination: repository.reference.webURL.appendingPathComponent("commits")) {
                    DockIconLabel("View history", icon: .arrowUpRight)
                }.buttonStyle(.dockLink)
            }
            if let error = details.commitError { sectionError(error, retained: details.commits != nil) }
            if let commits = details.commits {
                if commits.isEmpty { placeholder("No commits returned by GitHub.") }
                VStack(spacing: 0) {
                    ForEach(commits) { commit in
                        HStack(alignment: .center, spacing: 8) {
                            Link(
                                destination: repository.reference.webURL.appendingPathComponent("commit")
                                    .appendingPathComponent(commit.sha)
                            ) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(String(commit.sha.prefix(7))).dockFont(.machineMetadata)
                                        .foregroundStyle(Color.dockAccent)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(commit.title).dockFont(.body, weight: .medium)
                                            .foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                                        HStack(spacing: 6) {
                                            if let author = commit.author { Text(author).lineLimit(1) }
                                            if commit.author != nil, commit.date != nil { Text("·") }
                                            if let date = commit.date {
                                                Text(HumanDateFormatting.relative(date)).fixedSize()
                                                    .help(date.formatted())
                                            }
                                        }.dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .multilineTextAlignment(.leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.dockHover)
                            .help("Open commit on GitHub")
                            DockCopyButton(
                                commit.sha, accessibilityLabel: "Copy commit SHA \(commit.sha.prefix(7))",
                                presentation: .icon
                            )
                            .buttonStyle(.dockHover)
                        }
                        .dockListRow()
                    }
                }
            } else if details.commitError == nil {
                placeholder("Loading commits…")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Recent events")
            if let error = details.activityError { sectionError(error, retained: details.events != nil) }
            if let events = details.events {
                if events.isEmpty { placeholder("No recent activity returned by GitHub.") }
                VStack(spacing: 0) {
                    ForEach(events) { event in
                        Link(destination: event.url) {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.summary).dockFont(.body, weight: .medium)
                                        .foregroundStyle(Color.dockPrimaryText).lineLimit(2)
                                    if let detail = event.detail, !detail.isEmpty {
                                        Text(detail).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                                            .lineLimit(2)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(HumanDateFormatting.relative(event.date)).dockFont(.metadata)
                                    .foregroundStyle(Color.dockMetadataText).fixedSize()
                                    .help(event.date.formatted())
                                DockIcon(.arrowUpRight, size: 12, color: .dockMetadataText).padding(.top, 2)
                            }
                            .multilineTextAlignment(.leading).contentShape(Rectangle())
                            .dockListRow()
                        }.buttonStyle(.dockHover)
                    }
                }
            } else if details.activityError == nil {
                placeholder("Loading activity…")
            }
            Text("Reported by GitHub; updates may be delayed.")
                .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(Color.dockMetadataText).padding(.vertical, 4)
    }

    private func sectionError(_ message: String, retained: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            DockIcon(.warning, size: 13, color: .dockWarning).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(retained ? "Couldn’t refresh. Showing previous data." : "Unavailable")
                    .dockFont(.body, weight: .medium).foregroundStyle(Color.dockPrimaryText)
                Text(message).foregroundStyle(Color.dockSecondaryText)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") { refreshID += 1 }.buttonStyle(.dockSecondary).disabled(details.loading)
        }
        .dockButtonSize(.compact)
    }

    private var palette: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }
}
