import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ArtifactsPresentationMode {
    case page
    case inspector
}

struct ArtifactSelectionPresentation {
    static func reconciledID(current: String?, visibleIDs: [String]) -> String? {
        if let current, visibleIDs.contains(current) { return current }
        return visibleIDs.first
    }
}

struct ArtifactActionPresentation: Equatable {
    let canOpen: Bool
    let canCopy: Bool
    let canRevealInFinder: Bool
    let canOpenSession: Bool

    static func make(record: ArtifactRecord, hasSourceSession: Bool) -> Self {
        let isLocalFile =
            record.kind == .file
            && !record.value.hasPrefix("http://")
            && !record.value.hasPrefix("https://")
            && !record.value.hasPrefix("data:")
        return Self(
            canOpen: !record.value.isEmpty,
            canCopy: !record.value.isEmpty,
            canRevealInFinder: isLocalFile,
            canOpenSession: hasSourceSession
        )
    }
}

/// Cross-session generated-output library.
///
/// This is intentionally separate from the Markdown plan inspector: Hermes
/// Desktop treats artifacts as an output archive with media previews, filters,
/// provenance, and OS actions rather than as a document editor.
struct ArtifactsInspectorView: View {
    @ObservedObject var model: DockModel
    let presentation: ArtifactsPresentationMode
    let sessionScope: ProfileScopedID?
    let contentHorizontalPadding: CGFloat
    /// Hosts that own navigation route here so opening a source session also
    /// leaves the Artifacts surface; without it the session only resumes.
    let onOpenSession: ((HermesSession) -> Void)?

    init(
        model: DockModel,
        presentation: ArtifactsPresentationMode = .inspector,
        sessionScope: ProfileScopedID? = nil,
        onOpenSession: ((HermesSession) -> Void)? = nil,
        contentHorizontalPadding: CGFloat = 16
    ) {
        self.model = model
        self.presentation = presentation
        self.sessionScope = sessionScope
        self.contentHorizontalPadding = contentHorizontalPadding
        self.onOpenSession = onOpenSession
    }

    @ObservedObject private var savedTools = RichArtifactStateStore.shared
    @State private var selectedVersionID: String?
    @State private var comparingVersions = false
    @State private var recordIndex = RichArtifactIndex.Snapshot([])
    private var records: [ArtifactRecord] {
        get { recordIndex.records }
        nonmutating set { recordIndex = RichArtifactIndex.Snapshot(newValue) }
    }
    @State private var presentationCache = ArtifactBrowserProjectionCache()
    @State private var indexedSessions: [HermesSession] = []
    @State private var artifactCache: [ProfileScopedID: ArtifactIndexLoader.CachedSession] = [:]
    @State private var query = ""
    @State private var filter: ArtifactFilter = .all
    @State private var imagePage = 1
    @State private var filePage = 1
    @State private var isLoading = false
    @State private var refreshID = 0
    @State private var automaticRefreshID = 0
    @State private var completedManualRefreshID = 0
    @State private var completedAutomaticRefreshID = 0
    @State private var refreshGeneration = UUID()
    @State private var errorMessage: String?
    @State private var failedSessionCount = 0
    @State private var selectedArtifactID: String?
    @State private var showsNarrowDetail = false
    @State private var textPreview: ArtifactTextPreview?
    @FocusState private var isBrowserFocused: Bool

    private let imagesPerPage = 24
    private let filesPerPage = 100

    private enum ArtifactFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case image = "Images"
        case file = "Files"
        case link = "Links"
        case interactive = "Interactive"
        case saved = "Saved"

        var id: String { rawValue }
        var icon: Ph {
            switch self {
            case .all: .squaresFour
            case .image: .image
            case .file: .file
            case .link: .link
            case .interactive: .squaresFour
            case .saved: .pushPin
            }
        }
        var showsIcon: Bool { self != .all }
    }

    private var projection: ArtifactBrowserProjectionCache.Projection {
        let kind: ArtifactKind? =
            switch filter {
            case .all, .saved: nil
            case .image: .image
            case .file: .file
            case .link: .link
            case .interactive: .interactive
            }
        return presentationCache.project(
            index: recordIndex, query: query, kind: kind, savedOnly: filter == .saved,
            bookmarks: savedTools.bookmarks, resources: savedTools.resourceBookmarks,
            isSaved: savedTools.isSaved)
    }

    private var visibleRecords: [ArtifactRecord] { projection.visible }

    private var visibleImages: [ArtifactRecord] {
        visibleRecords.filter { $0.kind == .image }
    }

    private var visibleFiles: [ArtifactRecord] {
        visibleRecords.filter { $0.kind != .image && (presentation == .page || $0.kind != .interactive) }
    }

    private var imagePageCount: Int {
        max(1, Int(ceil(Double(visibleImages.count) / Double(imagesPerPage))))
    }

    private var filePageCount: Int {
        max(1, Int(ceil(Double(visibleFiles.count) / Double(filesPerPage))))
    }

    private var pagedImages: [ArtifactRecord] {
        let page = min(imagePage, imagePageCount)
        let start = (page - 1) * imagesPerPage
        return Array(visibleImages.dropFirst(start).prefix(imagesPerPage))
    }

    private var pagedFiles: [ArtifactRecord] {
        let page = min(filePage, filePageCount)
        let start = (page - 1) * filesPerPage
        return Array(visibleFiles.dropFirst(start).prefix(filesPerPage))
    }

    var body: some View {
        Group {
            if presentation == .page {
                pageBody
            } else {
                inspectorBody
            }
        }
        .task(
            id:
                "\(sessionScope.map { "\($0.profileID ?? "default"):\($0.resourceID)" } ?? "global"):\(refreshID):\(automaticRefreshID)"
        ) {
            await refresh(force: refreshID != completedManualRefreshID)
        }
        .onChange(of: model.isSending) { _, sending in if !sending { automaticRefreshID += 1 } }
        .onChange(of: query) { resetPages() }
        .onChange(of: filter) { resetPages() }
        .onChange(of: visibleRecords.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: selectedArtifactID) { _, _ in selectedVersionID = nil }
        .dockSheet(isPresented: $comparingVersions) {
            if let current = selectedRecord, let generated = current.generated,
                let previous = recordIndex.versions(of: current)
                    .first(where: {
                        $0.timestamp < current.timestamp
                            || ($0.generated?.reference.rowID ?? 0) < (generated.reference.rowID ?? 0)
                    })?.generated
            {
                RichRevisionComparisonView(previous: previous, current: generated, close: { comparingVersions = false })
                    .frame(minWidth: 640, minHeight: 500).modifier(ReviewSheetContext())
            }
        }
    }

    private var inspectorBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.dockBorderLight)
            content
        }
        .background(Color.dockCanvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ARTIFACTS")
                        .dockFont(.compactStatus, weight: .bold, design: .monospaced)
                        .foregroundStyle(Color.dockMetadataText)
                        .tracking(0.8)
                    Text("Generated outputs")
                        .dockFont(.metric, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                    Text(summaryText)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockSecondaryText)
                }
                Spacer(minLength: 8)
                Button {
                    refreshID += 1
                } label: {
                    DockIcon(isLoading ? .hourglass : .arrowsClockwise)
                        .dockFont(.metadata, weight: .semibold)
                }
                .buttonStyle(.dockHover)
                .foregroundStyle(Color.dockAccent)
                .disabled(isLoading)
                .accessibilityLabel("Refresh artifacts")
            }

            TextField(
                "", text: $query,
                prompt: Text("Search by name, path, URL, or session…").foregroundColor(Color.dockMetadataText)
            )
            .textFieldStyle(.dockGlass)
            .accessibilityLabel("Search artifacts")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ArtifactFilter.allCases) { item in
                        filterButton(item)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var pageBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            DockPageHeader(
                title: "Artifacts",
                subtitle: pageSummaryText,
                onRefresh: { refreshID += 1 },
                isRefreshing: isLoading,
                horizontalPadding: contentHorizontalPadding
            )
            pageToolbar
            pageContent
        }
        .background(Color.dockCanvas)
    }

    private var pageToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                searchField
                    .frame(maxWidth: 360)
                filterBar
                Spacer(minLength: 0)
            }
            .frame(minWidth: 560)
            VStack(alignment: .leading, spacing: 8) {
                searchField
                ViewThatFits(in: .horizontal) {
                    filterBar
                    compactFilterMenu
                }
            }
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius)
        return HStack(spacing: 6) {
            DockIcon(.magnifyingGlass, size: 13, color: .dockMetadataText)
            TextField("", text: $query, prompt: Text("Search artifacts").foregroundColor(Color.dockMetadataText))
                .textFieldStyle(.plain)
                .dockFont(.body)
                .foregroundStyle(Color.dockPrimaryText)
                .accessibilityLabel("Search artifacts by name, path, URL, or session")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    DockIcon(.xCircle, size: 13, color: .dockMetadataText)
                }
                .buttonStyle(.dockHover)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            shape.dockSurfaceFill(Color.dockSurface2, stroke: Color.dockBorderLight, lineWidth: DockLayout.outline))
    }

    @ViewBuilder
    private var pageContent: some View {
        if let errorMessage, records.isEmpty, !isLoading {
            pageState(title: "Artifacts unavailable", detail: errorMessage, icon: .warning, actionTitle: "Retry") {
                refreshID += 1
            }
        } else if records.isEmpty && isLoading {
            pageState(
                title: "Indexing artifacts", detail: "Reading generated outputs from Hermes sessions…",
                icon: .hourglass, actionTitle: nil, action: nil)
        } else if visibleRecords.isEmpty {
            let filtered = !query.isEmpty || filter != .all
            pageState(
                title: filtered ? "No matching artifacts" : "No generated outputs yet",
                detail: filtered
                    ? "Try another search or clear the current filter."
                    : "Files Hermes writes, images it produces, and links it shares will appear here.",
                icon: .squaresFour,
                actionTitle: filtered ? "Clear filters" : nil
            ) {
                query = ""
                filter = .all
            }
        } else {
            // A fixed browser column avoids HSplitView's native divider and
            // scroller chrome, which clashed with the themed surfaces. Below
            // 700pt only one of browser/detail shows at a time.
            GeometryReader { geo in
                if geo.size.width >= 700 {
                    HStack(spacing: 0) {
                        artifactBrowser
                            .frame(width: 320)
                        Color.dockBorderLight.frame(width: DockLayout.hairline)
                        artifactDetail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if showsNarrowDetail {
                    VStack(spacing: 0) {
                        HStack {
                            Button {
                                showsNarrowDetail = false
                            } label: {
                                DockIconLabel("BACK", icon: .caretLeft)
                            }
                            .buttonStyle(.dockCompact)
                            .dockFont(.metadata, weight: .semibold)
                            .foregroundStyle(Color.dockAccent)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        Divider().overlay(Color.dockBorderLight)
                        artifactDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    artifactBrowser.frame(maxWidth: .infinity)
                }
            }
            .overlay(alignment: .top) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
        }
    }

    private var artifactBrowser: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(projection.sections) { section in
                        Section {
                            ForEach(section.records) { record in
                                artifactBrowserRow(record)
                                    .id(record.id)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Text(section.title.uppercased())
                                    .tracking(0.8)
                                Text("\(section.records.count)")
                                    .foregroundStyle(Color.dockMetadataText)
                                Spacer(minLength: 0)
                            }
                            .dockFont(.sectionLabel)
                            .foregroundStyle(Color.dockSectionText)
                            .padding(.horizontal, 10)
                            .padding(.top, 12)
                            .padding(.bottom, 6)
                            .background(Color.dockCanvas)
                            .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
            .focusable()
            .focused($isBrowserFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) {
                moveSelection(by: 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                moveSelection(by: -1)
                return .handled
            }
            .onKeyPress(.return) {
                if let selectedRecord {
                    if selectedRecord.kind == .interactive {
                        showsNarrowDetail = true
                    } else {
                        open(selectedRecord.value)
                    }
                }
                return .handled
            }
            .onChange(of: selectedArtifactID) { _, id in
                guard let id else { return }
                withAnimation(.dockEase(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
        .background(Color.dockCanvas)
    }

    private func moveSelection(by offset: Int) {
        let ids = visibleRecords.map(\.id)
        guard !ids.isEmpty else { return }
        let current = selectedArtifactID.flatMap { ids.firstIndex(of: $0) } ?? -offset
        selectedArtifactID = ids[min(max(current + offset, 0), ids.count - 1)]
    }

    private func artifactBrowserRow(_ record: ArtifactRecord) -> some View {
        let isSelected = record.id == selectedArtifactID
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius - 1)
        return HStack(spacing: 10) {
            artifactRowIcon(record)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.label)
                    .dockFont(.rowTitle)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(record.sessionTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("·")
                    Text(record.timestamp, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .monospacedDigit()
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .dockFont(.compactStatus, weight: .regular)
                .foregroundStyle(Color.dockMetadataText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockSelectionBackground(shape, active: isSelected, fill: Color.dockAccent.opacity(0.14), allowsInvert: false)
        .overlay(shape.stroke(isSelected ? Color.dockAccent.opacity(0.35) : Color.clear, lineWidth: DockLayout.outline))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(record.value) }
        .onTapGesture {
            selectedArtifactID = record.id
            isBrowserFocused = true
            showsNarrowDetail = true
        }
        .contextMenu { artifactContextActions(record) }
        .help(record.value)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.label), \(record.origin.rawValue.lowercased()) in \(record.sessionTitle)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func originBadge(_ origin: ArtifactOrigin) -> some View {
        Text(origin.rawValue)
            .dockFont(.metadata, weight: .medium)
            .foregroundStyle(Color.dockSecondaryText)
    }

    @ViewBuilder
    private func artifactRowIcon(_ record: ArtifactRecord, size: CGFloat = 32) -> some View {
        if record.kind == .image {
            imagePreview(for: record, compact: true)
                .frame(width: size, height: size)
                .clipShape(DockThemeShape(cornerRadius: DockLayout.controlRadius - 2))
        } else if record.kind == .file {
            systemFileIcon(record)
                .frame(width: size, height: size)
        } else {
            DockIcon(record.kind == .interactive ? .squaresFour : .link)
                .foregroundStyle(Color.dockSecondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    DockThemeShape(cornerRadius: DockLayout.controlRadius - 2).dockSurfaceFill(
                        Color.dockSurface2)
                )
                .frame(width: size, height: size)
        }
    }

    /// Language-specific icon (TypeScript, Python, …) resolved by name, so
    /// moved or deleted files still get the right icon.
    private func systemFileIcon(_ record: ArtifactRecord) -> some View {
        let image =
            ArtifactFileIcon.image(for: record.label)
            ?? NSWorkspace.shared.icon(
                for: UTType(filenameExtension: URL(fileURLWithPath: record.label).pathExtension) ?? .data)
        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                DockThemeShape(cornerRadius: DockLayout.controlRadius - 2).dockSurfaceFill(
                    Color.dockSurface2)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artifactDetail: some View {
        if let record = selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHeader(record)
                    detailActions(record)
                    detailPreview(record)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(24)
            }
            .background(Color.dockCanvas)
            .task(id: record.id) { await loadTextPreview(for: record) }
        } else {
            pageState(
                title: "Select an artifact", detail: "Choose an output to preview its contents and actions.",
                icon: .fileMagnifyingGlass, actionTitle: nil, action: nil)
        }
    }

    private var selectedRecord: ArtifactRecord? {
        records.first { $0.id == (selectedVersionID ?? selectedArtifactID) }
    }

    private func detailHeader(_ record: ArtifactRecord) -> some View {
        HStack(alignment: .top, spacing: 14) {
            artifactRowIcon(record)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(record.label)
                    .dockFont(size: 17, weight: .semibold, design: DockThemeStyle.current.fontDesign)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    originBadge(record.origin)
                    Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(record.location)
                        .dockFont(.machineMetadata)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(record.value)
                }
                .dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText)
                if let session = sourceSession(for: record) {
                    Button {
                        openSession(session)
                    } label: {
                        HStack(spacing: 5) {
                            DockIcon(.chatCircle, size: 12, color: .dockAccent)
                            Text(record.sessionTitle)
                                .lineLimit(1)
                            DockIcon(.arrowRight, size: 10, color: .dockAccent)
                        }
                        .dockFont(.control)
                        .foregroundStyle(Color.dockAccent)
                    }
                    .buttonStyle(.dockLink)
                    .help("Open the session that produced this artifact")
                } else {
                    DockIconLabel(record.sessionTitle, icon: .chatCircle)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockSecondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private func detailPreview(_ record: ArtifactRecord) -> some View {
        if let generated = record.generated {
            VStack(alignment: .leading, spacing: 12) {
                let versions = recordIndex.versions(of: records.first { $0.id == selectedArtifactID } ?? record)
                if versions.count > 1 {
                    Picker(
                        "Version",
                        selection: Binding(
                            get: { selectedVersionID ?? selectedArtifactID ?? record.id },
                            set: { selectedVersionID = $0 })
                    ) {
                        ForEach(versions) { item in Text(item.timestamp.formatted()).tag(item.id) }
                    }.pickerStyle(.menu)
                    Button("Compare with previous version") { comparingVersions = true }.buttonStyle(.dockCompact)
                        .disabled(record.id == versions.last?.id)
                }
                RichArtifactPreview(model: model, generated: generated)
            }
        } else if record.unavailableBookmark != nil {
            previewPlaceholder(
                icon: .warning, title: "Source unavailable",
                detail:
                    "Refresh to retry, or remove the saved reference. Export a tool to keep an independent document.")
        } else if record.kind == .image {
            imagePreview(for: record)
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(minHeight: 260, maxHeight: 520)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).dockSurfaceFill(
                        Color.dockSurface2))
        } else if let textPreview, textPreview.id == record.id {
            switch textPreview.content {
            case .text(let text, let truncated):
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if isMarkdown(record) {
                            MarkdownMessageView(markdown: text, cacheKey: "artifact:\(record.id)")
                        } else {
                            Text(text)
                                .dockFont(.metadata, weight: .regular, design: .monospaced)
                                .foregroundStyle(Color.dockPrimaryText)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    if truncated {
                        Divider().overlay(Color.dockBorderLight)
                        Text("Preview truncated — open the file to see the rest.")
                            .dockFont(.compactStatus, weight: .regular)
                            .foregroundStyle(Color.dockMetadataText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).dockSurfaceFill(
                        Color.dockSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).stroke(
                        Color.dockBorderLight))
            case .missing:
                previewPlaceholder(
                    icon: .warning, title: "File no longer exists",
                    detail: "It was moved or deleted after the session produced it.")
            case .binary:
                previewPlaceholder(
                    icon: fileIcon(for: record.label), title: "No inline preview",
                    detail: "Open it with its default app.")
            }
        } else if record.kind == .link {
            previewPlaceholder(icon: .link, title: record.location, detail: record.value)
        } else {
            previewPlaceholder(icon: fileIcon(for: record.label), title: "Loading preview…", detail: nil)
        }
    }

    private func isMarkdown(_ record: ArtifactRecord) -> Bool {
        ["md", "markdown"].contains(URL(fileURLWithPath: record.label).pathExtension.lowercased())
    }

    private func previewPlaceholder(icon: Ph, title: String, detail: String?) -> some View {
        VStack(spacing: 8) {
            DockIcon(icon)
                .foregroundStyle(Color.dockSecondaryText)
            Text(title)
                .dockFont(.body, weight: .medium)
                .foregroundStyle(Color.dockPrimaryText)
            if let detail {
                Text(detail)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockSecondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).dockSurfaceFill(
                Color.dockSurface2))
    }

    private func detailActions(_ record: ArtifactRecord) -> some View {
        HStack(spacing: 8) {
            if let bookmark = record.unavailableBookmark {
                Button("Remove saved reference") {
                    savedTools.toggle(bookmark)
                    refreshID += 1
                }.buttonStyle(.dockSecondary)
            } else if record.generated == nil {
                Button(savedTools.isSaved(record) ? "Unsave" : "Save") { savedTools.toggleResource(record) }
                    .buttonStyle(.dockCompact)
                Button {
                    open(record.value)
                } label: {
                    DockIconLabel(record.kind == .link ? "Open link" : "Open", icon: .arrowSquareOut)
                }
                .buttonStyle(.dockPrimary)
                DockCopyButton(
                    record.value,
                    label: "Copy \(record.kind == .link ? "link" : "path")",
                    accessibilityLabel: "Copy \(record.kind == .link ? "link" : "path")",
                    presentation: .iconAndText,
                    iconSize: 12,
                    color: .dockPrimaryText
                )
                .buttonStyle(.dockSecondary)
                if isLocalFile(record) {
                    Button {
                        reveal(record.value)
                    } label: {
                        DockIconLabel("Reveal in Finder", icon: .folderOpen)
                    }
                    .buttonStyle(.dockSecondary)
                }
            }
            if let session = sourceSession(for: record) {
                Button {
                    openSession(session)
                } label: {
                    DockIconLabel("Open session", icon: .chatCircle)
                }
                .buttonStyle(.dockSecondary)
            }
        }
        .controlSize(.small)
    }

    private func sourceSession(for record: ArtifactRecord) -> HermesSession? {
        indexedSessions.first { $0.id == record.sessionID && $0.profileID == record.profileID }
    }

    private func openSession(_ session: HermesSession) {
        if let onOpenSession {
            onOpenSession(session)
        } else {
            model.resumeSession(session)
        }
    }

    @ViewBuilder
    private func artifactContextActions(_ record: ArtifactRecord) -> some View {
        if record.kind != .interactive {
            Button(savedTools.isSaved(record) ? "Unsave" : "Save") { savedTools.toggleResource(record) }
            Button("Open") { open(record.value) }
            Button("Copy \(record.kind == .link ? "Link" : "Path")") { copy(record.value) }
        }
        if isLocalFile(record) {
            Button("Reveal in Finder") { reveal(record.value) }
        }
        if let session = sourceSession(for: record) {
            Divider()
            Button("Open Session") { openSession(session) }
        }
    }

    private func pageState(title: String, detail: String, icon: Ph, actionTitle: String?, action: (() -> Void)?)
        -> some View
    {
        VStack(spacing: 10) {
            DockIconLabel(title, icon: icon)
                .dockFont(.navigation, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
            Text(detail)
                .dockFont(.metadata)
                .foregroundStyle(Color.dockSecondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.dockPrimary)
                    .tint(Color.dockAccent)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var pageSummaryText: String {
        if let errorMessage { return errorMessage }
        if failedSessionCount > 0 { return "\(failedSessionCount) sessions could not be read. Refresh to retry." }
        if isLoading && records.isEmpty { return "Indexing Hermes sessions…" }
        let count = records.count
        let sessions = Set(records.map(\.scopedSessionID)).count
        return "\(count) \(count == 1 ? "output" : "outputs") across \(sessions) session\(sessions == 1 ? "" : "s")"
    }

    private func loadTextPreview(for record: ArtifactRecord) async {
        guard record.kind == .file, let url = artifactURL(record.value), url.isFileURL else { return }
        let content = await Task.detached { ArtifactTextPreview.Content.load(url) }.value
        guard !Task.isCancelled else { return }
        if isMarkdown(record), case .text(let source, _) = content {
            let key = MarkdownMessageView.renderKey(for: source)
            if MarkdownRenderDocumentCache.cached(source: source, key: key) == nil {
                let document = await Task.detached(priority: .userInitiated) {
                    MarkdownRenderDocumentBuilder.build(source: source, key: key)
                }.value
                guard !Task.isCancelled else { return }
                MarkdownRenderDocumentCache.insert(document, prefetched: true)
            }
        }
        textPreview = ArtifactTextPreview(id: record.id, content: content)
    }

    private var summaryText: String {
        if let errorMessage { return errorMessage }
        if failedSessionCount > 0 { return "\(failedSessionCount) sessions could not be read. Refresh to retry." }
        if isLoading && records.isEmpty { return "Indexing Hermes sessions…" }
        let count = visibleRecords.count
        return "\(count) \(count == 1 ? "output" : "outputs") from Hermes sessions"
    }

    private var content: some View {
        Group {
            if let errorMessage, records.isEmpty, !isLoading {
                state(title: "Artifacts unavailable", detail: errorMessage, icon: .warning)
            } else if records.isEmpty && isLoading {
                state(
                    title: "Indexing artifacts", detail: "Reading generated outputs from Hermes sessions…",
                    icon: .hourglass)
            } else if visibleRecords.isEmpty {
                state(
                    title: query.isEmpty ? "No artifacts found" : "No matching artifacts",
                    detail: query.isEmpty
                        ? "Generated images, files, and links will appear here as sessions produce them."
                        : "Try another search or choose a different artifact type.",
                    icon: .squaresFour
                )
            } else {
                artifactResults
            }
        }
    }

    private var artifactResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if !pagedImages.isEmpty {
                    sectionHeader("IMAGES", count: visibleImages.count)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10)], spacing: 10) {
                        ForEach(pagedImages) { record in imageCard(record) }
                    }
                    pagination(current: min(imagePage, imagePageCount), total: imagePageCount) { imagePage = $0 }
                }

                ForEach(visibleRecords.filter { $0.generated != nil }) { record in
                    if let generated = record.generated {
                        RichArtifactPreview(model: model, generated: generated)
                    }
                }
                ForEach(visibleRecords.filter { $0.unavailableBookmark != nil }) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record.label).fontWeight(.semibold)
                        Text("Source unavailable. Refresh to retry.").foregroundStyle(Color.dockSecondaryText)
                        if let bookmark = record.unavailableBookmark {
                            Button("Remove saved reference") {
                                savedTools.toggle(bookmark)
                                refreshID += 1
                            }.buttonStyle(.dockCompact)
                        }
                    }
                }
                if !pagedFiles.isEmpty {
                    sectionHeader("FILES AND LINKS", count: visibleFiles.count)
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(pagedFiles) { record in fileRow(record) }
                    }
                    pagination(current: min(filePage, filePageCount), total: filePageCount) { filePage = $0 }
                }
            }
            .padding(14)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 2) {
            ForEach(ArtifactFilter.allCases) { item in
                filterSegment(item)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius + 1, style: .continuous).dockSurfaceFill(
                Color.dockSurface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius + 1, style: .continuous).stroke(
                Color.dockBorderLight))
    }

    private var compactFilterMenu: some View {
        DockMenu(outlined: true) {
            ForEach(ArtifactFilter.allCases) { item in
                DockMenuCheckRow(title: "\(item.rawValue) · \(count(for: item))", isSelected: filter == item) {
                    filter = item
                }
            }
        } label: {
            HStack(spacing: 6) {
                DockIcon(filter.icon, size: 13)
                Text("\(filter.rawValue) · \(count(for: filter))")
                    .lineLimit(1)
                DockIcon(.caretDown, size: 10)
            }
        }
        .dockFont(.body)
        .accessibilityLabel("Artifact type: \(filter.rawValue), \(count(for: filter)) artifacts")
    }

    private func filterSegment(_ item: ArtifactFilter) -> some View {
        let selected = filter == item
        return Button {
            filter = item
        } label: {
            HStack(spacing: 6) {
                if item.showsIcon {
                    DockIcon(
                        item.icon, size: 13, weight: selected ? .fill : .regular,
                        color: selected ? .dockPrimaryText : .dockMetadataText)
                }
                Text(item.rawValue)
                    .dockFont(.body, weight: selected ? .semibold : .medium)
                    .fixedSize()
                Text("\(count(for: item))")
                    .dockFont(.compactStatus, weight: .medium).monospacedDigit()
                    .foregroundStyle(selected ? Color.dockAccent : Color.dockMetadataText)
            }
            .foregroundStyle(selected ? Color.dockPrimaryText : Color.dockSecondaryText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .dockSelectionBackground(
                DockThemeShape(cornerRadius: DockLayout.controlRadius - 2), active: selected,
                fill: DockThemePalette(theme: DockThemeRuntime.current).selectedFill, allowsInvert: false
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityLabel("\(item.rawValue), \(count(for: item)) artifacts")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func filterButton(_ item: ArtifactFilter) -> some View {
        Button {
            filter = item
        } label: {
            HStack(spacing: 6) {
                DockIcon(item.icon)
                Text(item.rawValue)
                Text("\(count(for: item))")
                    .dockFont(.compactStatus, weight: .regular, design: .monospaced)
                    .opacity(0.75)
            }
        }
        .dockFont(.metadata, weight: .semibold)
        .buttonStyle(.dockHover)
        .foregroundStyle(filter == item ? Color.dockPrimaryText : Color.dockSecondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(filter == item ? Color.dockAccent : Color.dockSurface2, in: Capsule())
        .accessibilityLabel("\(item.rawValue), \(count(for: item)) artifacts")
        .accessibilityAddTraits(filter == item ? .isSelected : [])
    }

    private func count(for item: ArtifactFilter) -> Int {
        let value = projection
        return switch item {
        case .all: value.total
        case .image: value.images
        case .file: value.files
        case .link: value.links
        case .interactive: value.interactive
        case .saved: value.saved
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .dockFont(.compactStatus, weight: .bold, design: .monospaced)
                .foregroundStyle(Color.dockMetadataText)
                .tracking(0.8)
            Text("· \(count)")
                .dockFont(.compactStatus, weight: .regular, design: .monospaced)
                .foregroundStyle(Color.dockSecondaryText)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func imageCard(_ record: ArtifactRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            imagePreview(for: record)
                .frame(maxWidth: .infinity)
                .frame(height: 118)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(
                        Color.dockSurface2)
                )
                .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))

            Text(record.label)
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(record.sessionTitle)
                .dockFont(.compactStatus, weight: .regular)
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(1)
            HStack(spacing: 10) {
                Text(record.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .dockFont(.metadata, design: .monospaced)
                    .foregroundStyle(Color.dockMetadataText)
                Spacer(minLength: 4)
                artifactCopyAction(record.value)
                artifactAction("Open") { open(record.value) }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(
                Color.dockSurface2.opacity(0.55))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Image \(record.label), from \(record.sessionTitle)")
    }

    @ViewBuilder
    private func imagePreview(for record: ArtifactRecord, compact: Bool = false) -> some View {
        if let url = artifactURL(record.value) {
            ArtifactImagePreview(url: url, maximumPixelSize: compact ? 96 : 1_040) {
                previewUnavailable(compact: compact)
            }
        } else {
            previewUnavailable(compact: compact)
        }
    }

    private func previewUnavailable(compact: Bool) -> some View {
        VStack(spacing: 5) {
            DockIcon(.image)
            if !compact {
                Text("Preview unavailable")
                    .dockFont(.compactStatus, weight: .regular)
            }
        }
        .foregroundStyle(Color.dockSecondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileRow(_ record: ArtifactRecord) -> some View {
        HStack(spacing: 12) {
            artifactRowIcon(record, size: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.label)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                if let session = sourceSession(for: record) {
                    Button(session.displayTitle) { openSession(session) }
                        .dockFont(.compactStatus, weight: .regular)
                        .buttonStyle(.dockLink)
                        .foregroundStyle(Color.dockAccent)
                        .lineLimit(1)
                } else {
                    Text(record.sessionTitle)
                        .dockFont(.compactStatus, weight: .regular)
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                }
                Text(record.value)
                    .dockFont(.compactStatus, weight: .regular, design: .monospaced)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)
            Text(record.timestamp, format: .dateTime.month(.abbreviated).day())
                .dockFont(.metadata, design: .monospaced)
                .foregroundStyle(Color.dockMetadataText)
            artifactCopyAction(record.value)
            artifactAction("Open") { open(record.value) }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(
                Color.dockSurface2.opacity(0.55))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.kind == .link ? "Link" : "File") \(record.label), from \(record.sessionTitle)")
    }

    private func artifactAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .dockFont(.compactStatus, weight: .semibold)
            .buttonStyle(.dockCompact)
            .foregroundStyle(Color.dockAccent)
    }

    private func artifactCopyAction(_ value: String) -> some View {
        DockCopyButton(
            value,
            accessibilityLabel: "Copy artifact location",
            presentation: .text,
            iconSize: 10,
            color: .dockAccent
        )
        .dockFont(.compactStatus, weight: .semibold)
        .buttonStyle(.dockCompact)
    }

    private func pagination(current: Int, total: Int, select: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Button {
                select(max(1, current - 1))
            } label: {
                DockIcon(.caretLeft)
            }
            .disabled(current <= 1)
            Text("Page \(current) of \(total)")
                .dockFont(.compactStatus, weight: .regular, design: .monospaced)
                .foregroundStyle(Color.dockSecondaryText)
            Button {
                select(min(total, current + 1))
            } label: {
                DockIcon(.caretRight)
            }
            .disabled(current >= total)
        }
        .buttonStyle(.dockCompact)
        .foregroundStyle(Color.dockAccent)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page \(current) of \(total)")
    }

    private func state(title: String, detail: String, icon: Ph) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DockIconLabel(title, icon: icon)
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
            Text(detail)
                .dockFont(.metadata)
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func fileIcon(for label: String) -> Ph {
        switch URL(fileURLWithPath: label).pathExtension.lowercased() {
        case "pdf": .fileText
        case "csv", "xls", "xlsx": .table
        case "html", "htm": .globe
        case "json", "yaml", "yml", "toml", "txt", "md": .fileText
        default: .file
        }
    }

    private func artifactURL(_ value: String) -> URL? { ArtifactOpener.url(value) }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func open(_ value: String) { ArtifactOpener.open(value) }

    private func isLocalFile(_ record: ArtifactRecord) -> Bool {
        ArtifactActionPresentation.make(
            record: record,
            hasSourceSession: sourceSession(for: record) != nil
        ).canRevealInFinder && artifactURL(record.value)?.isFileURL == true
    }

    private func reveal(_ value: String) { ArtifactOpener.reveal(value) }

    private func resetPages() {
        imagePage = 1
        filePage = 1
    }

    private func reconcileSelection() {
        guard presentation == .page else { return }
        selectedArtifactID = ArtifactSelectionPresentation.reconciledID(
            current: selectedArtifactID,
            visibleIDs: visibleRecords.map(\.id)
        )
    }

    private func refresh(force: Bool) async {
        let manualRefreshID = refreshID
        let automaticID = automaticRefreshID
        let changedSession =
            automaticID != completedAutomaticRefreshID
            ? model.navigationSessionID.map {
                ProfileScopedID(profileID: model.sessionProfileID ?? model.profileScopeID, resourceID: $0)
            }
            : nil
        guard !Task.isCancelled else { return }
        let generation = UUID()
        refreshGeneration = generation
        isLoading = true
        defer { if refreshGeneration == generation { isLoading = false } }
        errorMessage = nil
        let previous = records
        let sessions: [HermesSession]
        let indexIncomplete: Bool
        do {
            let index: (sessions: [HermesSession], isIncomplete: Bool)
            if let sessionScope {
                var selected = model.sessions.filter { $0.scopedID == sessionScope }
                if selected.isEmpty, model.navigationSessionID == sessionScope.resourceID,
                    (model.sessionProfileID ?? model.profileScopeID) == sessionScope.profileID
                {
                    selected = [
                        HermesSession(
                            id: sessionScope.resourceID, profileID: sessionScope.profileID,
                            title: model.currentSessionTitle ?? "Session", preview: "", startedAt: nil,
                            messageCount: model.messages.count, source: HermesFeatureIDs.sessionSource)
                    ]
                }
                index = (selected, false)
            } else {
                let result = try await model.artifactSessions()
                index = (result.sessions, result.isIncomplete)
            }
            guard !Task.isCancelled, refreshGeneration == generation else { return }
            sessions = index.sessions
            indexIncomplete = index.isIncomplete
            if indexIncomplete {
                errorMessage = "Some Hermes sessions could not be indexed. Results may be incomplete. Refresh to retry."
            }
        } catch {
            guard !Task.isCancelled, refreshGeneration == generation else { return }
            errorMessage =
                "Could not refresh the artifact index. "
                + HermesDiagnosticsService.safeSummary(error.localizedDescription)
            return
        }
        guard !Task.isCancelled, refreshGeneration == generation else { return }
        indexedSessions = sessions
        let results = await ArtifactIndexLoader.load(
            sessions: sessions, cache: artifactCache, index: .shared,
            owner: ObjectIdentifier(model), force: force,
            invalidatedSessions: Set(changedSession.map { [$0] } ?? []),
            onSession: { result in
                guard !Task.isCancelled, refreshGeneration == generation, result.error == nil else { return }
                let key = ProfileScopedID(profileID: result.profileID, resourceID: result.sessionID)
                records = (records.filter { $0.scopedSessionID != key } + result.records)
                    .sorted { $0.timestamp > $1.timestamp }
                reconcileSelection()
            },
            messages: { session, offset in
                try await model.artifactMessages(for: session, offset: offset)
            })
        guard !Task.isCancelled, refreshGeneration == generation else { return }
        var next: [ArtifactRecord] = []
        var failedSessionIDs = Set<ProfileScopedID>()
        var lastFailure: String?
        let sessionsByID = Dictionary(sessions.map { ($0.scopedID, $0) }, uniquingKeysWith: { first, _ in first })
        var nextCache: [ProfileScopedID: ArtifactIndexLoader.CachedSession] = [:]
        for result in results {
            if let error = result.error {
                failedSessionIDs.insert(ProfileScopedID(profileID: result.profileID, resourceID: result.sessionID))
                lastFailure = error
            } else {
                next.append(contentsOf: result.records)
                let key = ProfileScopedID(profileID: result.profileID, resourceID: result.sessionID)
                if let session = sessionsByID[key] {
                    nextCache[key] = ArtifactIndexLoader.CachedSession(session: session, records: result.records)
                }
            }
        }
        artifactCache = nextCache
        // Keep the prior artifacts for sessions that could not be read this
        // cycle, while allowing successful sessions and removed sessions to
        // converge to the latest authoritative index.
        next.append(
            contentsOf: previous.filter {
                failedSessionIDs.contains($0.scopedSessionID)
                    || (indexIncomplete && sessionsByID[$0.scopedSessionID] == nil)
            })
        failedSessionCount = failedSessionIDs.count
        records = Dictionary(grouping: next, by: \.id)
            .compactMap(\.value.first)
            .sorted { $0.timestamp > $1.timestamp }
        if !failedSessionIDs.isEmpty && records.isEmpty {
            errorMessage =
                "Hermes couldn't read \(failedSessionIDs.count) of \(sessions.count) sessions. \(lastFailure ?? "")"
        }
        for bookmark in savedTools.resourceBookmarks where !records.contains(where: { $0.id == bookmark.id }) {
            guard sessionScope == nil || sessionScope == bookmark.record.scopedSessionID else { continue }
            records.append(bookmark.record)
        }
        savedTools.reconcile(records.compactMap { $0.generated?.reference })
        for bookmark in savedTools.bookmarks where !records.contains(where: { $0.id == bookmark.id }) {
            let reference = bookmark.reference
            let scope = ProfileScopedID(profileID: reference.profileID, resourceID: reference.sessionID)
            guard sessionScope == nil || sessionScope == scope else { continue }
            records.append(
                ArtifactRecord(
                    value: "", sessionID: reference.sessionID, sessionTitle: bookmark.sessionTitle,
                    timestamp: .distantPast, profileID: reference.profileID, unavailableBookmark: bookmark))
        }
        completedManualRefreshID = manualRefreshID
        completedAutomaticRefreshID = automaticID
        resetPages()
        reconcileSelection()
    }
}

struct ArtifactDaySection: Identifiable {
    let title: String
    let records: [ArtifactRecord]
    var id: String { title }

    /// Groups already time-sorted records into Today / Yesterday / weekday / month buckets.
    static func group(_ records: [ArtifactRecord], now: Date = .now, calendar: Calendar = .current) -> [Self] {
        var order: [String] = []
        var buckets: [String: [ArtifactRecord]] = [:]
        for record in records {
            let title: String
            if calendar.isDate(record.timestamp, inSameDayAs: now) {
                title = "Today"
            } else if calendar.isDateInYesterday(record.timestamp) {
                title = "Yesterday"
            } else if let days = calendar.dateComponents([.day], from: record.timestamp, to: now).day, days < 7 {
                title = record.timestamp.formatted(.dateTime.weekday(.wide))
            } else {
                title = record.timestamp.formatted(.dateTime.month(.wide).year())
            }
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(record)
        }
        return order.map { Self(title: $0, records: buckets[$0] ?? []) }
    }
}

struct ArtifactTextPreview: Equatable {
    enum Content: Equatable {
        case text(String, truncated: Bool)
        case binary
        case missing

        private static let limit = 48_000

        static func load(_ url: URL) -> Self {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return .missing }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
            let slice = data.prefix(limit)
            guard !slice.contains(0),
                let text = String(data: slice, encoding: .utf8) ?? String(data: slice.dropLast(3), encoding: .utf8)
            else {
                return .binary
            }
            return .text(text, truncated: data.count > limit)
        }
    }

    let id: String
    let content: Content
}
