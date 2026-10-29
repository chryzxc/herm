import SwiftUI

struct SessionPullRequestPreview: View {
    let reference: GitHubItemReference
    let onOpenChat: (PullRequestRecord) -> Void
    @StateObject private var center: PullRequestCenterModel
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var reloadID = 0

    init(
        reference: GitHubItemReference, onOpenChat: @escaping (PullRequestRecord) -> Void,
        center: PullRequestCenterModel? = nil
    ) {
        self.reference = reference
        self.onOpenChat = onOpenChat
        _center = StateObject(wrappedValue: center ?? PullRequestCenterModel(details: .shared))
    }

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading pull request…")
                }
            } else if let loadError {
                VStack(spacing: 8) {
                    Text("Pull request unavailable.").dockFont(.body, weight: .semibold)
                    Text(loadError).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    Button("Retry") { reloadID += 1 }.buttonStyle(.dockPrimary)
                }
            } else {
                PullRequestDetailView(center: center, onOpenChat: onOpenChat, isInspector: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: reloadID) {
            loadError = nil
            isLoading = true
            let opened = await center.open(reference)
            guard !Task.isCancelled else { return }
            isLoading = false
            if !opened {
                loadError = HermesDiagnosticsService.safeSummary(center.errorMessage ?? "Pull request unavailable")
            }
        }
        .onDisappear { center.cancelLoads() }
    }
}
