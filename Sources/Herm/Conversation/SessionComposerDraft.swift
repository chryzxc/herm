import Foundation

/// Unsent input belongs to its conversation, independently of the mounted editor.
struct SessionComposerDraft {
    struct Key: Hashable {
        let profileID: String?
        let sessionID: String?
        var projectPath: String? = nil
    }

    let text: String
    let images: [ImageAttachment]
    let pdfURL: URL?
    let contexts: [ChatContext]
    let replyQuote: ReplyQuote?
    let attachmentError: String?
    let pdfError: String?

    var isEmpty: Bool {
        text.isEmpty && images.isEmpty && pdfURL == nil && contexts.isEmpty
            && replyQuote == nil && attachmentError == nil && pdfError == nil
    }
}

extension DockModel {
    var composerDraftKey: SessionComposerDraft.Key {
        SessionComposerDraft.Key(
            profileID: Self.normalizedProfileID(sessionProfileID),
            sessionID: navigationSessionID,
            projectPath: navigationSessionID == nil ? newSessionProjectPath : nil
        )
    }

    func saveComposerDraft() {
        let snapshot = SessionComposerDraft(
            text: draft, images: pendingImages, pdfURL: pendingPDFURL,
            contexts: attachedContexts, replyQuote: replyQuote,
            attachmentError: pendingAttachmentError, pdfError: pendingPDFError
        )
        composerDrafts[composerDraftKey] = snapshot.isEmpty ? nil : snapshot
    }

    func restoreComposerDraft(for key: SessionComposerDraft.Key) {
        // Transfer ownership out of the cache so sending/removing an attachment
        // cannot leave an older draft referring to its deleted temporary file.
        let snapshot = composerDrafts.removeValue(forKey: key)
        composer.reset(to: snapshot?.text ?? "")
        // Unchanged published values would invalidate the entire workspace.
        let images = snapshot?.images ?? []
        if !pendingImages.elementsEqual(images, by: { $0.id == $1.id }) { pendingImages = images }
        if pendingPDFURL != snapshot?.pdfURL { pendingPDFURL = snapshot?.pdfURL }
        let contexts = snapshot?.contexts ?? []
        if attachedContexts != contexts { attachedContexts = contexts }
        if replyQuote != snapshot?.replyQuote { replyQuote = snapshot?.replyQuote }
        if pendingAttachmentError != snapshot?.attachmentError {
            pendingAttachmentError = snapshot?.attachmentError
        }
        if pendingPDFError != snapshot?.pdfError { pendingPDFError = snapshot?.pdfError }
    }

    func discardComposerDraft(for key: SessionComposerDraft.Key) {
        guard let snapshot = composerDrafts.removeValue(forKey: key) else { return }
        cleanupImageAttachments(snapshot.images)
    }
}
