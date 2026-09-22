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

    private let imagesPerPage = 24
    private let filesPerPage = 100

    private enum ArtifactFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case image = "Images"
        case file = "Files"
        case link = "Links"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .all: "square.grid.2x2"
            case .image: "photo"
            case .file: "doc"
            case .link: "link"
            }
        }
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

    private var pageBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader
            Divider().overlay(Color.dockBorderLight)
            pageToolbar
            Divider().overlay(Color.dockBorderLight)
            pageContent
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
                    LucideImage(systemName: isLoading ? "hourglass" : "refresh-cw")
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

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Artifacts")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Text(pageSummaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(failedSessionCount > 0 ? Color.dockWarning : Color.dockSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { Task { await refresh() } } label: {
                Group {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        LucideImage(systemName: "refresh-cw")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.dockAccent)
            .disabled(isLoading)
            .help(isLoading ? "Refreshing artifacts…" : "Refresh artifacts")
            .accessibilityLabel(isLoading ? "Refreshing artifacts" : "Refresh artifacts")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var pageToolbar: some View {
        HStack(spacing: 10) {
            TextField("Search by name, path, URL, or session…", text: $query)
                .textFieldStyle(.dockGlass)
                .accessibilityLabel("Search artifacts")

            Picker("Artifact type", selection: $filter) {
                ForEach(ArtifactFilter.allCases) { item in
                    Text("\(item.rawValue)  \(count(for: item))")
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 330)
            .accessibilityLabel("Artifact type")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var pageContent: some View {
        if let errorMessage, records.isEmpty {
            pageState(title: "Artifacts unavailable", detail: errorMessage, icon: "exclamationmark.triangle", actionTitle: "Retry") {
                Task { await refresh() }
            }
        } else if records.isEmpty && isLoading {
            pageState(title: "Indexing artifacts", detail: "Reading generated outputs from recent Hermes sessions…", icon: "hourglass", actionTitle: nil, action: nil)
        } else if visibleRecords.isEmpty {
            pageState(
                title: query.isEmpty ? "No generated outputs" : "No matching artifacts",
                detail: query.isEmpty ? "Generated images, files, and links will appear here as sessions produce them." : "Try another search or clear the current filter.",
                icon: "square.grid.2x2",
                actionTitle: query.isEmpty ? nil : "Clear search"
            ) {
                query = ""
                filter = .all
            }
        } else {
            HSplitView {
                artifactBrowser
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                artifactDetail
                    .frame(minWidth: 360)
            }
        }
    }

    private var artifactBrowser: some View {
        List(visibleRecords, selection: $selectedArtifactID) { record in
            artifactBrowserRow(record)
                .tag(record.id)
                .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .contextMenu { artifactContextActions(record) }
                .onTapGesture(count: 2) { open(record.value) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color.dockCanvas)
    }

    private func artifactBrowserRow(_ record: ArtifactRecord) -> some View {
        HStack(spacing: 10) {
            artifactRowIcon(record)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(record.kind.rawValue.capitalized)
                    Text("·")
                    Text(record.sessionTitle)
                        .lineLimit(1)
                    Text("·")
                    Text(record.timestamp, style: .relative)
                        .monospacedDigit()
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func artifactRowIcon(_ record: ArtifactRecord) -> some View {
        if record.kind == .image {
            imagePreview(for: record)
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            LucideImage(systemName: record.kind == .link ? "link" : fileIcon(for: record.label))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(record.kind == .link ? Color.dockSecondaryText : Color.dockAccent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder
    private var artifactDetail: some View {
        if let record = selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailPreview(record)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.label)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.dockPrimaryText)
                            .textSelection(.enabled)
                        Text(record.kind.rawValue.capitalized)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    detailActions(record)
                    detailMetadata(record)
                }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(24)
            }
            .background(Color.dockCanvas)
        } else {
            pageState(title: "Select an artifact", detail: "Choose an output to preview its contents and actions.", icon: "doc.text.magnifyingglass", actionTitle: nil, action: nil)
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
                .frame(minHeight: 260, maxHeight: 440)
                .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            VStack(spacing: 10) {
                LucideImage(systemName: record.kind == .link ? "link" : fileIcon(for: record.label))
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(record.kind == .link ? Color.dockSecondaryText : Color.dockAccent)
                Text(record.kind == .link ? "Web link" : "File output")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dockSecondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
            .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func detailActions(_ record: ArtifactRecord) -> some View {
        HStack(spacing: 8) {
            Button("Open") { open(record.value) }
                .buttonStyle(.borderedProminent)
                .tint(Color.dockAccent)
                .frame(minHeight: 44)
            Button("Copy") { copy(record.value) }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            if isLocalFile(record) {
                Button("Reveal in Finder") { reveal(record.value) }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
            if let session = model.sessions.first(where: { $0.id == record.sessionID }) {
                Button("Open session") { model.resumeSession(session) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.dockAccent)
                    .frame(minHeight: 44)
            }
        }
        .controlSize(.small)
    }

    private func detailMetadata(_ record: ArtifactRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            metadataRow("Location", value: record.value)
            metadataRow("Session", value: record.sessionTitle)
            metadataRow("Created", value: record.timestamp.formatted(date: .abbreviated, time: .shortened))
        }
        .font(.system(size: 11))
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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

    private func pageState(title: String, detail: String, icon: String, actionTitle: String?, action: (() -> Void)?) -> some View {
        VStack(spacing: 10) {
            LucideLabel(title, icon: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Color.dockSecondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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

    private var summaryText: String {
        if isLoading && records.isEmpty { return "Indexing recent Hermes sessions…" }
        let count = visibleRecords.count
        return "\(count) \(count == 1 ? "output" : "outputs") from recent sessions"
    }

    private var pageSummaryText: String {
        if isLoading && records.isEmpty { return "Indexing recent Hermes sessions…" }
        let count = records.count
        let output = "\(count) \(count == 1 ? "output" : "outputs") from recent sessions"
        if failedSessionCount > 0 {
            return "\(output) · \(failedSessionCount) session\(failedSessionCount == 1 ? "" : "s") unavailable"
        }
        return output
    }

    private var content: some View {
        Group {
            if let errorMessage, records.isEmpty {
                state(title: "Artifacts unavailable", detail: errorMessage, icon: "exclamationmark.triangle")
            } else if records.isEmpty && isLoading {
                state(title: "Indexing artifacts", detail: "Reading generated outputs from recent Hermes sessions…", icon: "hourglass")
            } else if visibleRecords.isEmpty {
                state(
                    title: query.isEmpty ? "No artifacts found" : "No matching artifacts",
                    detail: query.isEmpty ? "Generated images, files, and links will appear here as sessions produce them." : "Try another search or choose a different artifact type.",
                    icon: "square.grid.2x2"
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

    private func filterButton(_ item: ArtifactFilter) -> some View {
        Button { filter = item } label: {
            HStack(spacing: 6) {
                LucideImage(systemName: item.icon)
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
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

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
                artifactAction("Copy") { copy(record.value) }
                artifactAction("Open") { open(record.value) }
            }
        }
        .padding(10)
        .background(Color.dockSurface2.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Image \(record.label), from \(record.sessionTitle)")
    }

    @ViewBuilder
    private func imagePreview(for record: ArtifactRecord) -> some View {
        if let url = artifactURL(record.value), url.isFileURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else if let url = artifactURL(record.value) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    previewUnavailable
                }
            }
        } else {
            previewUnavailable
        }
    }

    private var previewUnavailable: some View {
        VStack(spacing: 5) {
            LucideImage(systemName: "photo")
            Text("Preview unavailable")
                .font(.system(size: 10))
        }
        .foregroundStyle(Color.dockSecondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileRow(_ record: ArtifactRecord) -> some View {
        HStack(spacing: 12) {
            LucideImage(systemName: record.kind == .link ? "link" : fileIcon(for: record.label))
                .foregroundStyle(record.kind == .link ? Color.dockSecondaryText : Color.dockAccent)
                .frame(width: 30, height: 30)
                .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

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
            artifactAction("Copy") { copy(record.value) }
            artifactAction("Open") { open(record.value) }
        }
        .padding(10)
        .background(Color.dockSurface2.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.kind == .link ? "Link" : "File") \(record.label), from \(record.sessionTitle)")
    }

    private func artifactAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(.borderless)
            .foregroundStyle(Color.dockAccent)
    }

    private func pagination(current: Int, total: Int, select: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Button { select(max(1, current - 1)) } label: {
                LucideImage(systemName: "chevron.left")
            }
            .disabled(current <= 1)
            Text("Page \(current) of \(total)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.dockSecondaryText)
            Button { select(min(total, current + 1)) } label: {
                LucideImage(systemName: "chevron.right")
            }
            .disabled(current >= total)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.dockAccent)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page \(current) of \(total)")
    }

    private func state(title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LucideLabel(title, icon: icon)
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

    private func fileIcon(for label: String) -> String {
        switch URL(fileURLWithPath: label).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "csv", "xls", "xlsx": "tablecells"
        case "html", "htm": "globe"
        case "json", "yaml", "yml", "toml", "txt", "md": "doc.text"
        default: "doc"
        }
    }

    private func artifactURL(_ value: String) -> URL? {
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return URL(string: value) }
        if value.hasPrefix("data:image/") { return URL(string: value) }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func open(_ value: String) {
        guard let url = artifactURL(value) else { return }
        NSWorkspace.shared.open(url)
    }

    private func isLocalFile(_ record: ArtifactRecord) -> Bool {
        ArtifactActionPresentation.make(
            record: record,
            hasSourceSession: model.sessions.contains { $0.id == record.sessionID }
        ).canRevealInFinder && artifactURL(record.value)?.isFileURL == true
    }

    private func reveal(_ value: String) {
        guard let url = artifactURL(value), url.isFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

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
        var next: [ArtifactRecord] = []
        var failures = 0
        var failedSessionIDs = Set<String>()
        let previous = records
        for session in model.sessions.prefix(50) {
            do {
                next.append(contentsOf: ArtifactService.extract(session: session, messages: try await model.artifactMessages(for: session)))
            } catch {
                failures += 1
                failedSessionIDs.insert(session.id)
            }
        }
        // Keep the prior artifacts for sessions that could not be read this
        // cycle, while allowing successful sessions and removed sessions to
        // converge to the latest authoritative index.
        next.append(contentsOf: previous.filter { failedSessionIDs.contains($0.sessionID) })
        let refreshed = Dictionary(grouping: next, by: \.id)
            .compactMap(\.value.first)
            .sorted { $0.timestamp > $1.timestamp }
        failedSessionCount = failures
        records = refreshed
        if failures > 0 && records.isEmpty {
            errorMessage = "Some recent session outputs could not be read. Try refreshing."
        }
        resetPages()
        reconcileSelection()
        isLoading = false
    }
}
