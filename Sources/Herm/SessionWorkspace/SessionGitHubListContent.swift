import SwiftUI

struct SessionGitHubListPresentation: Equatable {
    let isLoading: Bool
    let warning: String?

    init(scopeMatches: Bool, isInitialLoad: Bool, warning: String?) {
        isLoading = !scopeMatches || isInitialLoad
        self.warning = scopeMatches ? warning : nil
    }
}

struct SessionGitHubListContent<Rows: View>: View {
    let state: SessionGitHubListPresentation
    let loadingMessage: String
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        if let warning = state.warning {
            Text(warning)
                .dockFont(.metadata)
                .foregroundStyle(Color.dockWarning)
                .dockPadding(.horizontal, DockSpacing.inspectorInset)
                .dockPadding(.vertical, DockSpacing.control)
        }
        ScrollView {
            LazyVStack(spacing: 2) {
                if state.isLoading {
                    VStack(spacing: 12) {
                        DockLoadingIndicator().controlSize(.small)
                        Text(loadingMessage)
                            .dockFont(.body)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    .frame(maxWidth: .infinity)
                    .dockPadding(.vertical, 32)
                } else {
                    rows()
                }
            }
            .dockPadding(.horizontal, DockSpacing.inspectorInset)
            .dockPadding(.vertical, 6)
        }
    }
}
