import SwiftUI

struct ReviewGuideView: View {
    @ObservedObject var coordinator: ReviewGuideCoordinator
    @ObservedObject var model: DockModel
    let currentIdentity: String
    let directory: String?
    /// The owning surface closes its presentation before navigating.
    var onOpenConversation: ((HermesSession) -> Void)? = nil
    @StateObject private var content = ReviewGuideReplyModel()
    @State private var refreshID = 0
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
                onRefresh: coordinator.session == nil ? nil : { refreshID += 1 },
                isRefreshing: coordinator.requesting || content.loading
            ) {
                Button("Close") { dismiss() }.buttonStyle(.dockCompact)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let reply = content.reply {
                        GenerativeUIIntegration.renderReply(reply) { MarkdownMessageView(markdown: reply) }
                        let references = ReviewGuideReferences.valid(
                            in: GenerativeUIIntegration.plainText(reply), documents: coordinator.documents)
                        if !references.isEmpty {
                            Divider().overlay(Color.dockBorderLight)
                            DisclosureGroup("Referenced code (\(references.count))") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(references) { reference in
                                        Button("\(reference.path):\(reference.firstLine)–\(reference.lastLine)") {
                                            selected = reference
                                        }
                                        .buttonStyle(.dockLink)
                                        .lineLimit(1).truncationMode(.middle)
                                        .help(reference.path)
                                    }
                                }.padding(.top, 8)
                            }.dockFont(.body)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            if coordinator.requesting
                                || coordinator.session != nil && content.error == nil && coordinator.requestError == nil
                            {
                                ProgressView().controlSize(.small)
                            }
                            Text(
                                coordinator.requestError != nil
                                    ? "Review request needs attention"
                                    : coordinator.requesting
                                        ? "Starting review conversation…"
                                        : coordinator.session != nil
                                            ? "Waiting for the review guide" : "No review guide yet"
                            )
                            .dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
                            Text(
                                coordinator.requestError
                                    ?? (coordinator.session != nil
                                        ? "Saved replies appear automatically. Open the conversation to follow activity or respond to the reviewer."
                                        : coordinator.message ?? "Generate a guide from the comparison to read it here.")
                            )
                            .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                        }
                        .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
                    }
                    if let error = content.error {
                        Text("Couldn’t refresh the guide · " + error).dockFont(.body).foregroundStyle(Color.dockWarning)
                    }
                }.padding(24).frame(maxWidth: 800, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            Divider().overlay(Color.dockBorderLight)
            HStack(spacing: 12) {
                Text(
                    coordinator.session.map { "Reviewer · " + ($0.profileID ?? "Default bot") }
                        ?? "Separate review conversation"
                )
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText).lineLimit(1)
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
            .task(id: trackingIdentity) {
                content.reset(session: coordinator.session)
                guard !coordinator.requesting, coordinator.requestError == nil,
                    let session = coordinator.session
                else { return }
                let client = model.controlRPCClient
                while !Task.isCancelled {
                    await content.refresh(session: session, client: client)
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
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
    private var trackingIdentity: String {
        let session = coordinator.session
        return WorkspaceIdentity.session(profileID: session?.profileID, sessionID: session?.id)
            + ":\(ObjectIdentifier(model.controlRPCClient)):\(coordinator.requesting):\(refreshID)"
    }
}
