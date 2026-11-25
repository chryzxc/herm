import AppKit
import Foundation
import Testing

@testable import Herm

@MainActor
private final class ComposerQueueRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var requests: [(method: String, params: [String: Any])] = []
    var holdRedirect = false
    var redirectStatus = "redirected"
    var steerStatus: String?
    var pendingRedirect: CheckedContinuation<[String: Any], Never>?
    var holdImageAttachment = false
    var pendingImageAttachment: CheckedContinuation<[String: Any], Never>?
    var holdInterrupt = false
    var pendingInterrupt: CheckedContinuation<[String: Any], Never>?
    var submitted: [String] {
        // Queue assertions compare user material; rendering context is covered by submission tests.
        requests.filter { $0.method == "prompt.submit" }.compactMap { $0.params["text"] as? String }.map(
            GenerativeUIIntegration.displayUserText)
    }

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        if method == "session.redirect" {
            if holdRedirect {
                return await withCheckedContinuation { pendingRedirect = $0 }
            }
            return ["status": redirectStatus]
        }
        if method == "session.steer", let steerStatus { return ["status": steerStatus] }
        if method == "session.interrupt" {
            if holdInterrupt { return await withCheckedContinuation { pendingInterrupt = $0 } }
            return ["status": "interrupted"]
        }
        if method == "image.attach_bytes", holdImageAttachment {
            return await withCheckedContinuation { pendingImageAttachment = $0 }
        }
        if method == "image.attach_bytes" { return ["attached": true] }
        if method == "gateway.capabilities" { return ["per_session_exclusive_submit": true] }
        if method == "file.attach" { return ["attached": true, "ref_text": "@file:document.pdf"] }
        if method == "session.resume" {
            return ["session_id": params["session_id"] ?? "", "messages": []]
        }
        return ["status": "streaming"]
    }

    func finishRedirect(status: String) {
        let continuation = pendingRedirect
        pendingRedirect = nil
        continuation?.resume(returning: ["status": status])
    }

    func finishImageAttachment() {
        let continuation = pendingImageAttachment
        pendingImageAttachment = nil
        continuation?.resume(returning: ["attached": true])
    }

    func finishInterrupt(status: String = "interrupted") {
        let continuation = pendingInterrupt
        pendingInterrupt = nil
        continuation?.resume(returning: ["status": status])
    }
}

@MainActor
struct ComposerQueueOrderingTests {
    private func model(_ client: ComposerQueueRPCClient) -> DockModel {
        DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "composer-order-\(UUID().uuidString).json"),
            initialSessionID: "composer-order", rpcClient: client)
    }

    private func complete(_ model: DockModel) {
        model.receiveGatewayEvent(
            "message.complete", params: ["session_id": "composer-order", "payload": ["text": "Done"]])
    }

    private func parkFirstMessage(_ model: DockModel) {
        model.status = .working
        model.isSending = true
        model.draft = "Earlier message"
        model.queueDraft()
    }

    private func waitForSubmissions(_ count: Int, client: ComposerQueueRPCClient) async throws {
        let deadline = Date().addingTimeInterval(2)
        while client.submitted.count < count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.submitted.count == count)
    }

    @Test(arguments: ["rejected", "redirected", "queued"])
    func redirectReplyAfterCompletionPreservesSubmissionOrder(status: String) async throws {
        let client = ComposerQueueRPCClient()
        client.holdRedirect = true
        defer { client.finishRedirect(status: "rejected") }
        let model = model(client)
        model.status = .working
        model.isSending = true
        model.draft = "Earlier message"
        model.submitComposerInput()
        let deadline = Date().addingTimeInterval(2)
        while client.pendingRedirect == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.pendingRedirect != nil)
        complete(model)
        model.draft = "Later message"

        model.submitComposerInput()

        #expect(model.currentSessionQueuedPrompts.map(\.text) == ["Later message"])
        #expect(!model.messages.contains { $0.role == .user && $0.text == "Later message" })
        client.finishRedirect(status: status)
        if status == "queued" {
            let deadline = Date().addingTimeInterval(2)
            while !model.isSending, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.isSending)
            #expect(client.submitted.isEmpty)
            // Hermes owns the accepted follow-up; it completes before the local tail sends.
            complete(model)
        }
        try await waitForSubmissions(1, client: client)
        if status == "rejected" {
            #expect(client.submitted == ["Earlier message"])
            complete(model)
            try await waitForSubmissions(2, client: client)
            #expect(client.submitted == ["Earlier message", "Later message"])
        } else {
            #expect(client.submitted == ["Later message"])
        }
    }

    @Test(arguments: [false, true])
    func newDraftWaitsBehindOlderQueuedMessages(useBotRouting: Bool) async throws {
        let client = ComposerQueueRPCClient()
        let model = model(client)
        parkFirstMessage(model)
        model.draft = "Later message"

        if useBotRouting { model.submitComposerInput(bots: []) } else { model.submitComposerInput() }
        model.draft = "Newest message"
        model.submitComposerInput()

        #expect(model.draft.isEmpty)
        #expect(
            model.currentSessionQueuedPrompts.map(\.text) == ["Earlier message", "Later message", "Newest message"])
        #expect(!model.messages.contains { $0.role == .user && $0.text == "Later message" })
        #expect(client.submitted.isEmpty)
        complete(model)
        try await waitForSubmissions(1, client: client)
        #expect(client.submitted == ["Earlier message"])
        complete(model)
        try await waitForSubmissions(2, client: client)
        #expect(client.submitted == ["Earlier message", "Later message"])
        complete(model)
        try await waitForSubmissions(3, client: client)
        #expect(client.submitted == ["Earlier message", "Later message", "Newest message"])
        #expect(model.currentSessionQueuedPrompts.isEmpty)
        #expect(!client.requests.contains { $0.method == "session.redirect" || $0.method == "session.steer" })
    }

    @Test func steeringAQueuedPromptRedirectsTheLiveTurn() async throws {
        let client = ComposerQueueRPCClient()
        let model = model(client)
        parkFirstMessage(model)
        let queued = try #require(model.currentSessionQueuedPrompts.first)
        #expect(model.canSteerQueuedPrompt(queued))

        model.steerQueuedPrompt(queued.id)

        #expect(model.currentSessionQueuedPrompts.isEmpty)
        let deadline = Date().addingTimeInterval(2)
        while !client.requests.contains(where: { $0.method == "session.redirect" }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.requests.contains { $0.method == "session.redirect" })
    }

    @Test func backgroundCompletionSendsItsOwnQueueInOrder() async throws {
        let client = ComposerQueueRPCClient()
        let model = model(client)
        model.sessionStorageID = "saved-chat"
        model.sessionProfileID = "original-profile"
        model.storageIDsByRuntimeID["composer-order"] = "saved-chat"
        parkFirstMessage(model)
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-1.7".utf8).write(to: pdf)
        defer { try? FileManager.default.removeItem(at: pdf) }
        model.pendingPDFURLs = [pdf]
        model.draft = "Later message"
        model.queueDraft()

        model.newChat()
        model.sessionID = "other-runtime"
        model.sessionProfileID = "other-profile"
        model.status = .working
        model.isSending = true
        model.draft = "Another conversation's draft"

        model.receiveGatewayEvent(
            "message.complete",
            params: ["session_id": "composer-order", "payload": ["session_id": "other-runtime", "text": "Done"]])
        #expect(model.queuedPrompts.count == 2)
        complete(model)
        try await waitForSubmissions(1, client: client)
        #expect(client.submitted == ["Earlier message"])
        #expect(model.queuedPrompts.map(\.text) == ["Later message"])

        complete(model)
        try await waitForSubmissions(2, client: client)
        #expect(client.submitted == ["Earlier message", "Later message\n\n@file:document.pdf"])
        let attachment = try #require(client.requests.first { $0.method == "file.attach" })
        #expect(attachment.params["session_id"] as? String == "composer-order")
        #expect(attachment.params["profile"] as? String == "original-profile")
        for submission in client.requests where submission.method == "prompt.submit" {
            #expect(submission.params["session_id"] as? String == "composer-order")
            #expect(submission.params["profile"] as? String == "original-profile")
        }
        #expect(model.sessionID == "other-runtime")
        #expect(model.messages.isEmpty)
        #expect(model.draft == "Another conversation's draft")
        #expect(model.isSending)
    }

    @Test func backgroundQueueWaitsForRedirectReply() async throws {
        let client = ComposerQueueRPCClient()
        client.holdRedirect = true
        defer { client.finishRedirect(status: "rejected") }
        let model = model(client)
        model.status = .working
        model.isSending = true
        model.draft = "Redirect first"
        model.submitComposerInput()
        let deadline = Date().addingTimeInterval(2)
        while client.pendingRedirect == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(client.pendingRedirect != nil)
        model.draft = "Later message"
        model.queueDraft()
        model.newChat()

        complete(model)
        #expect(client.submitted.isEmpty)
        client.finishRedirect(status: "rejected")

        try await waitForSubmissions(1, client: client)
        #expect(client.submitted == ["Redirect first"])
        complete(model)
        try await waitForSubmissions(2, client: client)
        #expect(client.submitted == ["Redirect first", "Later message"])
    }

    @Test func backgroundCompletionAfterStopKeepsQueuedMessages() async throws {
        let client = ComposerQueueRPCClient()
        let model = model(client)
        parkFirstMessage(model)
        let stop = try #require(model.stop())
        await stop.value
        model.newChat()

        complete(model)

        #expect(model.queuedPrompts.map(\.text) == ["Earlier message"])
        #expect(client.submitted.isEmpty)
    }

    @Test func reopeningStoppedChatDoesNotSendItsQueueUntilRequested() async throws {
        let client = ComposerQueueRPCClient()
        let model = model(client)
        defer { model.delegationMonitoringTask?.cancel() }
        parkFirstMessage(model)
        await model.stop()?.value
        complete(model)
        model.newChat()
        let session = HermesSession(
            id: "composer-order", title: "Chat", preview: "", startedAt: nil, messageCount: 0,
            source: "herm")

        #expect(await model.resumeSession(session, reportFailure: true))

        #expect(model.currentSessionQueuedPrompts.map(\.text) == ["Earlier message"])
        #expect(client.submitted.isEmpty)
        model.submitComposerInput()
        try await waitForSubmissions(1, client: client)
        #expect(client.submitted == ["Earlier message"])
    }

    @Test func redirectRefusalDuringStopDoesNotSteerOrSendAgain() async throws {
        let client = ComposerQueueRPCClient()
        client.holdRedirect = true
        client.holdInterrupt = true
        defer {
            client.finishRedirect(status: "rejected")
            client.finishInterrupt()
        }
        let model = model(client)
        model.status = .working
        model.isSending = true
        model.draft = "Earlier message"
        model.submitComposerInput()
        let deadline = Date().addingTimeInterval(2)
        while client.pendingRedirect == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(client.pendingRedirect != nil)

        let stop = try #require(model.stop())
        while client.pendingInterrupt == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(client.pendingInterrupt != nil)
        model.redirectTurn(with: "Later message", sessionID: "composer-order")
        client.finishRedirect(status: "rejected")
        while model.isRedirectInFlight, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.isRedirectInFlight)
        client.finishInterrupt()
        await stop.value

        #expect(client.requests.filter { $0.method == "session.redirect" }.count == 1)
        #expect(!client.requests.contains { $0.method == "session.steer" })
        #expect(model.currentSessionQueuedPrompts.map(\.text) == ["Earlier message", "Later message"])
        #expect(client.submitted.isEmpty)
    }

    // Herm missed the turn end, so it still shows working; Hermes rejects the
    // steer because nothing runs. The prompt must send, not re-queue forever.
    @Test func steerRejectedForAMissedTurnEndSendsThePromptAsTheNextTurn() async throws {
        let client = ComposerQueueRPCClient()
        client.redirectStatus = "rejected"
        client.steerStatus = "rejected"
        let model = model(client)
        parkFirstMessage(model)
        let queued = try #require(model.currentSessionQueuedPrompts.first)

        model.steerQueuedPrompt(queued.id)

        try await waitForSubmissions(1, client: client)
        #expect(model.currentSessionQueuedPrompts.isEmpty)
    }

    @Test func sendNowStopsTheTurnAndSendsTheUnsteerablePromptFirst() async throws {
        let client = ComposerQueueRPCClient()
        let model = model(client)
        parkFirstMessage(model)
        model.draft = "With a quote"
        model.replyQuote = ReplyQuote(author: "Hermes", text: "Earlier reply")
        model.queueDraft()
        let attached = try #require(model.currentSessionQueuedPrompts.last)
        #expect(!model.canSteerQueuedPrompt(attached))

        model.sendQueuedPromptNow(attached.id)

        #expect(model.currentSessionQueuedPrompts.map(\.text) == ["With a quote", "Earlier message"])
        let deadline = Date().addingTimeInterval(2)
        while !client.requests.contains(where: { $0.method == "session.interrupt" }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        complete(model)
        try await waitForSubmissions(1, client: client)
        #expect(client.submitted.first?.contains("With a quote") == true)
    }

    // Desktop parity: Hermes acks Stop synchronously, so Send now must not wait
    // for the stopped turn's terminal frame (which can lag or never arrive).
    @Test func sendNowSendsOnInterruptAckAndIgnoresTheStoppedTurnTail() async throws {
        let client = ComposerQueueRPCClient()
        let model = model(client)
        parkFirstMessage(model)
        model.draft = "With a quote"
        model.replyQuote = ReplyQuote(author: "Hermes", text: "Earlier reply")
        model.queueDraft()
        let attached = try #require(model.currentSessionQueuedPrompts.last)

        model.sendQueuedPromptNow(attached.id)
        try await waitForSubmissions(1, client: client)

        #expect(client.submitted.first?.contains("With a quote") == true)
        #expect(client.requests.last { $0.method == "prompt.submit" }?.params["queued"] as? Bool == true)
        #expect(model.isSending)
        complete(model)
        #expect(model.isSending)
        #expect(client.submitted.count == 1)
        #expect(model.currentSessionQueuedPrompts.map(\.text) == ["Earlier message"])
    }

    @Test func sendNowHeldByAnInFlightRedirectSendsWhenTheRedirectReplies() async throws {
        let client = ComposerQueueRPCClient()
        client.holdRedirect = true
        defer { client.finishRedirect(status: "redirected") }
        let model = model(client)
        model.status = .working
        model.isSending = true
        model.draft = "Steer this"
        model.submitComposerInput()
        let deadline = Date().addingTimeInterval(2)
        while client.pendingRedirect == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.draft = "With a quote"
        model.replyQuote = ReplyQuote(author: "Hermes", text: "Earlier reply")
        model.queueDraft()
        let attached = try #require(model.currentSessionQueuedPrompts.last)

        model.sendQueuedPromptNow(attached.id)
        while !client.requests.contains(where: { $0.method == "session.interrupt" }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.submitted.isEmpty)

        client.finishRedirect(status: "redirected")
        try await waitForSubmissions(1, client: client)
        #expect(client.submitted.first?.contains("With a quote") == true)
    }

    @Test func acceptedBackendQueueAlreadyCompletedBeforeRedirectReplyStillReleasesTheTail()
        async throws
    {
        let client = ComposerQueueRPCClient()
        client.holdRedirect = true
        defer { client.finishRedirect(status: "queued") }
        let model = model(client)
        model.status = .working
        model.isSending = true
        model.draft = "Earlier message"
        model.submitComposerInput()
        let deadline = Date().addingTimeInterval(2)
        while client.pendingRedirect == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.pendingRedirect != nil)
        complete(model)
        model.draft = "Later message"
        model.submitComposerInput()
        model.receiveGatewayEvent(
            "message.start", params: ["session_id": "composer-order", "payload": [:]])
        complete(model)
        #expect(client.submitted.isEmpty)

        client.finishRedirect(status: "queued")

        try await waitForSubmissions(1, client: client)
        #expect(client.submitted == ["Later message"])
        #expect(model.currentSessionQueuedPrompts.isEmpty)
    }

    @Test(arguments: [false, true])
    func acknowledgedBackendQueueKeepsLaterInputBehindItUntilItsTurnCompletes(firstTurnFails: Bool)
        async throws
    {
        let client = ComposerQueueRPCClient()
        client.holdRedirect = true
        defer { client.finishRedirect(status: "queued") }
        let model = model(client)
        model.status = .working
        model.isSending = true
        model.draft = "Earlier message"
        model.submitComposerInput()
        let deadline = Date().addingTimeInterval(2)
        while client.pendingRedirect == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.pendingRedirect != nil)
        client.holdRedirect = false
        client.finishRedirect(status: "queued")
        try await Task.sleep(for: .milliseconds(20))
        model.draft = "Later message"

        model.submitComposerInput()

        #expect(model.currentSessionQueuedPrompts.map(\.text) == ["Later message"])
        if firstTurnFails {
            model.receiveGatewayEvent(
                "error", params: ["session_id": "composer-order", "payload": ["message": "Failed"]])
        } else {
            complete(model)
        }
        #expect(client.submitted.isEmpty)
        #expect(model.currentSessionQueuedPrompts.map(\.text) == ["Later message"])
        model.receiveGatewayEvent(
            "message.start", params: ["session_id": "composer-order", "payload": [:]])
        complete(model)
        try await waitForSubmissions(1, client: client)
        #expect(client.submitted == ["Later message"])
        #expect(client.requests.filter { $0.method == "session.redirect" }.count == 1)
        #expect(model.currentSessionQueuedPrompts.isEmpty)
    }

    @Test func backendQueuedTurnFinishingOffscreenDoesNotBlockTheConversationWhenReopened()
        async throws
    {
        let client = ComposerQueueRPCClient()
        client.holdRedirect = true
        defer { client.finishRedirect(status: "queued") }
        let model = model(client)
        model.status = .working
        model.isSending = true
        model.draft = "Earlier message"
        model.submitComposerInput()
        let deadline = Date().addingTimeInterval(2)
        while client.pendingRedirect == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.pendingRedirect != nil)
        client.finishRedirect(status: "queued")
        try await Task.sleep(for: .milliseconds(20))
        model.newChat()
        complete(model)
        model.receiveGatewayEvent(
            "message.start", params: ["session_id": "composer-order", "payload": [:]])
        complete(model)
        let session = HermesSession(
            id: "composer-order", title: "Chat", preview: "", startedAt: nil, messageCount: 0,
            source: "herm")
        model.resumeSession(session)
        let resumeDeadline = Date().addingTimeInterval(2)
        while model.sessionID != "composer-order" || model.isRestoringSession || model.status != .idle,
            Date() < resumeDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.sessionID == "composer-order")
        #expect(model.status == .idle)
        #expect(!model.hasQueuedOrRedirectingPrompt)
        model.draft = "After reopening"

        model.submitComposerInput()

        try await waitForSubmissions(1, client: client)
        #expect(client.submitted == ["After reopening"])
    }

    @Test(arguments: [false, true])
    func stoppingAnAcknowledgedOrPendingBackendQueueAllowsAFreshSubmission(
        acknowledgeBeforeStop: Bool
    ) async throws {
        let client = ComposerQueueRPCClient()
        client.holdRedirect = true
        defer { client.finishRedirect(status: "queued") }
        let model = model(client)
        model.status = .working
        model.isSending = true
        model.draft = "Earlier message"
        model.submitComposerInput()
        let deadline = Date().addingTimeInterval(2)
        while client.pendingRedirect == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.pendingRedirect != nil)
        if acknowledgeBeforeStop {
            client.finishRedirect(status: "queued")
            try await Task.sleep(for: .milliseconds(20))
        }
        await model.stop()?.value
        complete(model)
        if !acknowledgeBeforeStop {
            client.finishRedirect(status: "queued")
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.hasQueuedOrRedirectingPrompt)
        #expect(!model.isSending)
        model.draft = "After stopping"

        model.submitComposerInput()

        try await waitForSubmissions(1, client: client)
        #expect(client.submitted == ["After stopping"])
    }

    @Test(arguments: [false, true])
    func freshDraftResumesAnIdleQueueInOrder(useDirectSend: Bool) async throws {
        let client = ComposerQueueRPCClient()
        let model = model(client)
        parkFirstMessage(model)
        await model.stop()?.value
        complete(model)
        #expect(!model.isSending)
        #expect(model.currentSessionQueuedPrompts.count == 1)
        model.draft = "Later message"

        if useDirectSend { model.send() } else { model.submitComposerInput() }

        try await waitForSubmissions(1, client: client)
        #expect(client.submitted == ["Earlier message"])
        #expect(model.currentSessionQueuedPrompts.map(\.text) == ["Later message"])
        complete(model)
        try await waitForSubmissions(2, client: client)
        #expect(client.submitted == ["Earlier message", "Later message"])
        #expect(
            client.requests.filter { $0.method == "prompt.submit" }.allSatisfy {
                $0.params["queued"] as? Bool == true
            })
        #expect(model.currentSessionQueuedPrompts.isEmpty)
    }

    @Test(arguments: [false, true])
    func queuedDraftKeepsItsWholePayload(hasEarlierMessage: Bool) async throws {
        let client = ComposerQueueRPCClient()
        let model = model(client)
        if hasEarlierMessage {
            parkFirstMessage(model)
        } else {
            model.status = .working
            model.isSending = true
        }
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "composer-order-\(UUID().uuidString).png")
        try Data([1, 2, 3]).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let attachment = ImageAttachment(
            image: NSImage(size: NSSize(width: 2, height: 2)), fileURL: imageURL)
        let context = ChatContext(
            kanbanTask: KanbanTaskSummary(
                id: "t1", title: "Fix login", status: "ready", detail: "Users get 500",
                priority: nil, assignee: nil))
        let quote = ReplyQuote(author: "Hermes", text: "Previous answer")
        let pdfURL = imageURL.deletingPathExtension().appendingPathExtension("pdf")
        try Data("%PDF-1.4".utf8).write(to: pdfURL)
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        model.pendingImages = [attachment]
        model.stagePDFFile(at: pdfURL)
        model.attachedContexts = [context]
        model.replyQuote = quote
        model.draft = "Later message"

        model.submitComposerInput()

        #expect(model.pendingImages.isEmpty)
        #expect(model.pendingPDFURLs.isEmpty)
        #expect(model.attachedContexts.isEmpty)
        #expect(model.replyQuote == nil)
        #expect(model.currentSessionQueuedPrompts.last?.text == "Later message")
        #expect(model.currentSessionQueuedPrompts.last?.images.map(\.id) == [attachment.id])
        #expect(model.currentSessionQueuedPrompts.last?.pdfURLs == [pdfURL])
        #expect(!model.messages.contains { $0.role == .user && $0.text == "Later message" })
        if hasEarlierMessage {
            complete(model)
            try await waitForSubmissions(1, client: client)
            #expect(client.submitted == ["Earlier message"])
        }
        complete(model)
        try await waitForSubmissions(hasEarlierMessage ? 2 : 1, client: client)
        let expected =
            ChatContext.prompt(quote.composing("Later message"), contexts: [context])
            + "\n\n@file:document.pdf"
        #expect(client.submitted == (hasEarlierMessage ? ["Earlier message", expected] : [expected]))
        #expect(client.requests.filter { $0.method == "image.attach_bytes" }.count == 1)
        #expect(client.requests.filter { $0.method == "file.attach" }.count == 1)
        #expect(model.messages.last { $0.role == .user }?.images.count == 1)
    }

    @Test func immediateSendClearsAttachmentsBeforeUploadAndPreservesTheNextDraft() async throws {
        let client = ComposerQueueRPCClient()
        client.holdImageAttachment = true
        defer { client.finishImageAttachment() }
        let model = model(client)
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "composer-clear-\(UUID().uuidString).png")
        try Data([1, 2, 3]).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let pdfURL = imageURL.deletingPathExtension().appendingPathExtension("pdf")
        try Data("%PDF-1.4".utf8).write(to: pdfURL)
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        model.pendingImages = [
            ImageAttachment(image: NSImage(size: NSSize(width: 2, height: 2)), fileURL: imageURL)
        ]
        model.stagePDFFile(at: pdfURL)
        model.draft = "First message"

        model.submitComposerInput()

        #expect(model.draft.isEmpty)
        #expect(model.pendingImages.isEmpty)
        #expect(model.pendingPDFURLs.isEmpty)
        let deadline = Date().addingTimeInterval(2)
        while client.pendingImageAttachment == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.pendingImageAttachment != nil)
        model.draft = "Next draft"
        let nextImage = ImageAttachment(
            image: NSImage(size: NSSize(width: 2, height: 2)), fileURL: imageURL)
        model.pendingImages = [nextImage]
        model.stagePDFFile(at: pdfURL)
        client.finishImageAttachment()
        try await waitForSubmissions(1, client: client)
        #expect(model.draft == "Next draft")
        #expect(model.pendingImages.map(\.id) == [nextImage.id])
        #expect(model.pendingPDFURLs == [pdfURL])
    }
}
