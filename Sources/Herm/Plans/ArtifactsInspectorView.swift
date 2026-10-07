import AppKit
import SwiftUI

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
        let isLocalFile = record.kind == .file
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

    init(model: DockModel, presentation: ArtifactsPresentationMode = .inspector) {
        self.model = model
        self.presentation = presentation
    }

    @State private var records: [ArtifactRecord] = []
    @State private var query = ""
    @State private var filter: ArtifactFilter = .all
    @State private var imagePage = 1
    @State private var filePage = 1
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var failedSessionCount = 0
    @State private var selectedArtifactID: String?
    @State private var textPreview: ArtifactTextPreview?

    private let imagesPerPage = 24
    private let filesPerPage = 100

    private enum ArtifactFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case image = "Images"
        case file = "Files"
        case link = "Links"

        var id: String { rawValue }
        var icon: Ph {
            switch self {
            case .all: .squaresFour
            case .image: .image
            case .file: .file
            case .link: .link
            }
        }
        var showsIcon: Bool { self != .all }
    }

    private var visibleRecords: [ArtifactRecord] {
        let kind: ArtifactKind? = switch filter {
        case .all: nil
        case .image: .image
        case .file: .file
        case .link: .link
        }
        return ArtifactService.filter(records, query: query, kind: kind)
    }

    private var visibleImages: [ArtifactRecord] {
        visibleRecords.filter { $0.kind == .image }
    }

    private var visibleFiles: [ArtifactRecord] {
        visibleRecords.filter { $0.kind != .image }
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

    private var sessionRefreshKey: String {
        model.sessions.map(\.id).joined(separator: ",")
    }

    var body: some View {
        Group {
            if presentation == .page {
                pageBody
            } else {
                inspectorBody
            }
        }
        .task(id: sessionRefreshKey) { await refresh() }
        .onChange(of: query) { resetPages() }
        .onChange(of: filter) { resetPages() }
        .onChange(of: visibleRecords.map(\.id)) { _, _ in reconcileSelection() }
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
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                        .tracking(0.8)
                    Text("Generated outputs")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text(summaryText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                }
                Spacer(minLength: 8)
                Button { Task { await refresh() } } label: {
                    DockIcon(isLoading ? .hourglass : .arrowsClockwise)
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockAccent)
                .disabled(isLoading)
                .accessibilityLabel("Refresh artifacts")
            }

            TextField("Search by name, path, URL, or session…", text: $query)
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
            pageHeader
            if failedSessionCount > 0 && !records.isEmpty {
                partialFailureBanner
            }
            Divider().overlay(Color.dockBorderLight)
            pageContent
        }
        .background(Color.dockCanvas)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Artifacts")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text(pageSummaryText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { Task { await refresh() } } label: {
                    Group {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            DockIcon(.arrowsClockwise)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockAccent)
                .disabled(isLoading)
                .help(isLoading ? "Refreshing artifacts…" : "Refresh artifacts")
                .accessibilityLabel(isLoading ? "Refreshing artifacts" : "Refresh artifacts")
            }

            HStack(spacing: 10) {
                TextField("Search by name, path, URL, or session…", text: $query)
                    .textFieldStyle(.dockGlass)
                    .frame(maxWidth: 420)
                    .accessibilityLabel("Search artifacts")
                filterBar
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var partialFailureBanner: some View {
        HStack(spacing: 8) {
            DockIcon(.warning)
                .foregroundStyle(Color.dockWarning)
            Text("\(failedSessionCount) session\(failedSessionCount == 1 ? "" : "s") couldn't be read. Showing what loaded.")
                .font(.system(size: 11))
                .foregroundStyle(Color.dockSecondaryText)
            Spacer(minLength: 8)
            Button("Retry") { Task { await refresh() } }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
                .disabled(isLoading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.dockWarning.opacity(0.08))
    }

    @ViewBuilder
    private var pageContent: some View {
        if let errorMessage, records.isEmpty {
            pageState(title: "Artifacts unavailable", detail: errorMessage, icon: .warning, actionTitle: "Retry") {
                Task { await refresh() }
            }
        } else if records.isEmpty && isLoading {
            pageState(title: "Indexing artifacts", detail: "Reading generated outputs from recent Hermes sessions…", icon: .hourglass, actionTitle: nil, action: nil)
        } else if visibleRecords.isEmpty {
            let filtered = !query.isEmpty || filter != .all
            pageState(
                title: filtered ? "No matching artifacts" : "No generated outputs yet",
                detail: filtered ? "Try another search or clear the current filter." : "Files Hermes writes, images it produces, and links it shares will appear here.",
                icon: .squaresFour,
                actionTitle: filtered ? "Clear filters" : nil
            ) {
                query = ""
                filter = .all
            }
        } else {
            HSplitView {
                artifactBrowser
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 460)
                artifactDetail
                    .frame(minWidth: 360)
            }
        }
    }

    private var artifactBrowser: some View {
        List(selection: $selectedArtifactID) {
            ForEach(ArtifactDaySection.group(visibleRecords)) { section in
                Section {
                    ForEach(section.records) { record in
                        artifactBrowserRow(record)
                            .tag(record.id)
                            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(section.title.uppercased())
                            .tracking(0.8)
                        Text("\(section.records.count)")
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.dockSectionText)
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let record = ids.first.flatMap({ id in visibleRecords.first { $0.id == id } }) {
                artifactContextActions(record)
            }
        } primaryAction: { ids in
            ids.compactMap { id in visibleRecords.first { $0.id == id } }.forEach { open($0.value) }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.dockCanvas)
    }

    private func artifactBrowserRow(_ record: ArtifactRecord) -> some View {
        HStack(spacing: 10) {
            artifactRowIcon(record)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(record.timestamp, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.dockMetadataText)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    originBadge(record.origin)
                    Text(record.sessionTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.dockSecondaryText)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.label), \(record.origin.rawValue.lowercased()) in \(record.sessionTitle)")
    }

    private func originBadge(_ origin: ArtifactOrigin) -> some View {
        Text(origin.rawValue)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(originColor(origin))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(originColor(origin).opacity(0.14), in: Capsule())
    }

    private func originColor(_ origin: ArtifactOrigin) -> Color {
        switch origin {
        case .generated: .dockSuccess
        case .shared: .dockAccent
        }
    }

    @ViewBuilder
    private func artifactRowIcon(_ record: ArtifactRecord) -> some View {
        if record.kind == .image {
            imagePreview(for: record, compact: true)
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous))
        } else {
            DockIcon(record.kind == .link ? .link : fileIcon(for: record.label))
                .foregroundStyle(record.kind == .link ? Color.dockSecondaryText : Color.dockAccent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous))
        }
    }

    @ViewBuilder
    private var artifactDetail: some View {
        if let record = selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.label)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.dockPrimaryText)
                            .textSelection(.enabled)
                        HStack(spacing: 6) {
                            originBadge(record.origin)
                            Text(record.location)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.dockMetadataText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    detailActions(record)
                    detailPreview(record)
                    detailMetadata(record)
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(24)
            }
            .background(Color.dockCanvas)
            .task(id: record.id) { await loadTextPreview(for: record) }
        } else {
            pageState(title: "Select an artifact", detail: "Choose an output to preview its contents and actions.", icon: .fileMagnifyingGlass, actionTitle: nil, action: nil)
        }
    }

    private var selectedRecord: ArtifactRecord? {
        visibleRecords.first { $0.id == selectedArtifactID }
    }

    @ViewBuilder
    private func detailPreview(_ record: ArtifactRecord) -> some View {
        if record.kind == .image {
            imagePreview(for: record)
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(minHeight: 260, maxHeight: 480)
                .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous))
        } else if let textPreview, textPreview.id == record.id {
            switch textPreview.content {
            case .text(let text, let truncated):
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView(.horizontal) {
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.dockPrimaryText)
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(14)
                    }
                    if truncated {
                        Divider().overlay(Color.dockBorderLight)
                        Text("Preview truncated — open the file to see the rest.")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.dockMetadataText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous).stroke(Color.dockBorderLight))
            case .missing:
                previewPlaceholder(icon: .warning, title: "File no longer exists", detail: "It was moved or deleted after the session produced it.")
            case .binary:
                previewPlaceholder(icon: fileIcon(for: record.label), title: "No inline preview", detail: "Open it with its default app.")
            }
        } else if record.kind == .link {
            previewPlaceholder(icon: .link, title: record.location, detail: record.value)
        } else {
            previewPlaceholder(icon: fileIcon(for: record.label), title: "Loading preview…", detail: nil)
        }
    }

    private func previewPlaceholder(icon: Ph, title: String, detail: String?) -> some View {
        VStack(spacing: 8) {
            DockIcon(icon)
                .foregroundStyle(Color.dockSecondaryText)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dockPrimaryText)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockSecondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous))
    }

    private func detailActions(_ record: ArtifactRecord) -> some View {
        HStack(spacing: 8) {
            Button("Open") { open(record.value) }
                .buttonStyle(.borderedProminent)
                .tint(Color.dockAccent)
            DockCopyButton(
                record.value,
                label: "Copy \(record.kind == .link ? "link" : "path")",
                accessibilityLabel: "Copy \(record.kind == .link ? "link" : "path")",
                presentation: .text
            )
                .buttonStyle(.bordered)
            if isLocalFile(record) {
                Button("Reveal in Finder") { reveal(record.value) }
                    .buttonStyle(.bordered)
            }
            if let session = model.sessions.first(where: { $0.id == record.sessionID }) {
                Button("Open session") { model.resumeSession(session) }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.regular)
    }

    private func detailMetadata(_ record: ArtifactRecord) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            metadataRow("Location", value: record.value)
            metadataRow("Session", value: record.sessionTitle)
            metadataRow("Updated", value: record.timestamp.formatted(date: .abbreviated, time: .shortened))
        }
        .font(.system(size: 11))
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.dockMetadataText)
            Text(value)
                .foregroundStyle(Color.dockSecondaryText)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private func artifactContextActions(_ record: ArtifactRecord) -> some View {
        Button("Open") { open(record.value) }
        Button("Copy") { copy(record.value) }
        if isLocalFile(record) {
            Button("Reveal in Finder") { reveal(record.value) }
        }
        if let session = model.sessions.first(where: { $0.id == record.sessionID }) {
            Button("Open session") { model.resumeSession(session) }
        }
    }

    private func pageState(title: String, detail: String, icon: Ph, actionTitle: String?, action: (() -> Void)?) -> some View {
        VStack(spacing: 10) {
            DockIconLabel(title, icon: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Color.dockSecondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.dockAccent)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var pageSummaryText: String {
        if isLoading && records.isEmpty { return "Indexing recent Hermes sessions…" }
        let count = records.count
        let sessions = Set(records.map(\.sessionID)).count
        return "\(count) \(count == 1 ? "output" : "outputs") across \(sessions) session\(sessions == 1 ? "" : "s")"
    }

    private func loadTextPreview(for record: ArtifactRecord) async {
        guard record.kind == .file, let url = artifactURL(record.value), url.isFileURL else { return }
        let content = await Task.detached { ArtifactTextPreview.Content.load(url) }.value
        textPreview = ArtifactTextPreview(id: record.id, content: content)
    }

    private var summaryText: String {
        if isLoading && records.isEmpty { return "Indexing recent Hermes sessions…" }
        let count = visibleRecords.count
        return "\(count) \(count == 1 ? "output" : "outputs") from recent sessions"
    }

    private var content: some View {
        Group {
            if let errorMessage, records.isEmpty {
                state(title: "Artifacts unavailable", detail: errorMessage, icon: .warning)
            } else if records.isEmpty && isLoading {
                state(title: "Indexing artifacts", detail: "Reading generated outputs from recent Hermes sessions…", icon: .hourglass)
            } else if visibleRecords.isEmpty {
                state(
                    title: query.isEmpty ? "No artifacts found" : "No matching artifacts",
                    detail: query.isEmpty ? "Generated images, files, and links will appear here as sessions produce them." : "Try another search or choose a different artifact type.",
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
        .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: DockLayout.controlRadius + 1, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius + 1, style: .continuous).stroke(Color.dockBorderLight))
    }

    private func filterSegment(_ item: ArtifactFilter) -> some View {
        let selected = filter == item
        return Button { filter = item } label: {
            HStack(spacing: 6) {
                if item.showsIcon {
                    DockIcon(item.icon, size: 13, color: selected ? .dockAccent : .dockMetadataText)
                }
                Text(item.rawValue)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                Text("\(count(for: item))")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(selected ? Color.dockAccent : Color.dockMetadataText)
            }
            .foregroundStyle(selected ? Color.dockPrimaryText : Color.dockSecondaryText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(selected ? Color.dockAccent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.rawValue), \(count(for: item)) artifacts")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func filterButton(_ item: ArtifactFilter) -> some View {
        Button { filter = item } label: {
            HStack(spacing: 6) {
                DockIcon(item.icon)
                Text(item.rawValue)
                Text("\(count(for: item))")
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(0.75)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .buttonStyle(.borderless)
        .foregroundStyle(filter == item ? Color.dockPrimaryText : Color.dockSecondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(filter == item ? Color.dockAccent : Color.dockSurface2, in: Capsule())
        .accessibilityLabel("\(item.rawValue), \(count(for: item)) artifacts")
        .accessibilityAddTraits(filter == item ? .isSelected : [])
    }

    private func count(for item: ArtifactFilter) -> Int {
        switch item {
        case .all: records.count
        case .image: records.filter { $0.kind == .image }.count
        case .file: records.filter { $0.kind == .file }.count
        case .link: records.filter { $0.kind == .link }.count
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.dockMetadataText)
                .tracking(0.8)
            Text("· \(count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.dockSecondaryText)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func imageCard(_ record: ArtifactRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            imagePreview(for: record)
                .frame(maxWidth: .infinity)
                .frame(height: 118)
                .background(Color.dockSurface2)
                .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))

            Text(record.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(record.sessionTitle)
                .font(.system(size: 10))
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(1)
            HStack(spacing: 10) {
                Text(record.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                Spacer(minLength: 4)
                artifactCopyAction(record.value)
                artifactAction("Open") { open(record.value) }
            }
        }
        .padding(10)
        .background(Color.dockSurface2.opacity(0.55), in: RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Image \(record.label), from \(record.sessionTitle)")
    }

    @ViewBuilder
    private func imagePreview(for record: ArtifactRecord, compact: Bool = false) -> some View {
        // AsyncImage loads file URLs too, off the main thread; a synchronous
        // NSImage(contentsOf:) here decoded every image on each scroll render.
        if let url = artifactURL(record.value) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    previewUnavailable(compact: compact)
                }
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
                    .font(.system(size: 10))
            }
        }
        .foregroundStyle(Color.dockSecondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileRow(_ record: ArtifactRecord) -> some View {
        HStack(spacing: 12) {
            DockIcon(record.kind == .link ? .link : fileIcon(for: record.label))
                .foregroundStyle(record.kind == .link ? Color.dockSecondaryText : Color.dockAccent)
                .frame(width: 30, height: 30)
                .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(record.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                if let session = model.sessions.first(where: { $0.id == record.sessionID }) {
                    Button(session.displayTitle) { model.resumeSession(session) }
                        .font(.system(size: 10))
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.dockAccent)
                        .lineLimit(1)
                } else {
                    Text(record.sessionTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                }
                Text(record.value)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)
            Text(record.timestamp, format: .dateTime.month(.abbreviated).day())
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.dockMetadataText)
            artifactCopyAction(record.value)
            artifactAction("Open") { open(record.value) }
        }
        .padding(10)
        .background(Color.dockSurface2.opacity(0.55), in: RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.kind == .link ? "Link" : "File") \(record.label), from \(record.sessionTitle)")
    }

    private func artifactAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(.borderless)
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
        .font(.system(size: 10, weight: .semibold))
        .buttonStyle(.borderless)
    }

    private func pagination(current: Int, total: Int, select: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Button { select(max(1, current - 1)) } label: {
                DockIcon(.caretLeft)
            }
            .disabled(current <= 1)
            Text("Page \(current) of \(total)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.dockSecondaryText)
            Button { select(min(total, current + 1)) } label: {
                DockIcon(.caretRight)
            }
            .disabled(current >= total)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.dockAccent)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page \(current) of \(total)")
    }

    private func state(title: String, detail: String, icon: Ph) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DockIconLabel(title, icon: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Text(detail)
                .font(.system(size: 11))
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
            hasSourceSession: model.sessions.contains { $0.id == record.sessionID }
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


    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        let previous = records
        let sessions = Array(model.sessions.prefix(50))
        // Requests interleave on the main actor while each awaits the network.
        let tasks = sessions.map { session in
            (session.id, Task { @MainActor in
                ArtifactService.extract(session: session, messages: try await model.artifactMessages(for: session))
            })
        }
        var next: [ArtifactRecord] = []
        var failedSessionIDs = Set<String>()
        var lastFailure: String?
        for (sessionID, task) in tasks {
            switch await task.result {
            case .success(let found): next.append(contentsOf: found)
            case .failure(let error):
                failedSessionIDs.insert(sessionID)
                lastFailure = error.localizedDescription
            }
        }
        // Keep the prior artifacts for sessions that could not be read this
        // cycle, while allowing successful sessions and removed sessions to
        // converge to the latest authoritative index.
        next.append(contentsOf: previous.filter { failedSessionIDs.contains($0.sessionID) })
        failedSessionCount = failedSessionIDs.count
        records = Dictionary(grouping: next, by: \.id)
            .compactMap(\.value.first)
            .sorted { $0.timestamp > $1.timestamp }
        if !failedSessionIDs.isEmpty && records.isEmpty {
            errorMessage = "Hermes couldn't read \(failedSessionIDs.count) of \(sessions.count) sessions. \(lastFailure ?? "")"
        }
        resetPages()
        reconcileSelection()
        isLoading = false
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
            guard !slice.contains(0), let text = String(data: slice, encoding: .utf8) ?? String(data: slice.dropLast(3), encoding: .utf8) else {
                return .binary
            }
            return .text(text, truncated: data.count > limit)
        }
    }

    let id: String
    let content: Content
}
