import AppKit
import SwiftUI

/// Splits an assistant reply so each line-level `MEDIA:<path>` delivery renders
/// as a download card in place, like Hermes Desktop, instead of raw text.
enum ChatMediaSegment: Equatable {
    case markdown(String)
    case media(String)

    /// `delivered` are files tools produced (e.g. image_generate), which rarely
    /// repeat a MEDIA: tag in the reply; they follow the text.
    static func split(_ text: String, delivered: [String] = []) -> [ChatMediaSegment] {
        let segments = split(text)
        let inText = Set(segments.compactMap { if case .media(let path) = $0 { path } else { nil } })
        return segments + delivered.filter { !inText.contains($0) }.map { .media($0) }
    }

    private static func split(_ text: String) -> [ChatMediaSegment] {
        guard text.contains("MEDIA:") || text.contains("![") else { return [.markdown(text)] }
        var segments: [ChatMediaSegment] = []
        var buffer: [Substring] = []
        func flush() {
            let chunk = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { segments.append(.markdown(chunk)) }
            buffer.removeAll()
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let image = trimmed.range(of: #"^!\[[^\]]*\]\(([^)\s]+)\)$"#, options: .regularExpression) {
                flush()
                segments.append(
                    .media(
                        String(trimmed[image]).replacingOccurrences(
                            of: #"^!\[[^\]]*\]\("#, with: "", options: .regularExpression
                        ).dropLast().description))
            } else if trimmed.drop(while: { "`\"'".contains($0) }).hasPrefix("MEDIA:"),
                let path = ArtifactService.mediaValues(trimmed).first, !path.isEmpty
            {
                flush()
                segments.append(.media(path))
            } else {
                buffer.append(line)
            }
        }
        flush()
        return segments
    }
}

/// Separates Herm's pending labels and Hermes' persisted file references from message text.
enum UserMessageAttachments {
    static func split(_ text: String) -> (text: String, names: [String]) {
        var names: [String] = []
        var lines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            var path: String?
            if value.hasPrefix("[PDF: ") || value.hasPrefix("[File: "), value.hasSuffix("]") {
                path = String(value.dropFirst(value.hasPrefix("[PDF: ") ? 6 : 7).dropLast())
            } else if value.hasPrefix("@file:") {
                var reference = String(value.dropFirst(6))
                if reference.count >= 2, let first = reference.first, first == reference.last,
                    "`\"'".contains(first)
                {
                    reference.removeFirst()
                    reference.removeLast()
                } else if reference.contains(where: \.isWhitespace) {
                    lines.append(line)
                    continue
                }
                path = reference
            }
            if let path, !path.isEmpty {
                names.append((path as NSString).lastPathComponent)
            } else {
                lines.append(line)
            }
        }
        if !names.isEmpty { lines.removeAll { $0 == "[document]" || $0 == "[attachments]" } }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), names)
    }
}

enum ArtifactOpener {
    static func url(_ value: String) -> URL? {
        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("data:image/") {
            return URL(string: value)
        }
        if value.hasPrefix("file://") { return URL(string: value) }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }

    static func open(_ value: String) {
        guard let url = url(value) else { return }
        // Artifact paths come from agent output; opening an app bundle or an
        // executable would run it. Reveal those in Finder instead.
        var isDirectory: ObjCBool = false
        if url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
                ? NSWorkspace.shared.isFilePackage(atPath: url.path)
                : FileManager.default.isExecutableFile(atPath: url.path)
        {
            ExternalOpen.reveal([url])
            return
        }
        ExternalOpen.open(url)
    }

    static func reveal(_ value: String) {
        guard let url = url(value), url.isFileURL else { return }
        ExternalOpen.reveal([url])
    }

    /// Copies a local file into ~/Downloads under a free name and returns it.
    static func download(_ value: String) throws -> URL {
        guard let source = url(value), source.isFileURL else { throw CocoaError(.fileNoSuchFile) }
        let downloads = try FileManager.default.url(
            for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var destination = downloads.appendingPathComponent(source.lastPathComponent)
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = "\(base) (\(counter))" + (ext.isEmpty ? "" : ".\(ext)")
            destination = downloads.appendingPathComponent(name)
            counter += 1
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}

struct ChatMediaAttachmentCard: View {
    let path: String
    /// Rendered as a row inside a shared container, which supplies the chrome.
    var grouped = false
    @State private var status: String?
    @State private var changes: RepositoryAttachmentChanges?
    @Environment(\.sessionPreviewWorkspace) private var previewWorkspace

    private var url: URL? { ArtifactOpener.url(path) }
    private var name: String { url?.lastPathComponent ?? path }
    private var isLocal: Bool { url?.isFileURL == true }
    private var exists: Bool { !isLocal || url.map { FileManager.default.fileExists(atPath: $0.path) } == true }

    private var isImage: Bool { ArtifactService.kind(for: path) == .image }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isImage, exists, let url {
                imagePreview(url)
            } else if let url, ChatVideoPreview.supports(url), exists {
                ChatVideoPreview(url: url)
                    .id(url)
            }
            card
        }
        .task(id: path) {
            changes = nil
            guard !isImage, let url else { return }
            let resolved = await RepositoryService.attachmentChanges(url: url)
            guard !Task.isCancelled else { return }
            changes = resolved
        }
    }

    @ViewBuilder
    private func imagePreview(_ url: URL) -> some View {
        let shape = RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
        Group {
            if url.isFileURL || url.scheme == "data" {
                AttachmentThumbnailView(url: url).frame(maxWidth: 420).frame(height: 420)
            } else {
                AsyncImage(url: url) {
                    $0.resizable().scaledToFit()
                } placeholder: {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(maxWidth: 420, maxHeight: 420, alignment: .leading)
        .clipShape(shape)
        .onTapGesture { ArtifactOpener.open(path) }
    }

    private var card: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                FileTypeIcon(fileName: name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(changes?.files.first?.path ?? name)
                        .dockFont(.body, weight: .medium)
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle = status
                        ?? (changes.map {
                            "\($0.files.first?.status.rawValue.capitalized ?? "Changed") · Current Git changes"
                        } ?? (exists ? nil : "File not found"))
                    {
                        Text(subtitle)
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            HStack(spacing: 8) {
                if isLocal {
                    cardButton("Download", icon: .downloadSimple) {
                        do {
                            let saved = try ArtifactOpener.download(path)
                            status = "Saved to Downloads"
                            ExternalOpen.reveal([saved])
                        } catch {
                            status = "Download failed: \(error.localizedDescription)"
                        }
                    }
                    .disabled(!exists)
                }
                cardButton("Open", icon: nil) {
                    if let url, let previewWorkspace, FilePreviewKind(url: url) != nil {
                        SessionMessageTabs.shared.open(.file(url), in: previewWorkspace)
                    } else {
                        ArtifactOpener.open(path)
                    }
                }
                .disabled(!exists)
                if let changes {
                    cardButton("Open diff", icon: .gitBranch) {
                        FilePreviewCenter.shared.openDiff(changes)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .dockPadding(10)
        .background(
            Color.dockSurface2.opacity(grouped ? 0 : 0.55),
            in: RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
        )
        .overlay {
            if !grouped {
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).stroke(
                    Color.dockBorderLight, lineWidth: 0.5)
            }
        }
        .contextMenu {
            if isLocal { Button("Reveal in Finder") { ArtifactOpener.reveal(path) } }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
        .help(path)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachment \(name)")
    }

    private func cardButton(_ title: String, icon: Ph?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { DockIcon(icon, size: 11, color: Color.dockSecondaryText) }
                Text(title).dockFont(.body, weight: .medium)
            }
            .foregroundStyle(Color.dockSecondaryText)
        }
        .buttonStyle(.dockCompact)
    }
}

/// "Open with" rows for a local file: its default app, the other apps macOS
/// registers for it in a submenu, then Reveal in Finder. Rows for a `DockMenu`.
struct FileOpenWithItems: View {
    let url: URL

    var body: some View {
        let workspace = NSWorkspace.shared
        let preferred = workspace.urlForApplication(toOpen: url)
        let others = workspace.urlsForApplications(toOpen: url).filter { $0 != preferred }
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        if let preferred { appRow(preferred) }
        if !others.isEmpty {
            DockMenu("Open With", icon: .arrowSquareOut) {
                ForEach(others, id: \.self, content: appRow)
            }
        }
        Button("Reveal in Finder") { ExternalOpen.reveal([url]) }
    }

    private func name(_ app: URL) -> String { app.deletingPathExtension().lastPathComponent }

    private func appRow(_ app: URL) -> some View {
        Button {
            ExternalOpen.open(url, with: app)
        } label: {
            Label {
                Text(name(app))
            } icon: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 16, height: 16)
            }
        }
    }
}

struct SessionAttachmentDiffTab: View {
    let changes: RepositoryAttachmentChanges
    @State private var diffs: [String: RepositoryDiff] = [:]
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(changes.files) { file in
                    if file.isStaged {
                        Text("Staged changes")
                            .dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockSecondaryText)
                            .dockPadding(.horizontal, 14)
                    }
                    SessionChangeDiffPreview(file: file, diff: diffs[file.id], isLoading: isLoading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dockCanvas)
        .task(id: changes.id) {
            diffs = [:]
            isLoading = true
            for file in changes.files {
                let diff = await RepositoryService.diff(path: changes.repositoryPath, file: file)
                guard !Task.isCancelled else { return }
                diffs[file.id] = diff
            }
            isLoading = false
        }
    }
}
