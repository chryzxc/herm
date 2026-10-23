import SwiftUI

struct LocalReviewWorkspace: View {
    var owningSession: HermesSession?
    var closeAction: (() -> Void)?
    var onOpenConversation: ((HermesSession) -> Void)?
    let path: String
    private let guideOwner: QuickDestination
    @ObservedObject var model: DockModel
    @StateObject private var review: LocalReviewModel
    @State private var scope = RepositoryComparison.Scope.working
    @State private var reference = "HEAD"
    @State private var ignoreWhitespace = false
    @State private var query = ""
    @State private var search = ""
    @State private var searchIndex = 0
    @FocusState private var searchFocused: Bool
    @State private var references: [String] = []
    @State private var navigatorWidth: CGFloat = 280
    @State private var restoring = true
    private var presentationIdentity: String {
        WorkspaceIdentity.session(profileID: guideOwner.profileID, sessionID: guideOwner.sessionID) + ":review:" + path
    }
    @State private var selected: String?
    @State private var requestID = 0
    @State private var readingGuide = false
    @StateObject private var guide = ReviewGuideCoordinator()
    @Environment(\.chatContextRouter) private var contextRouter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.expandedReviewRouter) private var workspaceRouter
    init(
        owningSession: HermesSession? = nil, closeAction: (() -> Void)? = nil,
        onOpenConversation: ((HermesSession) -> Void)? = nil, path: String, model: DockModel
    ) {
        let capturedSession = owningSession ?? model.workflowSession
        self.owningSession = capturedSession
        guideOwner = ReviewGuideCoordinator.ownerDestination(
            session: capturedSession, fallbackProfileID: model.profileScopeID)
        self.closeAction = closeAction
        self.onOpenConversation = onOpenConversation
        self.path = path
        self.model = model
        let identity = WorkspaceIdentity.session(
            profileID: guideOwner.profileID, sessionID: guideOwner.sessionID)
        _review = StateObject(
            wrappedValue: LocalReviewModel(
                revisionNotes: ReviewDraftStore.shared.notes(key: identity + ":repository:" + path)))
    }
    private var files: [String] {
        (review.comparison?.files ?? []).filter {
            query.isEmpty || $0.localizedCaseInsensitiveContains(query)
                || review.patches[$0]?.text.localizedCaseInsensitiveContains(query) == true
        }
    }
    private var matches: [DiffSearchMatch] { DiffSearch.matches(query: search, patches: review.patches) }
    private var activeMatch: DiffSearchMatch? { matches.indices.contains(searchIndex) ? matches[searchIndex] : nil }
    private func moveMatch(_ delta: Int) {
        guard !matches.isEmpty else { return }
        searchIndex = (searchIndex + delta + matches.count) % matches.count
        selected = matches[searchIndex].path
    }
    var body: some View {
        DockExpandedPage(
            title: "Review changes", subtitle: "Local Git comparison", onRefresh: { requestID += 1 },
            isRefreshing: review.loading, close: { if let closeAction { closeAction() } else { dismiss() } }
        ) {
            HStack {
                Picker("Comparison", selection: $scope) {
                    ForEach(RepositoryComparison.Scope.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
                if scope == .branch || scope == .commit {
                    TextField("Local Git reference", text: $reference).textFieldStyle(.dockGlass).onSubmit {
                        requestID += 1
                    }
                    Menu("Choose reference") {
                        ForEach(references, id: \.self) { value in
                            Button(value) {
                                reference = value
                                requestID += 1
                            }
                        }
                        if references.isEmpty { Text("No local references available") }
                    }.buttonStyle(.dockCompact)
                }
                Toggle("Ignore whitespace", isOn: $ignoreWhitespace).toggleStyle(.dockSwitch)
                TextField("Filter files or loaded changes", text: $query).textFieldStyle(.dockGlass)
            }.dockFont(.body).padding(.horizontal, 16).padding(.bottom, 12)
            HStack {
                TextField("Find in loaded comparison", text: $search).textFieldStyle(.dockGlass).focused($searchFocused)
                    .onSubmit { moveMatch(1) }
                Text(
                    "\(matches.isEmpty ? 0 : searchIndex + 1) / \(matches.count)" + (matches.count >= 10_000 ? "+" : "")
                ).dockFont(.metadata)
                Button("Previous") { moveMatch(-1) }.buttonStyle(.dockCompact).disabled(matches.isEmpty)
                Button("Next") { moveMatch(1) }.buttonStyle(.dockCompact).disabled(matches.isEmpty)
            }.padding(.horizontal, 16).padding(.bottom, 10)
            Divider().overlay(Color.dockBorderLight)
            FullscreenPanelSplitView(
                leading: List(files, id: \.self, selection: $selected) { file in
                    Text(file).dockFont(.body).tag(file)
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden).background(Color.dockCanvas).frame(
                    minWidth: 220, idealWidth: 280, maxWidth: 360),
                trailing: ScrollView {
                    if let selected, let diff = review.patches[selected] {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(selected).dockFont(.body, weight: .semibold).textSelection(.enabled)
                            SharedDiffView(
                                patch: diff.text, path: selected,
                                contextLoader: { lines in
                                    try await RepositoryComparisonService.expandedPatch(
                                        path: path, file: selected,
                                        arguments: review.comparison?.arguments ?? ["diff", "--no-ext-diff"],
                                        original: diff.text, lines: lines,
                                        renameSource: review.comparison?.renameSources[selected])
                                }, projectPath: path, reveal: activeMatch?.path == selected ? activeMatch : nil,
                                owningSession: owningSession,
                                comparison: review.comparison.map {
                                    DiffComparisonIdentity.local(path: path, comparison: $0)
                                }, revisionNotes: review.revisionNotes)
                            if diff.isTruncated {
                                Text("Partial diff · display limit reached").foregroundStyle(Color.dockWarning)
                            }
                        }.padding(12)
                    } else {
                        Text(
                            review.loading
                                ? "Loading changes…"
                                : files.isEmpty ? "No changes in this comparison." : "Choose a changed file."
                        )
                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText).padding(20)
                    }
                }.frame(minWidth: 400), leadingFraction: nil, initialLeadingWidth: navigatorWidth,
                minimumLeadingWidth: 220,
                maximumLeadingWidth: 360, minimumTrailingWidth: 400, leadingWidth: $navigatorWidth
            )
            HStack {
                Text(
                    review.error.map { (review.stale ? "Stale comparison · " : "") + $0 }
                        ?? (review.partial
                            ? "Partial coverage · search includes loaded content only"
                            : "\(review.patches.count) files loaded")
                )
                .dockFont(.body).foregroundStyle(
                    review.error == nil ? Color.dockSecondaryText : Color.dockWarning
                ).lineLimit(2)
                Spacer()
                if guide.session != nil || guide.requesting { Button("Read guide") { readingGuide = true }.buttonStyle(.dockCompact) }
                if let session = guide.session {
                    Button("Open review conversation") {
                        openConversation(session)
                    }.buttonStyle(.dockCompact)
                }
                ReviewGuideGenerateAction(requesting: guide.requesting) { requestGuide(reviewerProfileID: $0) }.disabled(
                        review.loading || guide.requesting || guide.uncertain || review.patches.isEmpty
                            || review.error != nil)
            }.padding(12)
            if let source = guide.sourceIdentity, source != review.comparison?.identity {
                Text("Review guide source changed · generate a new guide after reviewing this comparison.")
                    .dockFont(.body).foregroundStyle(Color.dockWarning).padding(.horizontal, 12)
            }
            if let message = guide.message {
                Text(message).dockFont(.body).foregroundStyle(Color.dockSecondaryText).padding(
                    .horizontal, 12
                ).padding(.bottom, 8)
            }
        }.sheet(isPresented: $readingGuide) {
            ReviewGuideView(
                coordinator: guide, model: model, currentIdentity: review.comparison?.identity ?? "", directory: path,
                onOpenConversation: openConversation
            ).modifier(ReviewSheetContext())
        }
        .background(Color.dockCanvas)
        .frame(minWidth: 800, idealWidth: 1100, minHeight: 560, idealHeight: 760)
        .background {
            Button("Find comparison") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
        .task(id: presentationIdentity) {
            restoring = true
            if let saved = WorkspacePresentationStore.shared.loadReferences(
                ReviewWorkspacePresentation.self, identity: presentationIdentity)
            {
                scope = RepositoryComparison.Scope(rawValue: saved.scope) ?? .working
                reference = saved.reference
                selected = saved.file.flatMap { RepositoryService.isSafeRelativePath($0) ? $0 : nil }
                navigatorWidth = CGFloat(min(360, max(220, saved.navigatorWidth)))
            }
            restoring = false
            references = await RepositoryComparisonService.references(path: path)
        }
        .onChange(of: selected) { _, _ in savePresentation() }
        .onChange(of: navigatorWidth) { _, _ in savePresentation() }
        .onChange(of: scope) { _, _ in savePresentation() }
        .onChange(of: reference) { _, _ in savePresentation() }
        .onChange(of: search) { _, _ in
            searchIndex = 0
            if let first = matches.first {
                selected = first.path
                query = ""
            }
        }
        .task(id: "\(path):\(scope.rawValue):\(ignoreWhitespace):\(requestID)") {
            await review.load(path: path, scope: scope, reference: reference, ignoreWhitespace: ignoreWhitespace)
            if selected == nil || !files.contains(selected ?? "") { selected = files.first }
        }
    }
    private func openConversation(_ session: HermesSession) {
        if let onOpenConversation {
            onOpenConversation(session)
            return
        }
        if let workspaceRouter {
            workspaceRouter.closeAll(restoreFocus: false)
        } else {
            closeAction?()
            if closeAction == nil { dismiss() }
        }
        model.resumeSession(session)
        contextRouter?.onOpened(session.id)
    }

    private func savePresentation() {
        guard !restoring else { return }
        WorkspacePresentationStore.shared.saveReferences(
            ReviewWorkspacePresentation(
                scope: scope.rawValue, reference: reference,
                file: selected, navigatorWidth: Double(navigatorWidth)), identity: presentationIdentity)
    }
    private func requestGuide(reviewerProfileID: String?) {
        guard let comparison = review.comparison else { return }
        guide.start(
            model: model, owner: guideOwner, reviewerProfileID: reviewerProfileID, directory: path, identity: comparison.identity,
            documents: review.patches.keys.sorted().compactMap {
                review.patches[$0].map { DiffDocument(path: $0.path, patch: $0.text) }
            }, partial: review.partial)
        readingGuide = true
    }
}
