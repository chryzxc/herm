import SwiftUI

struct ReviewGuideView: View {
    @ObservedObject var coordinator: ReviewGuideCoordinator
    @ObservedObject var model: DockModel
    let currentIdentity: String
    let directory: String?
    /// The owning surface closes its presentation before navigating.
    var onOpenConversation: ((HermesSession) -> Void)? = nil
    @State private var reply: String?
    @State private var error: String?
    @State private var loading = false
    @State private var selected: ReviewGuideReference?
    @Environment(\.chatContextRouter) private var contextRouter
    @Environment(\.expandedReviewRouter) private var reviewRouter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            DockPageHeader(
                title: "Review guide",
                subtitle: coordinator.sourceIdentity == nil
                    ? "No captured guide"
                    : coordinator.sourceIdentity == currentIdentity
                        ? "Captured comparison" : "Source changed · captured comparison",
                onRefresh: coordinator.session == nil ? nil : { load() },
                isRefreshing: loading
            ) {
                Button("Close") { dismiss() }.buttonStyle(.dockCompact)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let reply {
                        GenerativeUIIntegration.renderReply(reply) { MarkdownMessageView(markdown: reply) }
                        let references = ReviewGuideReferences.valid(
                            in: GenerativeUIIntegration.plainText(reply), documents: coordinator.documents)
                        if !references.isEmpty {
                            DockSectionHeader(
                                title: "Captured references", style: DockThemePalette(theme: DockThemeRuntime.current))
                            ForEach(references) { reference in
                                Button("\(reference.path):\(reference.firstLine)–\(reference.lastLine)") {
                                    selected = reference
                                }.buttonStyle(.dockLink)
                            }
                        }
                    } else {
                        Text(
                            coordinator.session == nil
                                ? "Generate a guide from a captured comparison to read it here."
                                : loading
                                    ? "Loading the saved guide…"
                                    : "The guide has no saved reply yet. Refresh or open its conversation."
                        ).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    }
                    if let error { Text(error).dockFont(.body).foregroundStyle(Color.dockWarning) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Open review conversation") {
                    guard let session = coordinator.session else { return }
                    if let onOpenConversation {
                        onOpenConversation(session)
                    } else {
                        reviewRouter?.closeAll(restoreFocus: false)
                        model.resumeSession(session)
                        contextRouter?.onOpened(session.id)
                        dismiss()
                    }
                }
                .buttonStyle(.dockPrimary).disabled(coordinator.session == nil)
            }.padding(12)
        }.frame(minWidth: 700, idealWidth: 900, minHeight: 560, idealHeight: 760).background(Color.dockCanvas)
            .onAppear { load() }
            .onDisappear { GeneratedHTMLCoordinator.shared.close() }
            .sheet(item: $selected) { reference in
                if let document = coordinator.documents.first(where: { $0.path == reference.path }) {
                    SharedDiffView(
                        patch: document.patch, path: document.path, projectPath: directory, reveal: reference.match,
                        expandedPresentation: true, owningSession: coordinator.sourceSession
                    )
                    .frame(minWidth: 700, minHeight: 560)
                    .modifier(ReviewSheetContext())
                }
            }
    }
    private func load() {
        guard !loading, let session = coordinator.session else { return }
        loading = true
        error = nil
        let client = model.controlRPCClient
        Task {
            defer { loading = false }
            do {
                let loaded = try await HermesReviewGuideReplyService(client: client).load(session)
                guard coordinator.session?.id == session.id, model.controlRPCClient === client else { return }
                reply = loaded
            } catch { self.error = DockModel.safeUserDiagnostic(error.localizedDescription) }
        }
    }
}
