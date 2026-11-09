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
}

/// Shared navigation around the existing PR and issue pages; their models retain browsing state and drafts.
struct GitHubWorkspace<Content: View>: View {
    @ObservedObject var repositories: GitHubRepositoriesModel
    @Binding var selection: GitHubWorkspaceSection
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            selectedContent
                .environment(\.gitHubSectionSelection, $selection)
                .environment(\.gitHubCompactNavigation, geometry.size.width < 1000)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.dockCanvas)
        }
    }

    @ViewBuilder private var selectedContent: some View {
        if selection == .repositories {
            GitHubRepositoriesView(model: repositories)
        } else {
            content()
        }
    }

}

extension EnvironmentValues {
    @Entry var gitHubSectionSelection: Binding<GitHubWorkspaceSection>? = nil
    @Entry var gitHubCompactNavigation = false
}

struct GitHubWorkspaceNavigation: View {
    @Environment(\.gitHubSectionSelection) private var selection
    @Environment(\.gitHubCompactNavigation) private var compact

    var body: some View {
        if let selection {
            Group {
                if compact {
                    DockMenuPicker(title: selection.wrappedValue.title, selection: selection) {
                        ForEach(GitHubWorkspaceSection.allCases) { section in
                            DockMenuOption(section.title, value: section)
                        }
                    }
                } else {
                    DockTabBar(options: GitHubWorkspaceSection.allCases, selection: selection, title: { $0.title })
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("GitHub navigation")
        }
    }
}
