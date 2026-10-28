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
    var botMentions: [ComposerBotMention] = []

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
            attachmentError: pendingAttachmentError, pdfError: pendingPDFError, botMentions: composer.botMentions
        )
        composerDrafts[composerDraftKey] = snapshot.isEmpty ? nil : snapshot
    }

    func restoreComposerDraft(for key: SessionComposerDraft.Key) {
        // Transfer ownership out of the cache so sending/removing an attachment
        // cannot leave an older draft referring to its deleted temporary file.
        let snapshot = composerDrafts.removeValue(forKey: key)
        composer.reset(to: snapshot?.text ?? "")
        composer.botMentions = snapshot?.botMentions ?? []
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

    /// Starts a new chat in `projectPath` and moves the current draft,
    /// attachments included, into it instead of leaving it behind.
    func newChatMovingDraft(projectPath: String) {
        let previous = composerDraftKey
        newChat(projectPath: projectPath)
        composerDrafts[composerDraftKey] = composerDrafts.removeValue(forKey: previous)
        restoreComposerDraft(for: composerDraftKey)
    }

    func discardComposerDraft(for key: SessionComposerDraft.Key) {
        guard let snapshot = composerDrafts.removeValue(forKey: key) else { return }
        cleanupImageAttachments(snapshot.images)
    }
}
