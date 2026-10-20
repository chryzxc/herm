import AppKit

extension DockModel {
    /// Paste as text (Command-Shift-V) remains available without attachment conversion.
    func stageLargePaste() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string), text.utf8.count >= 32 * 1024 else {
            return false
        }
        guard text.utf8.count <= 8 * 1024 * 1024 else { return false }
        do {
            let url = try QuickDraftStore.shared.storePastedText(Data(text.utf8))
            var context = ChatContext(
                id: UUID().uuidString, title: "Pasted text · \(text.utf8.count / 1024) KiB",
                body: "Read the attached pasted-text file \(url.lastPathComponent) as context.")
            context.attachmentURL = url
            context.kind = .file
            attachedContexts.append(context)
        } catch {
            reportAttachmentError("The pasted text could not be attached; paste as text to keep it editable.")
            return false
        }
        return true
    }

    func captureDesktopWindow() {
        let owner = navigationSessionID
        let generation = sessionResumeGeneration
        Task { @MainActor in
            do {
                let captured = try await DesktopCaptureService.shared.capture()
                guard navigationSessionID == owner, sessionResumeGeneration == generation else { return }
                if stageImage(captured.image) {
                    attachedContexts.append(
                        ChatContext(id: UUID().uuidString, title: "Window capture", body: captured.context))
                }
            } catch { if navigationSessionID == owner { reportAttachmentError(error.localizedDescription) } }
        }
    }
}
