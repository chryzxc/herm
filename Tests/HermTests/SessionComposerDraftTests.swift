import AppKit
import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
private final class ComposerDraftRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var requests: [String] = []
    var runtimeRevision = 0
    var failResume = false
    var worktreeDirectory: String?
    var requestParameters: [(String, [String: Any])] = []

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append(method)
        requestParameters.append((method, params))
        if method == "session.resume", let worktreeDirectory {
            return ["session_id": "created", "session_key": "stored-created", "info": ["cwd": worktreeDirectory]]
        }
        if method == "session.resume" {
            if failResume { throw HermesGateway.GatewayError.malformedResponse }
            let storedID = params["session_id"] as? String ?? ""
            runtimeRevision += 1
            return [
                "session_id": "runtime-\(runtimeRevision)", "session_key": storedID, "messages": [],
            ]
        }
        if method == "session.create" {
            return ["session_id": "created", "session_key": "stored-created"]
        }
        return ["status": "streaming"]
    }
}

@MainActor
struct SessionComposerDraftTests {
    @Test func nativeEditsKeepSelectionOnOneOccurrenceAndClearItWhenThatOccurrenceIsDeleted() {
        let composer = ComposerText()
        let bot = BotSummary(
            id: "default", name: "Nexus", title: nil, description: nil, model: nil,
            isActive: false, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
            isHidden: false, hasAvatar: false, isDefault: true)
        composer.text = "@default @default hey"
        composer.selectBot(bot, range: NSRange(location: 0, length: 8))
        composer.noteEdit(range: NSRange(location: 0, length: 0), replacement: "👋 ")
        composer.text = "👋 " + composer.text
        #expect(composer.botMentions.first?.range == NSRange(location: 3, length: 8))
        composer.noteEdit(range: NSRange(location: 3, length: 9), replacement: "")
        composer.text = "👋 @default hey"
        #expect(composer.botMentions.isEmpty)
    }

    @Test func editingInsideASelectedTokenDoesNotSelectTheTypedReplacement() {
        let composer = ComposerText()
        let bot = BotSummary(
            id: "default", name: "Nexus", title: nil, description: nil, model: nil,
            isActive: false, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
            isHidden: false, hasAvatar: false, isDefault: true)
        composer.text = "@default hey"
        composer.selectBot(bot)
        composer.text = "@defaul hey"
        composer.text = "@default hey"
        #expect(composer.botMentions.isEmpty)
        composer.selectBot(bot)
        composer.noteEdit(range: NSRange(location: 8, length: 0), replacement: "x")
        composer.text = "@defaultx hey"
        #expect(composer.botMentions.isEmpty)
    }

    @Test func pickerSelectionSurvivesDraftRestorationAndQueueEditingButNotRetyping() {
        let rpc = ComposerDraftRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        let bot = BotSummary(
            id: "default", name: "Nexus", title: nil, description: nil, model: nil,
            isActive: false, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
            isHidden: false, hasAvatar: false, isDefault: true)
        model.sessionID = "origin"
        model.draft = "@default hey"
        model.composer.selectBot(bot)
        model.saveComposerDraft()
        model.composer.reset(to: "another draft")
        model.restoreComposerDraft(for: model.composerDraftKey)
        #expect(model.composer.selectedBots.map(\.id) == ["default"])

        #expect(model.composer.navigate(direction: -1, history: ["previous message"]))
        #expect(model.composer.selectedBots.isEmpty)
        #expect(model.composer.navigate(direction: 1, history: ["previous message"]))
        #expect(model.composer.selectedBots.map(\.id) == ["default"])

        model.status = .working
        model.isSending = true
        model.queueDraft()
        #expect(model.composer.selectedBots.isEmpty)
        if let queued = model.currentSessionQueuedPrompts.first { model.editQueuedPrompt(queued.id) }
        #expect(model.composer.selectedBots.map(\.id) == ["default"])
        model.draft = ""
        model.draft = "@default hey"
        #expect(model.composer.selectedBots.isEmpty)
    }

    private func session(_ id: String, profile: String = "default") -> HermesSession {
        HermesSession(
            id: id, profileID: profile, title: id, preview: "", startedAt: nil, messageCount: 0,
            source: "test")
    }

    private func model(_ rpc: ComposerDraftRPCClient) -> DockModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "composer-draft-\(UUID())")
        return DockModel(
            sessionAgentStateFileURL: directory.appendingPathComponent("agents.json"),
            defaults: UserDefaults(suiteName: "composer-draft-\(UUID())")!,
            botActivityFileURL: directory.appendingPathComponent("bots.json"), rpcClient: rpc
        )
    }

    @Test func typingDoesNotPublishWorkspaceChangesOrRewriteSavedDrafts() {
        let rpc = ComposerDraftRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.sessionProfileID = "default"
        let savedText = String(repeating: "Saved draft text ", count: 8_192)
        for index in 0..<500 {
            model.sessionID = "saved-\(index)"
            model.sessionStorageID = model.sessionID
            model.draft = savedText
            model.saveComposerDraft()
        }
        model.sessionID = "typing"
        model.sessionStorageID = "typing"
        model.draft = ""
        var workspaceChanges = 0
        var textChanges = 0
        let workspace = model.objectWillChange.sink { workspaceChanges += 1 }
        let editor = model.composer.$text.dropFirst().sink { _ in textChanges += 1 }
        defer {
            workspace.cancel()
            editor.cancel()
        }

        for _ in 0..<2_000 { model.draft.append("x") }

        #expect(workspaceChanges == 0)
        #expect(textChanges == 2_000)
        #expect(model.composerDrafts.count == 500)
        #expect(model.composerDrafts.values.allSatisfy { $0.text == savedText })
        #expect(rpc.requests.isEmpty)
    }

    @Test func restoringTextPublishesOnlyItsFinalValue() {
        let rpc = ComposerDraftRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.draft = "Saved text"
        model.saveComposerDraft()
        model.draft = "Other text"
        var workspaceChanges = 0
        var restoredValues: [String] = []
        let workspace = model.objectWillChange.sink { workspaceChanges += 1 }
        let editor = model.composer.$text.dropFirst().sink { restoredValues.append($0) }
        defer {
            workspace.cancel()
            editor.cancel()
        }

        model.restoreComposerDraft(for: model.composerDraftKey)

        #expect(restoredValues == ["Saved text"])
        #expect(workspaceChanges == 0)
    }

    @Test func restoringAnEmptyDraftDoesNotPublishUnchangedState() {
        let rpc = ComposerDraftRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        var workspaceChanges = 0
        var textChanges = 0
        let workspace = model.objectWillChange.sink { workspaceChanges += 1 }
        let editor = model.composer.$text.dropFirst().sink { _ in textChanges += 1 }
        defer {
            workspace.cancel()
            editor.cancel()
        }

        model.restoreComposerDraft(for: model.composerDraftKey)

        #expect(workspaceChanges == 0)
        #expect(textChanges == 0)
    }

    @Test func largeDraftCacheReusesImagesAndPublishesOnlyChangedFields() {
        let rpc = ComposerDraftRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        let image = NSImage(size: NSSize(width: 4_096, height: 4_096))
        let attachment = ImageAttachment(
            image: image, fileURL: URL(fileURLWithPath: "/draft/image.png"))
        model.pendingImages = [attachment]
        model.pendingPDFURL = URL(fileURLWithPath: "/draft/document.pdf")
        model.attachedContexts = [
            ChatContext(id: "notes", title: "Notes", body: "Read these notes")
        ]
        model.replyQuote = ReplyQuote(author: "Herm", text: "Quoted reply")
        model.pendingAttachmentError = "Retained error"
        model.pendingPDFError = "Retained PDF error"
        let largeText = String(repeating: "Large draft text ", count: 65_536)
        model.draft = largeText
        let keys = (0..<500).map {
            SessionComposerDraft.Key(profileID: "default", sessionID: "draft-\($0)")
        }
        for key in keys {
            model.sessionProfileID = key.profileID
            model.sessionID = key.sessionID
            model.sessionStorageID = key.sessionID
            model.saveComposerDraft()
        }
        var workspaceChanges = 0
        var textChanges = 0
        let workspace = model.objectWillChange.sink { workspaceChanges += 1 }
        let editor = model.composer.$text.dropFirst().sink { _ in textChanges += 1 }
        defer {
            workspace.cancel()
            editor.cancel()
        }

        let clock = ContinuousClock()
        let key = model.composerDraftKey
        let elapsed = clock.measure {
            for _ in 0..<1_000 {
                model.saveComposerDraft()
                model.restoreComposerDraft(for: key)
            }
        }

        #expect(workspaceChanges == 0)
        #expect(textChanges == 0)
        #expect(model.pendingImages.first?.image === image)
        #expect(model.composerDrafts.values.allSatisfy { $0.images.first?.image === image })
        #expect(rpc.requests.isEmpty)
        print(
            "Composer draft cache: 1,000 unchanged save/restore pairs with 500 session drafts: \(elapsed)"
        )

        model.sessionStorageID = keys[0].sessionID
        model.draft = largeText + "A"
        model.saveComposerDraft()
        model.sessionStorageID = keys[1].sessionID
        model.draft = largeText + "B"
        model.saveComposerDraft()
        model.restoreComposerDraft(for: keys[1])
        workspaceChanges = 0
        textChanges = 0
        var restorationChanges = 0
        let changedElapsed = clock.measure {
            for index in 0..<1_000 {
                let beforeSave = workspaceChanges
                model.saveComposerDraft()
                restorationChanges += workspaceChanges - beforeSave
                let next = keys[index % 2]
                // Changing the published session identity legitimately updates the workspace.
                model.sessionStorageID = next.sessionID
                let beforeRestore = workspaceChanges
                model.restoreComposerDraft(for: next)
                restorationChanges += workspaceChanges - beforeRestore
            }
        }

        #expect(restorationChanges == 0)
        #expect(workspaceChanges == 1_000)
        #expect(textChanges == 1_000)
        #expect(model.draft == largeText + "B")
        #expect(model.pendingImages.first?.image === image)
        print(
            "Composer draft cache: 1,000 transitions between different 1 MiB drafts: \(changedElapsed)"
        )
    }

    @Test func restoringMatchingTextStillResetsEditorNavigation() {
        let rpc = ComposerDraftRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.composer.navigate(direction: -1, history: ["Recalled prompt"])
        model.composer.pendingCaret = 5
        model.composer.isCompletionOpen = true
        model.saveComposerDraft()

        model.restoreComposerDraft(for: model.composerDraftKey)

        #expect(model.draft == "Recalled prompt")
        #expect(!model.composer.isBrowsingHistory)
        #expect(model.composer.pendingCaret == nil)
        #expect(!model.composer.isCompletionOpen)
    }

    @Test func switchingSessionsRestoresTheWholeDraftAcrossRuntimeAliases() async throws {
        let rpc = ComposerDraftRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        let sessionA = session("a")
        let sessionB = session("b")
        #expect(await model.resumeSession(sessionA, reportFailure: true))

        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "draft-image-\(UUID()).png")
        try Data([1, 2, 3]).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let image = ImageAttachment(
            image: NSImage(size: NSSize(width: 2, height: 2)), fileURL: imageURL)
        let pdfURL = URL(fileURLWithPath: "/tmp/draft-document.pdf")
        var context = ChatContext(id: "file", title: "Notes", body: "Read these notes")
        context.attachmentURL = URL(fileURLWithPath: "/tmp/notes.txt")
        context.inlineToken = "@notes"
        let quote = ReplyQuote(author: "Herm", text: "Earlier reply")
        model.draft = "  Continue with @notes\n"
        model.pendingImages = [image]
        model.pendingPDFURL = pdfURL
        model.attachedContexts = [context]
        model.replyQuote = quote
        model.pendingAttachmentError = "Choose the missing file again."
        model.pendingPDFError = "Choose a smaller PDF."
        model.composer.pendingCaret = 12
        model.composer.isCompletionOpen = true

        #expect(await model.resumeSession(sessionB, reportFailure: true))
        #expect(model.draft.isEmpty)
        #expect(model.pendingImages.isEmpty)
        #expect(model.pendingPDFURL == nil)
        #expect(model.attachedContexts.isEmpty)
        #expect(model.replyQuote == nil)
        #expect(model.pendingAttachmentError == nil)
        #expect(model.pendingPDFError == nil)
        #expect(model.composer.pendingCaret == nil)
        #expect(!model.composer.isCompletionOpen)
        #expect(FileManager.default.fileExists(atPath: imageURL.path))
        model.draft = "Draft B"

        #expect(await model.resumeSession(sessionA, reportFailure: true))
        #expect(model.sessionID == "runtime-3")
        #expect(model.draft == "  Continue with @notes\n")
        #expect(model.pendingImages.map(\.id) == [image.id])
        #expect(model.pendingPDFURL == pdfURL)
        #expect(model.attachedContexts == [context])
        #expect(model.replyQuote == quote)
        #expect(model.pendingAttachmentError == "Choose the missing file again.")
        #expect(model.pendingPDFError == "Choose a smaller PDF.")
        #expect(!rpc.requests.contains("prompt.submit"))

        #expect(await model.resumeSession(sessionA, reportFailure: true))
        #expect(model.draft == "  Continue with @notes\n")
        #expect(model.pendingImages.map(\.id) == [image.id])
        #expect(model.replyQuote == quote)
        #expect(await model.resumeSession(sessionB, reportFailure: true))
        #expect(model.draft == "Draft B")
    }

    @Test func identicalBotChatNamesKeepSeparateProfileDrafts() async {
        let rpc = ComposerDraftRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        let botA = session("Bot Chat", profile: "bot-a")
        let botB = session("Bot Chat", profile: "bot-b")
        #expect(await model.resumeSession(botA, reportFailure: true, profileID: "bot-a"))
        model.draft = "For bot A"
        model.replyQuote = ReplyQuote(author: "Bot A", text: "A reply")

        #expect(await model.resumeSession(botB, reportFailure: true, profileID: "bot-b"))
        #expect(model.draft.isEmpty)
        #expect(model.replyQuote == nil)
        model.draft = "For bot B"
        #expect(await model.resumeSession(botA, reportFailure: true, profileID: "bot-a"))
        #expect(model.draft == "For bot A")
        #expect(model.replyQuote?.author == "Bot A")
        #expect(await model.resumeSession(botB, reportFailure: true, profileID: "bot-b"))
        #expect(model.draft == "For bot B")
    }

    @Test func profilePickerSavesTheDraftUnderItsOriginalProfile() async {
        let rpc = ComposerDraftRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.setProfileScope("bot-a")
        let original = session("a", profile: "bot-a")
        #expect(await model.resumeSession(original, reportFailure: true))
        model.draft = "Belongs to bot A"

        model.setProfileScope("bot-b")
        #expect(model.draft.isEmpty)
        model.setProfileScope("bot-a")
        #expect(await model.resumeSession(original, reportFailure: true))
        #expect(model.draft == "Belongs to bot A")
    }

    @Test func worktreeSessionMustConfirmDirectoryBeforeSending() async throws {
        let rpc = ComposerDraftRPCClient()
        rpc.worktreeDirectory = "/tmp/wrong"
        let model = model(rpc)
        defer { model.shutdown() }
        model.draft = "Keep this draft"
        model.newChatMovingDraft(projectPath: "/tmp/worktree-a")
        do {
            _ = try await model.createAuthorizedSession(source: "test")
            Issue.record("An unconfirmed worktree was accepted")
        } catch {}
        #expect(model.pendingWorktreeDirectory == "/tmp/worktree-a")
        #expect(model.draft == "Keep this draft")
        let create = try #require(rpc.requestParameters.first { $0.0 == "session.create" })
        #expect(create.1["cwd"] as? String == "/tmp/worktree-a")
        #expect(create.1["cwd_explicit"] as? Bool == true)
        rpc.worktreeDirectory = "/tmp/worktree-a"
        #expect(try await model.createAuthorizedSession(source: "test") == "created")
        #expect(model.pendingWorktreeDirectory == nil)
        #expect(model.sessionWorkspace?.cwd == "/tmp/worktree-a")
        #expect(rpc.requests.filter { $0 == "session.create" }.count == 1)
    }

    @Test func failedWorktreeConfirmationKeepsTheSendDraftForRetry() async throws {
        let rpc = ComposerDraftRPCClient()
        rpc.worktreeDirectory = "/tmp/wrong"
        let model = model(rpc)
        defer { model.shutdown() }
        model.draft = "Keep this draft"
        model.newChatMovingDraft(projectPath: "/tmp/worktree-a")
        model.send()
        for _ in 0..<200 where model.isSending {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.draft == "Keep this draft")
        #expect(model.pendingWorktreeDirectory == "/tmp/worktree-a")
        #expect(!rpc.requests.contains("prompt.submit"))
    }

    @Test func worktreeTaskMovesTheDraftInsteadOfCopyingIt() async {
        let rpc = ComposerDraftRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.setProfileScope("bot-a")
        #expect(await model.resumeSession(session("existing", profile: "bot-a"), reportFailure: true))
        model.draft = "Build the parity flow"
        model.newChatMovingDraft(projectPath: "/tmp/worktree-a")
        #expect(model.draft == "Build the parity flow")
        #expect(await model.resumeSession(session("existing", profile: "bot-a"), reportFailure: true))
        #expect(model.draft.isEmpty)
    }

    @Test func newChatDraftsFollowTheirProfileAndProjectUntilSessionCreation() async throws {
        let rpc = ComposerDraftRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.setProfileScope("bot-a")
        model.newChat(projectPath: "/tmp/project-a")
        model.draft = "New project draft"
        #expect(
            await model.resumeSession(session("existing", profile: "bot-a"), reportFailure: true))
        model.draft = "Existing chat draft"
        model.newChat(projectPath: "/tmp/project-b")
        #expect(model.draft.isEmpty)
        model.newChat(projectPath: "/tmp/project-a")
        #expect(model.draft == "New project draft")
        model.setProfileScope("bot-b")
        #expect(model.draft.isEmpty)
        model.setProfileScope("bot-a")
        model.newChat(projectPath: "/tmp/project-a")
        #expect(model.draft == "New project draft")

        _ = try await model.createAuthorizedSession(source: "test")
        #expect(
            await model.resumeSession(session("existing", profile: "bot-a"), reportFailure: true))
        #expect(model.draft == "Existing chat draft")
        #expect(
            await model.resumeSession(
                session("stored-created", profile: "bot-a"), reportFailure: true))
        #expect(model.draft == "New project draft")
        model.newChat(projectPath: "/tmp/project-a")
        #expect(model.draft.isEmpty)
    }

    @Test func consumedDraftsDoNotReappearAfterSendingQueueingOrClearing() async throws {
        let rpc = ComposerDraftRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        let original = session("a")
        #expect(await model.resumeSession(original, reportFailure: true))
        model.draft = "Send this"
        model.newChat()
        #expect(await model.resumeSession(original, reportFailure: true))
        model.send()
        let deadline = Date().addingTimeInterval(2)
        while !rpc.requests.contains("prompt.submit"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rpc.requests.contains("prompt.submit"))
        model.newChat()
        #expect(await model.resumeSession(original, reportFailure: true))
        #expect(model.draft.isEmpty)

        model.draft = "Queue this"
        model.status = .working
        model.isSending = true
        model.queueDraft()
        model.newChat()
        #expect(await model.resumeSession(original, reportFailure: true))
        #expect(model.draft.isEmpty)
        #expect(model.currentSessionQueuedPrompts.map(\.text) == ["Queue this"])

        model.draft = "Clear this"
        model.newChat()
        #expect(await model.resumeSession(original, reportFailure: true))
        model.draft = ""
        model.newChat()
        #expect(await model.resumeSession(original, reportFailure: true))
        #expect(model.draft.isEmpty)
    }

    @Test func deletingASessionDiscardsItsDraftAndTemporaryImages() async throws {
        let rpc = ComposerDraftRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        let original = session("a")
        #expect(await model.resumeSession(original, reportFailure: true))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "discard-draft-\(UUID()).png")
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = ImageAttachment(
            image: NSImage(size: NSSize(width: 2, height: 2)), fileURL: url, ownsTemporaryFile: true)
        model.pendingImages = [image]
        model.draft = "Discard with the session"
        model.newChat()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(await model.deleteSession(original))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await model.resumeSession(original, reportFailure: true))
        #expect(model.draft.isEmpty)
        #expect(model.pendingImages.isEmpty)
    }

    @Test func removedAttachmentsAndReplyQuotesStayRemovedAfterReturning() async throws {
        let rpc = ComposerDraftRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        let original = session("a")
        #expect(await model.resumeSession(original, reportFailure: true))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remove-draft-\(UUID()).png")
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = ImageAttachment(
            image: NSImage(size: NSSize(width: 2, height: 2)), fileURL: url, ownsTemporaryFile: true)
        model.pendingImages = [image]
        model.pendingPDFURL = URL(fileURLWithPath: "/tmp/document.pdf")
        model.attachedContexts = [ChatContext(id: "notes", title: "Notes", body: "Notes")]
        model.replyQuote = ReplyQuote(author: "Herm", text: "Reply")
        model.newChat()
        #expect(await model.resumeSession(original, reportFailure: true))
        model.removePendingImage(image)
        model.removePendingPDF()
        model.attachedContexts = []
        model.replyQuote = nil
        model.newChat()
        #expect(await model.resumeSession(original, reportFailure: true))
        #expect(model.pendingImages.isEmpty)
        #expect(model.pendingPDFURL == nil)
        #expect(model.attachedContexts.isEmpty)
        #expect(model.replyQuote == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aFailedResumeDoesNotLoseTheSavedDraft() async {
        let rpc = ComposerDraftRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        let original = session("a")
        #expect(await model.resumeSession(original, reportFailure: true))
        model.draft = "Retain through a failed load"
        model.newChat()
        rpc.failResume = true
        #expect(await model.resumeSession(original, reportFailure: true) == false)
        #expect(model.draft == "Retain through a failed load")
        model.newChat()
        rpc.failResume = false
        #expect(await model.resumeSession(original, reportFailure: true))
        #expect(model.draft == "Retain through a failed load")
    }
}
