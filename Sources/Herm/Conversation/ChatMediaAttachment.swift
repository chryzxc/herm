import AppKit
import SwiftUI

/// Splits an assistant reply so each line-level `MEDIA:<path>` delivery renders
/// as a download card in place, like Hermes Desktop, instead of raw text.
enum ChatMediaSegment: Equatable {
    case markdown(String)
    case media(String)

    static func split(_ text: String) -> [ChatMediaSegment] {
        guard text.contains("MEDIA:") else { return [.markdown(text)] }
        var segments: [ChatMediaSegment] = []
        var buffer: [Substring] = []
        func flush() {
            let chunk = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { segments.append(.markdown(chunk)) }
            buffer.removeAll()
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.drop(while: { "`\"'".contains($0) }).hasPrefix("MEDIA:"),
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
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ value: String) {
        guard let url = url(value), url.isFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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

    private var url: URL? { ArtifactOpener.url(path) }
    private var name: String { url?.lastPathComponent ?? path }
    private var isLocal: Bool { url?.isFileURL == true }
    private var exists: Bool { !isLocal || url.map { FileManager.default.fileExists(atPath: $0.path) } == true }

    var body: some View {
        HStack(spacing: 12) {
            DockIcon(icon, size: 14, color: Color.dockSecondaryText)
                .frame(width: 30, height: 30)
                .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
                        NSWorkspace.shared.activateFileViewerSelecting([saved])
                    } catch {
                        status = "Download failed: \(error.localizedDescription)"
                    }
                }
                .disabled(!exists)
            }
            cardButton(isLocal ? "Open preview" : "Open", icon: nil) { ArtifactOpener.open(path) }
                .disabled(!exists)
        }
        .padding(10)
        .background(Color.dockSurface2.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
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
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
