import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Actions exposed by the composer attachment menu. The order is part of the
/// compact popover contract so keyboard users get a predictable traversal.
enum AttachmentPopoverAction: String, CaseIterable, Identifiable {
    case files
    case folder
    case captureWindow = "capture-window"
    case savedPrompts = "saved-prompts"
    case conversation = "conversation"
    case images
    case pasteImage = "paste-image"
    case promptSnippets = "prompt-snippets"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: "Files"
        case .savedPrompts: "Saved prompts"
        case .conversation: "Conversation excerpts"
        case .captureWindow: "Capture window"
        case .folder: "Folder"
        case .images: "Images"
        case .pasteImage: "Paste image"
        case .promptSnippets: "Prompt snippets"
        }
    }

    var icon: Ph {
        switch self {
        case .files: .file
        case .savedPrompts: .quotes
        case .conversation: .chatCircleText
        case .captureWindow: .image
        case .folder: .folder
        case .images: .image
        case .pasteImage: .clipboardText
        case .promptSnippets: .quotes
        }
    }
}

enum AttachmentPopoverFilePicker {
    case files
    case images
    case folder

    var allowedContentTypes: [UTType] {
        switch self {
        case .files: [.data]
        case .images: [.png, .jpeg, .image, .pdf]
        case .folder: [.folder]
        }
    }

    var allowsMultipleSelection: Bool { self != .folder }
}

struct AttachmentPromptSnippet: Equatable, Identifiable {
    let label: String
    let text: String

    var id: String { label }
}

enum AttachmentPopoverPresentation {
    static let promptSnippets = [
        AttachmentPromptSnippet(label: "Summarize", text: "Summarize this attachment."),
        AttachmentPromptSnippet(label: "Extract action items", text: "Extract the action items from this attachment."),
        AttachmentPromptSnippet(
            label: "Review this", text: "Review this attachment and call out anything that needs attention."),
    ]

    static func insertingPath(_ url: URL, into draft: String) -> String {
        insertingSnippet(url.path, into: draft)
    }

    static func insertingSnippet(_ snippet: String, into draft: String) -> String {
        draft.isEmpty ? snippet : "\(draft)\n\(snippet)"
    }

    static func importerErrorMessage(_ error: Error) -> String? {
        let nsError = error as NSError
        guard nsError.code != NSUserCancelledError else { return nil }
        return "Could not choose attachments: \(error.localizedDescription)"
    }
}

enum AttachmentPopoverFileSelection {
    private static let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "heic", "webp"])

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    static func process(
        _ urls: [URL],
        stageImage: (URL) -> Void,
        stagePDF: (URL) -> Void,
        stageFile: (URL) -> Void,
        reportError: (String) -> Void,
        clearErrors: () -> Void = {}
    ) {
        clearErrors()
        var pdfURLs: [URL] = []
        for url in urls {
            let pathExtension = url.pathExtension.lowercased()
            if pathExtension == "pdf" {
                pdfURLs.append(url)
            } else if imageExtensions.contains(pathExtension) {
                stageImage(url)
            } else {
                stageFile(url)
            }
        }

        if pdfURLs.count == 1, let pdfURL = pdfURLs.first {
            stagePDF(pdfURL)
        } else if pdfURLs.count > 1 {
            reportError("Select one PDF at a time. Multiple images can still be selected together.")
        }
    }
}

struct AttachmentPopover: View {
    let pasteImageAvailable: Bool
    let onSelect: (AttachmentPopoverAction) -> Void
    let onSelectSnippet: (String) -> Void
    /// Group rooms carry text only, so they offer just the inserting actions.
    var actions = AttachmentPopoverAction.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ATTACH OR INSERT")
                .dockFont(.metadata, weight: .semibold, design: .monospaced)
                .tracking(0.7)
                .foregroundStyle(Color.dockAccent)

            ForEach(actions) { action in
                if action == .promptSnippets {
                    snippetsRow
                } else {
                    actionRow(action)
                }
            }
        }
        .padding(12)
        .frame(width: 250)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(
                Color.dockSurface2)
        )
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachment actions")
    }

    private func actionRow(_ action: AttachmentPopoverAction) -> some View {
        let unavailable = (action == .pasteImage && !pasteImageAvailable)
        return Button {
            onSelect(action)
        } label: {
            HStack(spacing: 9) {
                DockIcon(action.icon)
                    .frame(width: 16)
                Text(action.title)
                Spacer()
            }
            .dockFont(.body, weight: .medium)
            .foregroundStyle(unavailable ? Color.dockMetadataText : Color.dockPrimaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .disabled(unavailable)
        .help(action == .folder ? "Insert a folder path into the message" : action.title)
        .accessibilityLabel(unavailable ? "\(action.title), unavailable" : action.title)
    }

    private var snippetsRow: some View {
        DockMenu {
            ForEach(AttachmentPopoverPresentation.promptSnippets) { snippet in
                Button(snippet.label) { onSelectSnippet(snippet.text) }
            }
        } label: {
            HStack(spacing: 9) {
                DockIcon(AttachmentPopoverAction.promptSnippets.icon)
                    .frame(width: 16)
                Text(AttachmentPopoverAction.promptSnippets.title)
                Spacer()
                DockIcon(.caretRight)
                    .dockFont(.metadata, weight: .semibold)
            }
            .dockFont(.body, weight: .medium)
            .foregroundStyle(Color.dockPrimaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityLabel("Prompt snippets")
    }
}
