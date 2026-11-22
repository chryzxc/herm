import AppKit
import SwiftUI

/// The runtime supplies bounded edit previews, which may omit files or lines.
struct ConversationChangesCard: View {
    let files: [ConversationChangeSummary.Row]
    @State private var expanded: Set<String> = []
    @State private var status: [String: String] = [:]
    @Environment(\.sessionPreviewWorkspace) private var previewWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(files) { file in
                let isOpen = expanded.contains(file.path)
                let fileName = (file.path as NSString).lastPathComponent
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button {
                            if isOpen { expanded.remove(file.path) } else { expanded.insert(file.path) }
                        } label: {
                            HStack(spacing: 8) {
                                PullRequestFileIcon(path: file.path, size: 14)
                                Text(fileName)
                                    .dockFont(.conversation)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                if !file.previews.isEmpty {
                                    let lines = file.previews.flatMap { $0.components(separatedBy: "\n") }
                                    let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
                                    let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
                                    HStack(spacing: 6) {
                                        Text("+\(added)").foregroundStyle(Color.dockSuccess)
                                        Text("−\(removed)").foregroundStyle(Color.dockDestructive)
                                    }
                                    .dockFont(.metadata, weight: .medium)
                                    .monospacedDigit()
                                    .fixedSize()
                                    DockIcon(isOpen ? .caretDown : .caretRight, size: 10, color: Color.dockMetadataText)
                                }
                            }
                            .dockPadding(.horizontal, 8)
                            .dockPadding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .disabled(file.previews.isEmpty)
                        .accessibilityLabel(
                            file.previews.isEmpty
                                ? fileName : "\(isOpen ? "Hide" : "Show") diff preview for \(fileName)"
                        )
                        .accessibilityHint(
                            file.previews.isEmpty ? "" : "Line counts reflect the available diff preview.")
                        if let path = file.delivery, let url = ArtifactOpener.url(path) {
                            let exists = !url.isFileURL || FileManager.default.fileExists(atPath: url.path)
                            if url.isFileURL {
                                Button {
                                    do {
                                        let saved = try ArtifactOpener.download(path)
                                        status[path] = "Saved to Downloads"
                                        ExternalOpen.reveal([saved])
                                    } catch {
                                        status[path] = "Download failed: \(error.localizedDescription)"
                                    }
                                } label: {
                                    actionLabel("Download", icon: .downloadSimple)
                                }
                                .buttonStyle(.dockSecondary)
                                .disabled(!exists)
                            }
                            Button {
                                if let previewWorkspace, FilePreviewKind(url: url) != nil {
                                    SessionMessageTabs.shared.open(.file(url), in: previewWorkspace)
                                } else {
                                    ArtifactOpener.open(path)
                                }
                            } label: {
                                actionLabel("Open", icon: .arrowSquareOut)
                            }
                            .buttonStyle(.dockSecondary)
                            .disabled(!exists)
                        }
                    }
                    .dockButtonSize(.inline)
                    // Actions sit as far from the trailing edge as the file name does from the leading one.
                    .dockPadding(.trailing, file.delivery == nil ? 0 : 4)

                    if let path = file.delivery, let message = status[path] {
                        Text(message).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                    }
                    if let path = file.delivery, let url = ArtifactOpener.url(path), url.isFileURL,
                        !FileManager.default.fileExists(atPath: url.path)
                    {
                        Text("File not found").dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                    }
                    if isOpen {
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(file.previews.enumerated()), id: \.offset) { _, preview in
                                    ForEach(PullRequestDiffPresentation.lines(preview)) { line in
                                        PullRequestDiffLineView(line: line, wraps: true)
                                    }
                                }
                            }
                            .dockFont(.body, design: .monospaced)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 280)
                        .dockPadding(4)
                        .clipShape(DockThemeShape(cornerRadius: DockLayout.controlRadius, role: .control))
                        .dockWell()
                    }
                }
            }
        }
        .dockFont(.body)
        .foregroundStyle(Color.dockSecondaryText)
        .dockPadding(.horizontal, 4)
        .dockPadding(.vertical, 6)
        .dockWell()
    }

    private func actionLabel(_ title: String, icon: Ph) -> some View {
        ZStack {
            DockIconLabel("Download", icon: .downloadSimple).hidden().accessibilityHidden(true)
            DockIconLabel(title, icon: icon)
        }
        .fixedSize()
    }
}
