import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Herm

struct AttachmentPopoverTests {
    @Test func exposesAttachmentActionsInStableOrder() {
        #expect(
            AttachmentPopoverAction.allCases.map(\.id) == [
                "files", "folder", "capture-window", "saved-prompts", "conversation", "images", "paste-image", "url",
                "prompt-snippets",
            ])
    }

    @Test func sharedPickerUsesTheSelectedAttachmentKind() {
        #expect(AttachmentPopoverFilePicker.files.allowedContentTypes == [.data])
        #expect(AttachmentPopoverFilePicker.images.allowedContentTypes == [.png, .jpeg, .image, .pdf])
        #expect(AttachmentPopoverFilePicker.folder.allowedContentTypes == [.folder])
        #expect(AttachmentPopoverFilePicker.files.allowsMultipleSelection)
        #expect(AttachmentPopoverFilePicker.images.allowsMultipleSelection)
        #expect(!AttachmentPopoverFilePicker.folder.allowsMultipleSelection)
    }

    @Test func acceptsOnlyHTTPAndHTTPSURLsWithAHost() {
        #expect(
            AttachmentPopoverPresentation.validatedURL(from: "https://example.com/path")?.absoluteString
                == "https://example.com/path")
        #expect(AttachmentPopoverPresentation.validatedURL(from: "http://localhost:8080")?.host == "localhost")
        #expect(AttachmentPopoverPresentation.validatedURL(from: "file:///private/secret") == nil)
        #expect(AttachmentPopoverPresentation.validatedURL(from: "javascript:alert(1)") == nil)
        #expect(AttachmentPopoverPresentation.validatedURL(from: "https://") == nil)
    }

    @Test func treatsPickerCancellationAsNoError() {
        let cancellation = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        #expect(AttachmentPopoverPresentation.importerErrorMessage(cancellation) == nil)
        #expect(
            AttachmentPopoverPresentation.importerErrorMessage(NSError(domain: NSCocoaErrorDomain, code: 257))
                == "Could not choose attachments: The file couldn’t be opened because you don’t have permission to view it."
        )
    }

    @Test func insertsAValidatedURLWithoutChangingTheExistingDraft() {
        #expect(
            AttachmentPopoverPresentation.insertingURL("https://example.com", into: "Keep this draft")
                == "Keep this draft\nhttps://example.com")
        #expect(AttachmentPopoverPresentation.insertingURL(" https://example.com ", into: "") == "https://example.com")
        #expect(
            AttachmentPopoverPresentation.insertingURL("https://example.com", into: "  Keep this draft  ")
                == "  Keep this draft  \nhttps://example.com")
        #expect(AttachmentPopoverPresentation.insertingURL("file:///tmp/a", into: "draft") == nil)
    }

    @Test func insertsPromptSnippetWithoutChangingDraftWhitespace() {
        #expect(
            AttachmentPopoverPresentation.insertingSnippet("Summarize this.", into: "  Keep this draft  ")
                == "  Keep this draft  \nSummarize this.")
    }

    @Test func routesMarkdownAndTextFilesToGenericAttachments() {
        let files = [URL(fileURLWithPath: "/tmp/README.md"), URL(fileURLWithPath: "/tmp/attachment.txt")]
        var stagedFiles: [URL] = []
        var stagedImages: [URL] = []
        var stagedPDFs: [URL] = []
        var errors: [String] = []

        AttachmentPopoverFileSelection.process(
            files,
            stageImage: { stagedImages.append($0) },
            stagePDF: { stagedPDFs.append($0) },
            stageFile: { stagedFiles.append($0) },
            reportError: { errors.append($0) }
        )

        #expect(stagedImages.isEmpty)
        #expect(stagedPDFs.isEmpty)
        #expect(stagedFiles == files)
        #expect(errors.isEmpty)
    }

    @Test @MainActor func markdownDropStagesOneRemovableFileContext() throws {
        let model = DockModel(approvalSoundPlayer: {})
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("README.md")
        try Data("# Read me".utf8).write(to: url)
        AttachmentPopoverFileSelection.process(
            [url, url], stageImage: model.stageImageFile,
            stagePDF: model.stagePDFFile, stageFile: model.stageFile, reportError: model.reportAttachmentError)
        let context = try #require(model.attachedContexts.first)
        #expect(model.attachedContexts.count == 1)
        #expect(context.kind == .file)
        #expect(context.title == "README.md")
        #expect(context.attachmentURL == url)
        #expect(model.pendingAttachmentError == nil)
        model.removeAttachedContext(context)
        #expect(model.attachedContexts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test @MainActor func genericFilesRejectDirectoriesAndOversizedFiles() throws {
        let model = DockModel(approvalSoundPlayer: {})
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.stageFile(at: directory)
        #expect(model.attachedContexts.isEmpty)
        #expect(model.pendingAttachmentError == "Choose a file. Use Folder to insert a directory path.")
        let url = directory.appendingPathComponent("large.txt")
        try Data(repeating: 0, count: 8 * 1024 * 1024 + 1).write(to: url)
        model.stageFile(at: url)
        #expect(model.attachedContexts.isEmpty)
        #expect(model.pendingAttachmentError == "File attachments are limited to 8 MB.")
    }

    @Test @MainActor func genericFileUploadUsesExistingContractAndRetainsFilesWithoutCapability() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("README.md")
        let bytes = Data("# Read me".utf8)
        try bytes.write(to: url)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setData(Data("file icon bitmap".utf8), forType: .tiff)
        #expect(!DockModel.pasteboardHoldsImageOnly(pasteboard))
        #expect(AttachmentPopoverFileSelection.fileURLs(from: pasteboard) == [url])
        for supported in [true, false] {
            let rpc = ComposerFileAttachmentRPC(supported: supported)
            let model = DockModel(
                sessionAgentStateFileURL: directory.appendingPathComponent("state.json"),
                defaults: UserDefaults(suiteName: "AttachmentUpload-\(UUID())")!,
                approvalSoundPlayer: {}, initialSessionID: "file-session", rpcClient: rpc)
            AttachmentPopoverFileSelection.process(
                AttachmentPopoverFileSelection.fileURLs(from: pasteboard),
                stageImage: model.stageImageFile, stagePDF: model.stagePDFFile,
                stageFile: model.stageFile, reportError: model.reportAttachmentError)
            #expect(model.pendingImages.isEmpty)
            var finished = false
            var submissionError: String?
            model.send(onSubmission: {
                submissionError = $0
                finished = true
            })
            for _ in 0..<200 where !finished { try await Task.sleep(for: .milliseconds(10)) }
            #expect(finished)
            let uploads = rpc.calls.filter { $0.0 == "file.attach" }
            if supported {
                let upload = try #require(uploads.first?.1)
                #expect(upload["session_id"] as? String == "file-session")
                #expect(upload["name"] as? String == "README.md")
                #expect(
                    upload["data_url"] as? String == "data:application/octet-stream;base64,"
                        + bytes.base64EncodedString())
                #expect(
                    rpc.calls.contains {
                        $0.0 == "prompt.submit" && ($0.1["text"] as? String)?.contains("@file:README.md") == true
                    })
                #expect(submissionError == nil)
            } else {
                #expect(uploads.isEmpty)
                #expect(!rpc.calls.contains { $0.0 == "prompt.submit" })
                #expect(model.attachedContexts.first?.attachmentURL == url)
                #expect(submissionError != nil)
            }
        }
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
            stageFile: model.stageFile,
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
            stageFile: model.stageFile,
            reportError: model.reportAttachmentError
        )

        #expect(model.pendingImages.isEmpty)
        #expect(
            model.pendingAttachmentError == "Could not attach image: attachment-popover-corrupt.png could not be read.")
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
            let data = representation.representation(using: .png, properties: [:])
        else {
            Issue.record("Could not create test image")
            return
        }
        try data.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        AttachmentPopoverFileSelection.process(
            [FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).txt"), imageURL],
            stageImage: model.stageImageFile,
            stagePDF: model.stagePDFFile,
            stageFile: model.stageFile,
            reportError: model.reportAttachmentError,
            clearErrors: model.clearAttachmentErrors
        )

        #expect(model.pendingImages.count == 1)
        #expect(model.pendingAttachmentError?.hasPrefix("Could not attach file:") == true)
    }

    @Test @MainActor func bitmapAndTextPastesKeepTheirExistingClassification() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(Data(), forType: .png)
        #expect(DockModel.pasteboardHoldsImageOnly(pasteboard))
        pasteboard.setString("https://example.com/image.png", forType: .string)
        #expect(DockModel.pasteboardHoldsImageOnly(pasteboard))
        pasteboard.setString("Keep this text", forType: .string)
        #expect(!DockModel.pasteboardHoldsImageOnly(pasteboard))
        #expect(AttachmentPopoverFileSelection.fileURLs(from: pasteboard).isEmpty)
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
        #expect(
            AttachmentPopoverPresentation.promptSnippets.map(\.label) == [
                "Summarize", "Extract action items", "Review this",
            ])
        #expect(AttachmentPopoverPresentation.promptSnippets.allSatisfy { !$0.text.isEmpty })
    }
}

@MainActor
private final class ComposerFileAttachmentRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var calls: [(String, [String: Any])] = []
    let supported: Bool
    init(supported: Bool) { self.supported = supported }
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        switch method {
        case "gateway.capabilities": return ["per_session_exclusive_submit": supported]
        case "file.attach": return ["attached": true, "ref_text": "@file:README.md"]
        case "prompt.submit": return ["status": "streaming"]
        default: return [:]
        }
    }
}
