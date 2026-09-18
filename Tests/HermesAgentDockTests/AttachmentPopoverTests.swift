import Foundation
import AppKit
import Testing
@testable import HermesAgentDock

struct AttachmentPopoverTests {
    @Test func exposesAttachmentActionsInStableOrder() {
        #expect(AttachmentPopoverAction.allCases.map(\.id) == [
            "files", "folder", "images", "paste-image", "url", "prompt-snippets"
        ])
    }

    @Test func acceptsOnlyHTTPAndHTTPSURLsWithAHost() {
        #expect(AttachmentPopoverPresentation.validatedURL(from: "https://example.com/path")?.absoluteString == "https://example.com/path")
        #expect(AttachmentPopoverPresentation.validatedURL(from: "http://localhost:8080")?.host == "localhost")
        #expect(AttachmentPopoverPresentation.validatedURL(from: "file:///private/secret") == nil)
        #expect(AttachmentPopoverPresentation.validatedURL(from: "javascript:alert(1)") == nil)
        #expect(AttachmentPopoverPresentation.validatedURL(from: "https://") == nil)
    }

    @Test func treatsPickerCancellationAsNoError() {
        let cancellation = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        #expect(AttachmentPopoverPresentation.importerErrorMessage(cancellation) == nil)
        #expect(AttachmentPopoverPresentation.importerErrorMessage(NSError(domain: NSCocoaErrorDomain, code: 257)) == "Could not choose attachments: The file couldn’t be opened because you don’t have permission to view it.")
    }

    @Test func insertsAValidatedURLWithoutChangingTheExistingDraft() {
        #expect(AttachmentPopoverPresentation.insertingURL("https://example.com", into: "Keep this draft") == "Keep this draft\nhttps://example.com")
        #expect(AttachmentPopoverPresentation.insertingURL(" https://example.com ", into: "") == "https://example.com")
        #expect(AttachmentPopoverPresentation.insertingURL("https://example.com", into: "  Keep this draft  ") == "  Keep this draft  \nhttps://example.com")
        #expect(AttachmentPopoverPresentation.insertingURL("file:///tmp/a", into: "draft") == nil)
    }

    @Test func insertsPromptSnippetWithoutChangingDraftWhitespace() {
        #expect(AttachmentPopoverPresentation.insertingSnippet("Summarize this.", into: "  Keep this draft  ") == "  Keep this draft  \nSummarize this.")
    }

    @Test func rejectsUnsupportedFilesAndReportsThem() {
        let unsupported = URL(fileURLWithPath: "/tmp/attachment.txt")
        var stagedImages: [URL] = []
        var stagedPDFs: [URL] = []
        var errors: [String] = []

        AttachmentPopoverFileSelection.process(
            [unsupported],
            stageImage: { stagedImages.append($0) },
            stagePDF: { stagedPDFs.append($0) },
            reportError: { errors.append($0) }
        )

        #expect(stagedImages.isEmpty)
        #expect(stagedPDFs.isEmpty)
        #expect(errors == ["Unsupported attachment: attachment.txt"])
    }

    @Test @MainActor func fileSelectionUsesTheRealPDFStagingPath() throws {
        let model = DockModel(
            defaults: UserDefaults(suiteName: "AttachmentPopoverTests")!,
            approvalSoundPlayer: {}
        )
        let pdfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-popover-test.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdfURL)
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        AttachmentPopoverFileSelection.process(
            [pdfURL],
            stageImage: model.stageImageFile,
            stagePDF: model.stagePDFFile,
            reportError: model.reportAttachmentError
        )

        #expect(model.pendingPDFURL == pdfURL)
        #expect(model.pendingAttachmentError == nil)
    }

    @Test @MainActor func failedImageStagingPublishesAnActionableError() throws {
        let model = DockModel(
            defaults: UserDefaults(suiteName: "AttachmentPopoverTests")!,
            approvalSoundPlayer: {}
        )
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-popover-corrupt.png")
        try Data("not an image".utf8).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        AttachmentPopoverFileSelection.process(
            [imageURL],
            stageImage: model.stageImageFile,
            stagePDF: model.stagePDFFile,
            reportError: model.reportAttachmentError
        )

        #expect(model.pendingImages.isEmpty)
        #expect(model.pendingAttachmentError == "Could not attach image: attachment-popover-corrupt.png could not be read.")
    }

    @Test @MainActor func mixedSelectionKeepsEarlierAttachmentFailureVisible() throws {
        let model = DockModel(
            defaults: UserDefaults(suiteName: "AttachmentPopoverTests-mixed")!,
            approvalSoundPlayer: {}
        )
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-popover-valid.png")
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let data = representation.representation(using: .png, properties: [:]) else {
            Issue.record("Could not create test image")
            return
        }
        try data.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        AttachmentPopoverFileSelection.process(
            [URL(fileURLWithPath: "/tmp/rejected.txt"), imageURL],
            stageImage: model.stageImageFile,
            stagePDF: model.stagePDFFile,
            reportError: model.reportAttachmentError,
            clearErrors: model.clearAttachmentErrors
        )

        #expect(model.pendingImages.count == 1)
        #expect(model.pendingAttachmentError == "Unsupported attachment: rejected.txt")
    }

    @Test @MainActor func invalidClipboardImagePublishesAnActionableError() {
        let model = DockModel(
            defaults: UserDefaults(suiteName: "AttachmentPopoverTests-paste")!,
            approvalSoundPlayer: {}
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(Data("not an image".utf8), forType: .png)
        defer { pasteboard.clearContents() }

        #expect(model.pasteImageFromPasteboard() == false)
        #expect(model.pendingAttachmentError == "Could not paste image: the clipboard image could not be read.")
    }

    @Test func promptSnippetsAreNonEmptyAndHaveStableLabels() {
        #expect(AttachmentPopoverPresentation.promptSnippets.map(\.label) == ["Summarize", "Extract action items", "Review this"])
        #expect(AttachmentPopoverPresentation.promptSnippets.allSatisfy { !$0.text.isEmpty })
    }
}
