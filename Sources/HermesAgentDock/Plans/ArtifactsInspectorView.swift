import AppKit
import SwiftUI

struct ArtifactsInspectorView: View {
    @ObservedObject var model: DockModel
    @State private var records: [ArtifactRecord] = []
    @State private var query = ""
    @State private var filter: ArtifactFilter = .all
    @State private var isLoading = false
    @State private var errorMessage: String?

    private enum ArtifactFilter: String, CaseIterable {
        case all = "All", image = "Images", file = "Files", link = "Links"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.dockBorderLight)
            if isLoading && records.isEmpty {
                state(title: "Indexing artifacts", detail: "Reading generated outputs from recent Hermes sessions…")
            } else if let errorMessage, records.isEmpty {
                state(title: "Artifacts unavailable", detail: errorMessage)
            } else if visibleRecords.isEmpty {
                state(title: "No artifacts found", detail: "Generated images and file outputs will appear here as sessions produce them.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(visibleRecords) { record in row(record) }
                    }
                    .padding(14)
                }
            }
        }
        .background(Color.dockCanvas)
        .task { await refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ARTIFACTS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                        .tracking(0.8)
                    Text("Generated outputs")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("\(records.count) from recent sessions")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                }
                Spacer()
                Button { Task { await refresh() } } label: {
                    LucideImage(systemName: isLoading ? "hourglass" : "refresh-cw")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockAccent)
                .accessibilityLabel("Refresh artifacts")
            }
            TextField("Search artifacts…", text: $query)
                .textFieldStyle(.dockGlass)
            HStack(spacing: 6) {
                ForEach(ArtifactFilter.allCases, id: \.self) { item in
                    Button(item.rawValue) { filter = item }
                        .font(.system(size: 11, weight: .semibold))
                        .buttonStyle(.borderless)
                        .foregroundStyle(filter == item ? Color.dockCanvas : Color.dockSecondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(filter == item ? Color.dockAccent : Color.dockSurface2, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
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

    private func row(_ record: ArtifactRecord) -> some View {
        HStack(spacing: 12) {
            if record.kind == .image, let url = artifactURL(record.value) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { LucideImage(systemName: "image").foregroundStyle(Color.dockAccent) }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                LucideImage(systemName: record.kind == .link ? "link" : "doc")
                    .foregroundStyle(record.kind == .link ? Color.dockSecondaryText : Color.dockAccent)
                    .frame(width: 28, height: 28)
                    .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
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
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.value, forType: .string)
            }
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(.borderless)
            .foregroundStyle(Color.dockAccent)
            if record.kind != .link, let url = artifactURL(record.value) {
                Button("Open") { NSWorkspace.shared.open(url) }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.dockAccent)
            }
        }
        .padding(10)
        .background(Color.dockSurface2.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func artifactURL(_ value: String) -> URL? {
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return URL(string: value) }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }

    private func state(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.dockPrimaryText)
            Text(detail).font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        var next: [ArtifactRecord] = []
        var failures = 0
        for session in model.sessions.prefix(50) {
            do { next.append(contentsOf: ArtifactService.extract(session: session, messages: try await model.artifactMessages(for: session))) }
            catch { failures += 1 }
        }
        records = Dictionary(grouping: next, by: \.id).compactMap(\.value.first).sorted { $0.timestamp > $1.timestamp }
        if failures > 0 && records.isEmpty { errorMessage = "Some session outputs could not be read. Try refreshing." }
        isLoading = false
    }
}
