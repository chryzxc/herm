import SwiftUI

struct GitHubRepositoryActivityView: View {
    @ObservedObject var model: GitHubRepositoryActivityModel
    private var palette: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    DockSectionHeader(title: "Activity", style: palette, isContentHeader: true)
                    Spacer(minLength: 0)
                    filterMenu(
                        title: model.filters.oldestFirst ? "Oldest first" : "Most recent first", icon: .arrowsDownUp,
                        selection: $model.filters.oldestFirst,
                        choices: [("Most recent first", false), ("Oldest first", true)])
                }
                DockChipFlow(spacing: 8) {
                    filterMenu(
                        title: model.filters.branch.isEmpty ? "All branches" : short(branchName(model.filters.branch)),
                        icon: .gitBranch,
                        selection: $model.filters.branch,
                        choices: [("All branches", "")] + model.branches.map { (branchName($0), $0) }
                    )
                    .help("Filter by branches found in loaded activity")
                    filterMenu(
                        title: model.filters.type.title, icon: .gitCommit, selection: $model.filters.type,
                        choices: GitHubActivityType.allCases.map { ($0.title, $0) })
                    filterMenu(
                        title: model.filters.actor.isEmpty ? "All users" : short(model.filters.actor), icon: .users,
                        selection: $model.filters.actor, choices: [("All users", "")] + model.actors.map { ($0, $0) }
                    )
                    .help("Filter by users found in loaded activity")
                    filterMenu(
                        title: model.filters.period.title, icon: .clock, selection: $model.filters.period,
                        choices: GitHubActivityPeriod.allCases.map { ($0.title, $0) })
                }
                Text(status).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).lineLimit(2)
                    .help(model.error ?? "Branch and user choices are discovered from loaded activity.")
            }
            .dockButtonSize(.compact).dockPadding(.horizontal, 16).dockPadding(.vertical, 12)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(
                                model.loading
                                    ? "Loading activity…"
                                    : (model.error == nil ? "No matching code activity" : "Activity unavailable")
                            )
                            .dockFont(.body, weight: .semibold)
                            Text(model.error ?? "Pushes, merges, and branch changes reported by GitHub appear here.")
                                .foregroundStyle(Color.dockSecondaryText)
                            if model.error != nil {
                                Button("Retry") { model.reload() }.buttonStyle(.dockSecondary).disabled(model.loading)
                            } else if model.filters != GitHubActivityFilters() {
                                Button("Clear filters") { model.filters = GitHubActivityFilters() }.buttonStyle(
                                    .dockSecondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).dockPadding(16)
                    }
                    ForEach(model.items) { item in
                        activityRow(item)
                            .task(id: model.loading) { await model.loadSummary(item) }
                        Divider().overlay(Color.dockBorderLight)
                    }
                }
                .overlay(
                    DockThemeShape(cornerRadius: DockLayout.controlRadius).stroke(
                        Color.dockBorderLight, lineWidth: model.items.isEmpty ? 0 : DockLayout.hairline)
                )
                .dockPadding(16)
            }
        }
        .dockFont(.body).foregroundStyle(Color.dockPrimaryText).background(Color.dockCanvas)
        .task(id: model.request) { await model.load() }
        .onDisappear { model.cancelLoads() }
    }

    private var status: String {
        if model.loading { return "Loading activity…" }
        if model.error != nil {
            return model.items.isEmpty
                ? "Couldn’t load activity. Retry to refresh." : "Refresh failed · Showing previous activity"
        }
        return model.items.count == 30
            ? "Showing the first 30 matching entries. Narrow filters to see more." : "\(model.items.count) activities"
    }

    private func short(_ value: String) -> String { value.count > 25 ? String(value.prefix(22)) + "…" : value }
    private func branchName(_ ref: String) -> String { ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref }

    private func filterMenu<Value: Hashable>(
        title: String, icon: Ph, selection: Binding<Value>, choices: [(String, Value)]
    ) -> some View {
        DockMenu(outlined: true) {
            DockMenuChoices(selection: selection) {
                ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                    DockMenuOption(choice.0, value: choice.1)
                }
            }
        } label: {
            HStack(spacing: 6) {
                DockIcon(icon, size: 14, color: .dockMetadataText)
                Text(title).lineLimit(1)
                DockIcon(.caretDown, size: 10, color: .dockMetadataText)
            }
        }
    }

    private func activityRow(_ item: GitHubRepositoryActivity) -> some View {
        let summary = model.summaries[item.id]
        let url = item.webURL(in: model.repository)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Link(destination: url) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(summary?.title ?? "\(item.label) · \(item.branch)")
                            .dockFont(.body, weight: .semibold).lineLimit(2).multilineTextAlignment(.leading)
                        DockIcon(.arrowUpRight, size: 11, color: .dockMetadataText)
                    }
                }.buttonStyle(.dockHover)
                if ["force_push", "pr_merge", "merge_queue_merge"].contains(item.type) { badge(item) }
                Spacer(minLength: 0)
                DockMenu {
                    Button("View changes on GitHub") { InAppBrowser.open(url) }
                    DockCopyButton(
                        url.absoluteString, label: "Copy activity link", accessibilityLabel: "Copy activity link",
                        presentation: .text)
                    DockCopyButton(
                        item.hasAfter ? item.after : item.before, label: "Copy commit SHA",
                        accessibilityLabel: "Copy commit SHA", presentation: .text)
                    if summary?.error != nil {
                        Button("Retry commit details") { Task { await model.loadSummary(item, force: true) } }
                    }
                } label: {
                    DockIcon(.dotsThree, size: 16, color: .dockMetadataText).frame(width: 28, height: 28)
                }.accessibilityLabel("Activity actions")
            }
            HStack(alignment: .top, spacing: 8) {
                avatar(item)
                DockChipFlow(spacing: 6) {
                    Text(item.actor ?? "Unknown user").dockFont(.metadata, weight: .semibold)
                    Text(action(item, summary: summary)).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                    if item.type == "branch_deletion" {
                        DockMetadataPill(text: short(item.branch), compact: true).help(item.branch)
                    } else {
                        Link(
                            destination: model.repository.webURL.appendingPathComponent("tree").appendingPathComponent(
                                item.branch)
                        ) {
                            DockMetadataPill(text: short(item.branch), navigationIcon: .arrowUpRight, compact: true)
                        }.buttonStyle(.dockLink).help(item.branch)
                    }
                    Link(destination: url) {
                        DockCommitRange(
                            before: item.before, after: item.after,
                            hasBefore: item.hasBefore, hasAfter: item.hasAfter)
                    }.buttonStyle(.dockLink)
                    Text(HumanDateFormatting.relative(item.date)).dockFont(.metadata).foregroundStyle(
                        Color.dockMetadataText
                    )
                    .help(item.date.formatted())
                }
            }
            if let error = summary?.error {
                Text(
                    summary?.title != nil || summary?.commitCount != nil
                        ? "Some commit details couldn’t be refreshed." : "Commit details unavailable."
                ).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    .help(error)
            }
        }
        .dockPadding(.horizontal, 12).dockPadding(.vertical, 10).frame(
            maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    private func action(_ item: GitHubRepositoryActivity, summary: GitHubActivitySummary?) -> String {
        if let count = summary?.commitCount { return "pushed \(count) \(count == 1 ? "commit" : "commits") to" }
        return item.action
    }

    private func badge(_ item: GitHubRepositoryActivity) -> some View {
        let color = item.type == "force_push" ? Color.dockWarning : Color.dockMerged
        return Text(item.label).dockFont(.metadata, weight: .medium).foregroundStyle(color)
            .dockPadding(.horizontal, 6).dockPadding(.vertical, 2)
            .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: DockLayout.hairline))
    }

    private func avatar(_ item: GitHubRepositoryActivity) -> some View {
        AsyncImage(url: item.avatarURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                DockIcon(.user, size: 14, color: .dockMetadataText).frame(width: 22, height: 22).background(
                    Circle().fill(Color.dockSurface2))
            }
        }
        .frame(width: 22, height: 22).clipShape(Circle()).accessibilityHidden(true)
    }
}
