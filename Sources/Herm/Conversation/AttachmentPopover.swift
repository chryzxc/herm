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
    case url
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
        case .url: "URL"
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
        case .url: .link
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

    static func validatedURL(from rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = url.host,
            !host.isEmpty
        else { return nil }
        return url
    }

    static func insertingURL(_ rawValue: String, into draft: String) -> String? {
        guard let url = validatedURL(from: rawValue) else { return nil }
        let value = url.absoluteString
        return draft.isEmpty ? value : "\(draft)\n\(value)"
    }

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
    let onInsertURL: (String) -> Void
    let onSelectSnippet: (String) -> Void
    /// Group rooms carry text only, so they offer just the inserting actions.
    var actions = AttachmentPopoverAction.allCases

    @State private var urlText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ATTACH OR INSERT")
                .dockFont(.metadata, weight: .semibold, design: .monospaced)
                .tracking(0.7)
                .foregroundStyle(Color.dockAccent)

            ForEach(actions) { action in
                if action == .url {
                    urlRow
                } else if action == .promptSnippets {
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

    private var urlRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                DockIcon(AttachmentPopoverAction.url.icon)
                    .frame(width: 16)
                Text("URL")
                    .dockFont(.body, weight: .medium)
                Spacer()
            }
            HStack(spacing: 6) {
                DockTextField("https://…", text: $urlText)
                    .textFieldStyle(.dockGlass)
                    .dockFont(.metadata)
                    .onSubmit(insertURL)
                Button("Insert", action: insertURL)
                    .buttonStyle(.dockCompact)
                    .dockFont(.metadata, weight: .semibold)
                    .disabled(AttachmentPopoverPresentation.validatedURL(from: urlText) == nil)
            }
            Text("Only http:// and https:// URLs are accepted.")
                .dockFont(.compactStatus, weight: .regular)
                .foregroundStyle(Color.dockMetadataText)
        }
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

    private func insertURL() {
        guard AttachmentPopoverPresentation.validatedURL(from: urlText) != nil else { return }
        onInsertURL(urlText)
        urlText = ""
    }
}
