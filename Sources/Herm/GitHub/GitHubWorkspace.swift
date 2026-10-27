import SwiftUI

enum GitHubWorkspaceSection: String, CaseIterable, Identifiable {
    case pullRequests
    case issues
    case repositories

    var id: Self { self }
    var title: String {
        switch self {
        case .pullRequests: "Pull requests"
        case .issues: "Issues"
        case .repositories: "Repositories"
        }
    }
    var icon: Ph {
        switch self {
        case .pullRequests: .gitPullRequest
        case .issues: .record
        case .repositories: .folder
        }
    }

    static func visible(showsGitHub: Bool) -> [Self] {
        showsGitHub ? allCases : []
    }

    func available(in sections: [Self]) -> Self? {
        sections.contains(self) ? self : sections.first
    }
}

/// Shared navigation around the existing PR and issue pages; their models retain browsing state and drafts.
struct GitHubWorkspace<Content: View>: View {
    @StateObject private var repositories = GitHubRepositoriesModel()
    @Binding var selection: GitHubWorkspaceSection
    @Environment(\.dockTitleRow) private var titleRow
    @ViewBuilder var content: () -> Content

    private var sections: [GitHubWorkspaceSection] {
        GitHubWorkspaceSection.allCases
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 960 {
                HStack(spacing: 0) {
                    navigation
                        .frame(width: 200)
                    Color.dockBorderLight.frame(width: DockLayout.hairline)
                    selectedContent
                        .environment(
                            \.dockTitleRow, titleRow.map { DockTitleRow(height: $0.height, leadingClearance: 0) }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    DockPageHeader(title: "GitHub", subtitle: "") {
                        DockMenuPicker(title: selection.title, selection: $selection) {
                            ForEach(sections) { section in
                                DockMenuOption(section.title, value: section)
                            }
                        }
                    }
                    selectedContent
                        .environment(\.dockTitleRow, nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color.dockCanvas)
    }

    @ViewBuilder private var selectedContent: some View {
        if selection == .repositories {
            GitHubRepositoriesView(model: repositories)
        } else {
            content()
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            DockPageHeader(title: "GitHub", subtitle: "")
            VStack(spacing: 2) {
                ForEach(sections) { section in
                    DockNavRow(
                        title: section.title, icon: section.icon, isSelected: selection == section,
                        style: DockThemePalette(theme: DockThemeRuntime.current)
                    ) {
                        selection = section
                    }
                }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .background(Color.dockSidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("GitHub navigation")
    }
}
