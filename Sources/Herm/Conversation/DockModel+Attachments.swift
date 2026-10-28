import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    /// Text keeps its normal paste. Browsers add the image's URL or name as a
    /// one-token string beside the bitmap; that still counts as an image paste.
    static func pasteboardHoldsImageOnly(_ pasteboard: NSPasteboard) -> Bool {
        // Finder supplies an icon bitmap alongside the actual file URLs.
        guard AttachmentPopoverFileSelection.fileURLs(from: pasteboard).isEmpty else { return false }
        guard pasteboard.types?.contains(where: { $0 == .png || $0 == .tiff }) == true else { return false }
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return true
        }
        return text.isEmpty || !text.contains(where: \.isWhitespace)
    }

    @discardableResult
    func pasteImageFromPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        guard Self.pasteboardHoldsImageOnly(pasteboard) else { return false }
        let imageType = pasteboard.types?.first { $0 == .png || $0 == .tiff }
        guard let imageType else {
            return false
        }
        guard let data = pasteboard.data(forType: imageType),
            let nsImage = NSImage(data: data)
        else {
            pendingAttachmentError = "Could not paste image: the clipboard image could not be read."
            return false
        }
        return stageImage(nsImage)
    }

    func stageImageFile(at url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let nsImage = NSImage(contentsOf: url) else {
            pendingAttachmentError = "Could not attach image: \(url.lastPathComponent) could not be read."
            DebugLog.write("model: could not load image at \(url.path)")
            return
        }
        pendingImages.append(ImageAttachment(image: nsImage, fileURL: url))
        DebugLog.write("model: picked image \(url.lastPathComponent)")
    }

    func stagePDFFile(at url: URL) {
        pendingPDFError = nil
        guard url.pathExtension.lowercased() == "pdf" else {
            pendingPDFError = "Only PDF files can be attached as documents."
            return
        }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize
        else {
            pendingPDFError = "The PDF size could not be read."
            return
        }
        guard size <= 25 * 1024 * 1024 else {
            pendingPDFError = "PDF attachments are limited to 25 MB."
            return
        }
        pendingPDFURL = url
    }

    func stageFile(at url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                reportAttachmentError("Choose a file. Use Folder to insert a directory path.")
                return
            }
            guard let size = values.fileSize, size <= 8 * 1024 * 1024 else {
                reportAttachmentError("File attachments are limited to 8 MB.")
                return
            }
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                reportAttachmentError("Could not read the selected file. Select it again.")
                return
            }
            let id = "file:" + url.standardizedFileURL.path
            guard !attachedContexts.contains(where: { $0.id == id }) else { return }
            var context = ChatContext(
                id: id, title: url.lastPathComponent,
                body: "Read the attached file \(url.lastPathComponent) as context.")
            context.kind = .file
            context.attachmentURL = url
            attachedContexts.append(context)
        } catch {
            reportAttachmentError("Could not attach file: \(Self.safeUserDiagnostic(error.localizedDescription))")
        }
    }

    func reportPDFError(_ message: String) {
        pendingPDFError = message
    }

    func reportAttachmentError(_ message: String) {
        pendingAttachmentError = message
    }

    func clearAttachmentErrors() {
        pendingAttachmentError = nil
        pendingPDFError = nil
    }

    func removePendingPDF() {
        pendingPDFURL = nil
        pendingPDFError = nil
    }

    func removePendingImage(_ image: ImageAttachment) {
        cleanupImageAttachment(image)
        pendingImages.removeAll { $0.id == image.id }
    }

    func clearPendingImages() {
        cleanupImageAttachments(pendingImages)
        pendingImages = []
    }

    @discardableResult
    func stageImage(_ nsImage: NSImage) -> Bool {
        guard let tiff = nsImage.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            pendingAttachmentError = "Could not paste image: the image could not be encoded."
            DebugLog.write("model: failed to encode pasted image as PNG")
            return false
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-paste-\(UUID().uuidString).png")
        do {
            try png.write(to: tempURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        } catch {
            pendingAttachmentError = "Could not paste image: the image could not be saved."
            DebugLog.write(
                "model: failed to write image temp file: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return false
        }
        pendingImages.append(ImageAttachment(image: nsImage, fileURL: tempURL, ownsTemporaryFile: true))
        DebugLog.write("model: staged pasted image at \(tempURL.lastPathComponent)")
        return true
    }

    /// Reads the image's text on-device and stages it in the draft; the image itself stays attached.
    func stageText(from attachment: ImageAttachment) async {
        guard extractingImageTextIDs.insert(attachment.id).inserted else { return }
        defer { extractingImageTextIDs.remove(attachment.id) }
        let session = navigationSessionID
        let text = await ImageTextRecognizer.text(in: attachment.image)
        guard navigationSessionID == session, pendingImages.contains(where: { $0.id == attachment.id }) else { return }
        guard let text else {
            pendingAttachmentError = "No text was found in that image."
            return
        }
        stageDraft(text)
    }

    func cleanupImageAttachments(_ attachments: [ImageAttachment]) {
        attachments.forEach(cleanupImageAttachment)
    }

    func cleanupImageAttachment(_ attachment: ImageAttachment?) {
        guard let attachment, attachment.ownsTemporaryFile else { return }
        try? FileManager.default.removeItem(at: attachment.fileURL)
    }
}
