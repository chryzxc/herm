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
                segments.append(.media(String(trimmed[image]).replacingOccurrences(of: #"^!\[[^\]]*\]\("#, with: "", options: .regularExpression).dropLast().description))
            } else if trimmed.drop(while: { "`\"'".contains($0) }).hasPrefix("MEDIA:"),
               let path = ArtifactService.mediaValues(trimmed).first, !path.isEmpty {
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

enum ArtifactOpener {
    static func url(_ value: String) -> URL? {
        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("data:image/") { return URL(string: value) }
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
            : FileManager.default.isExecutableFile(atPath: url.path) {
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
        let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
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
    @State private var status: String?
    @State private var changes: RepositoryAttachmentChanges?
    @State private var preview: RepositoryAttachmentChanges?

    private var url: URL? { ArtifactOpener.url(path) }
    private var name: String { url?.lastPathComponent ?? path }
    private var isLocal: Bool { url?.isFileURL == true }
    private var exists: Bool { !isLocal || url.map { FileManager.default.fileExists(atPath: $0.path) } == true }

    private var isImage: Bool { ArtifactService.kind(for: path) == .image }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isImage, exists, let url {
                imagePreview(url)
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
        .sheet(item: $preview) { changes in
            ChatAttachmentDiffPreview(changes: changes)
        }
    }

    @ViewBuilder
    private func imagePreview(_ url: URL) -> some View {
        let shape = RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
        Group {
            if url.isFileURL || url.scheme == "data" {
                if let image = url.isFileURL ? NSImage(contentsOf: url) : (try? Data(contentsOf: url)).flatMap(NSImage.init(data:)) {
                    Image(nsImage: image).resizable().scaledToFit()
                }
            } else {
                AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { ProgressView().controlSize(.small) }
            }
        }
        .frame(maxWidth: 420, maxHeight: 420, alignment: .leading)
        .clipShape(shape)
        .onTapGesture { ArtifactOpener.open(path) }
    }

    private var card: some View {
        HStack(spacing: 12) {
            DockIcon(icon, size: 14, color: Color.dockSecondaryText)
                .frame(width: 30, height: 30)
                .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = status ?? (exists ? nil : "File not found") {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
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
            cardButton(changes == nil ? (isLocal ? "Open preview" : "Open") : "Preview diff", icon: nil) {
                if let changes { preview = changes }
                else if let url, FilePreviewKind(url: url) != nil {
                    FilePreviewCenter.shared.url = url
                } else { ArtifactOpener.open(path) }
            }
                .disabled(!exists && changes == nil)
        }
        .padding(10)
        .background(Color.dockSurface2.opacity(0.55), in: RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
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

    private var icon: Ph {
        switch (name as NSString).pathExtension.lowercased() {
        case "ppt", "pptx", "key": .presentation
        case "doc", "docx": .fileDoc
        case "pdf", "txt", "md", "json", "csv": .fileText
        default: .file
        }
    }

    private func cardButton(_ title: String, icon: Ph?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { DockIcon(icon, size: 11, color: Color.dockSecondaryText) }
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.dockSecondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
    }
}

private struct ChatAttachmentDiffPreview: View {
    let changes: RepositoryAttachmentChanges
    @Environment(\.dismiss) private var dismiss
    @State private var diffs: [String: RepositoryDiff] = [:]
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Diff preview").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Spacer()
                DockIconButton(icon: .x, label: "Close diff preview",
                               style: DockThemePalette(theme: DockThemeRuntime.current)) { dismiss() }
            }
            .padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(changes.files) { file in
                        Text(file.isStaged ? "Staged changes" : "Working tree changes")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dockSecondaryText)
                            .padding(.horizontal, 14)
                        SessionChangeDiffPreview(file: file, diff: diffs[file.id], isLoading: isLoading)
                    }
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 760, minHeight: 360, idealHeight: 560)
        .background(Color.dockCanvas)
        .task {
            for file in changes.files {
                let diff = await RepositoryService.diff(path: changes.repositoryPath, file: file)
                guard !Task.isCancelled else { return }
                diffs[file.id] = diff
            }
            isLoading = false
        }
    }
}
