import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    /// Bumps a row's recency locally so the rail reorders immediately instead
    /// of waiting for the session index round-trip. The open session is
    /// inserted when the index has not listed it yet (a just-created chat).
    func touchSession(sessionID rawSessionID: String?, at date: Date, preview: String? = nil) {
        guard let rawSessionID, !rawSessionID.isEmpty else { return }
        let sessionID = rowSessionID(rawSessionID)
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            guard sessionID == navigationSessionID else { return }
            sessions.insert(
                HermesSession(
                    id: sessionID,
                    profileID: sessionProfileID ?? profileScopeID,
                    title: currentSessionTitle ?? "",
                    preview: preview ?? "",
                    startedAt: date,
                    updatedAt: date,
                    messageCount: 0,
                    source: HermesFeatureIDs.sessionSource
                ), at: 0)
            return
        }
        let session = sessions[index]
        guard session.lastUpdatedAt.map({ date > $0 }) ?? true else { return }
        sessions[index] = HermesSession(
            id: session.id,
            profileID: session.profileID,
            title: session.title,
            preview: preview ?? session.preview,
            startedAt: session.startedAt,
            updatedAt: date,
            messageCount: session.messageCount,
            source: session.source,
            isHidden: session.isHidden,
            isWorking: session.isWorking,
            hasUnreadUpdate: session.hasUnreadUpdate
        )
    }

    /// Tracks working/unread state for a session that is not necessarily the
    /// one currently open, so the dock and sidebars can surface every session
    /// with activity, not just the focused one. Reuses the same gateway
    /// stream and `Self.isUnreadUpdateEvent` predicate that already drive the
    /// current session's `hasUnreadResponse`.
    func updateSessionActivity(sessionID rawSessionID: String, isWorking: Bool? = nil, unread: Bool? = nil) {
        if isWorking != nil { sessionActivityGeneration &+= 1 }
        let sessionID = rowSessionID(rawSessionID)
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let session = sessions[index]
        sessions[index] = HermesSession(
            id: session.id,
            profileID: session.profileID,
            title: session.title,
            preview: session.preview,
            startedAt: session.startedAt,
            updatedAt: session.updatedAt,
            messageCount: session.messageCount,
            source: session.source,
            isHidden: session.isHidden,
            isWorking: isWorking ?? session.isWorking,
            hasUnreadUpdate: unread ?? session.hasUnreadUpdate
        )
        if let unread {
            var unreadIDs = Set(defaults.stringArray(forKey: unreadSessionIDsKey) ?? [])
            if unread { unreadIDs.insert(sessionID) } else { unreadIDs.remove(sessionID) }
            defaults.set(Array(unreadIDs), forKey: unreadSessionIDsKey)
        }
    }

    func updateSessionActivityLabel(sessionID rawSessionID: String, type: String, payload: [String: Any]) {
        let sessionID = rowSessionID(rawSessionID)
        switch type {
        case "tool.call", "tool.start", "tool.use", "tool_use":
            let name =
                (payload["name"] as? String) ?? (payload["tool"] as? String) ?? (payload["tool_name"] as? String)
                ?? "tool"
            let step = ToolStep.describe(name: name, args: Self.textArgs(Self.parseArgsDict(payload["args"])) ?? [:])
            let preview = (payload["tool_preview"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            sessionActivityLabels[sessionID] = [step.title, step.detail ?? (preview.isEmpty ? nil : preview)].compactMap
            { $0 }.joined(separator: ": ")
        case "message.start":
            sessionActivityLabels[sessionID] = nil
        default:
            if Self.isUnreadUpdateEvent(type) { sessionActivityLabels[sessionID] = nil }
        }
    }

    /// Restores unread state persisted across launches for sessions the
    /// in-memory index does not already carry a live value for.
    func applyPersistedUnreadState(_ loaded: [HermesSession]) -> [HermesSession] {
        let unreadIDs = Set(defaults.stringArray(forKey: unreadSessionIDsKey) ?? [])
        guard !unreadIDs.isEmpty else { return loaded }
        return loaded.map { session in
            guard unreadIDs.contains(session.id), !session.hasUnreadUpdate else { return session }
            return HermesSession(
                id: session.id,
                profileID: session.profileID,
                title: session.title,
                preview: session.preview,
                startedAt: session.startedAt,
                updatedAt: session.updatedAt,
                messageCount: session.messageCount,
                source: session.source,
                isHidden: session.isHidden,
                isWorking: session.isWorking,
                hasUnreadUpdate: true
            )
        }
    }

    func refreshSessionTokenUsage() {
        guard let id = sessionID, !id.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let result = try? await self?.interruptRPC.sessionUsage(sessionID: id),
                let self, self.sessionID == id
            else { return }
            self.sessionTokenUsage = (id, ControlCenterModel.parseSessionUsage(result).totalTokens)
            self.applyContextUsage(result, sessionID: id)
        }
    }

    func fetchSessionContextDetails() async -> SessionContextSummary? {
        guard let id = sessionID, !id.isEmpty,
            let result = try? await interruptRPC.sessionContextBreakdown(sessionID: id),
            sessionID == id
        else { return nil }
        return ControlCenterModel.parseSessionContext(result)
    }

    func applyContextUsage(_ usage: [String: Any], sessionID id: String) {
        let summary = ControlCenterModel.parseSessionUsage(usage)
        guard let used = summary.contextUsed, let max = summary.contextMax, used > 0, max > 0 else { return }
        sessionContextUsage = (id, used, max)
    }

    // ponytail: ~4 chars/token heuristic for the live stream; session.usage replaces it at turn end.
    static func estimatedTokens(utf8Count: Int) -> Int { (utf8Count + 3) / 4 }

    func refreshSessionIndexAfterActivity() {
        guard !isLoadingSessions else {
            pendingSessionIndexRefresh = true
            return
        }
        guard let refresh = loadSessions() else { return }
        Task { @MainActor [weak self] in
            await refresh.value
            guard let self, self.pendingSessionIndexRefresh else { return }
            self.pendingSessionIndexRefresh = false
            self.refreshSessionIndexAfterActivity()
        }
    }

    static func isUnreadUpdateEvent(_ type: String) -> Bool {
        switch type {
        case "background.complete", "message.complete", "approval.request",
            "clarification.request", "clarify.request", "error":
            true
        default:
            false
        }
    }

    func requestComposerFocus() {
        composerFocusRequest &+= 1
    }

    /// Switches to `session` (or a new chat when nil), then attaches the
    /// context chip. Awaits the switch so its composer reset can't drop it.
    func attachContext(_ context: ChatContext, to session: HermesSession?) async {
        if let session {
            if session.id != sessionID, session.id != sessionStorageID {
                _ = await resumeSession(session, reportFailure: true)
            }
        } else if let path = context.projectPath {
            await startNewChat(in: path)
        } else {
            newChat()
        }
        if !attachedContexts.contains(where: { $0.id == context.id }) {
            attachedContexts.append(context)
        }
        requestComposerFocus()
    }

    /// Points Hermes' browser tools at a CDP endpoint (same as `/browser connect`); nil disconnects.
    /// Hermes keeps it process-wide until the gateway restarts.
    func setHermesBrowser(cdpURL: String?) async throws {
        var params: [String: Any] = ["action": cdpURL == nil ? "disconnect" : "connect"]
        if let cdpURL { params["url"] = cdpURL }
        let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.browserManage.rawValue, params: params)
        if cdpURL != nil, result["connected"] as? Bool != true {
            let detail = (result["messages"] as? [String])?.last ?? "Hermes could not connect to the browser."
            throw NSError(domain: "Herm.AgentBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }

    func removeAttachedContext(_ context: ChatContext) {
        attachedContexts.removeAll { $0.id == context.id }
    }

    func setCompletionNotificationsEnabled(_ enabled: Bool) {
        completionNotificationsEnabled = enabled
        defaults.set(enabled, forKey: completionNotificationsKey)
    }

    func markPopoverHidden() {
        isPopoverVisible = false
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        guard let sessionID, interruptState != .requesting else { return nil }
        interruptGeneration &+= 1
        let requestGeneration = interruptGeneration
        interruptState = .requesting
        return Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await interruptRPC.interrupt(
                    sessionID: sessionID,
                    profileID: sessionProfileID ?? profileScopeID
                )
                // `session.interrupt` stops synchronously (queue purged, no agent
                // wait), so settle now like Hermes Desktop instead of waiting on
                // the unwinding turn's terminal frame, which can lag or never come.
                guard self.interruptGeneration == requestGeneration, self.sessionID == sessionID,
                    self.interruptState == .requesting
                else { return }
                settleStoppedTurn()
            } catch {
                guard self.interruptGeneration == requestGeneration, self.sessionID == sessionID,
                    self.interruptState == .requesting
                else { return }
                interruptState = .failed("Hermes could not be interrupted. Try again.")
                DebugLog.write("model: interrupt failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    func requestControl(_ method: HermesFeatureIDs.ID, params: [String: Any]) async throws -> [String: Any] {
        try await gateway.request(method.rawValue, params: params)
    }

    func registerBackgroundTask(
        id: String, prompt: String, parentSessionID: String, kind: HermesBackgroundTaskKind = .general
    ) {
        guard !id.isEmpty, !backgroundTasks.contains(where: { $0.id == id }) else { return }
        backgroundTasks.append(
            HermesBackgroundTask(
                id: id, parentSessionID: parentSessionID, prompt: prompt, kind: kind, status: .running, output: nil,
                startedAt: .now, completedAt: nil))
        if backgroundTasks.count > 50 { backgroundTasks.removeFirst(backgroundTasks.count - 50) }
    }

    func isSyntheticSubagent(_ id: String) -> Bool {
        synthesizedSubagentIDs.contains(id)
    }

    func submitControlPrompt(_ text: String) async throws {
        guard !isRestoringSession else {
            throw NSError(
                domain: "Herm", code: 409,
                userInfo: [NSLocalizedDescriptionKey: "The previous conversation is still loading."])
        }
        try await gateway.connect()
        if sessionID == nil {
            _ = try await createAuthorizedSession(source: HermesFeatureIDs.sessionSource)
        }
        guard let sessionID else { throw HermesGateway.GatewayError.malformedResponse }
        _ = try await gateway.request(
            HermesFeatureIDs.ID.promptSubmit.rawValue, params: ["session_id": sessionID, "text": text])
    }

    func interruptionNotice(_ kind: HermNotice.Kind, owner: String? = nil, eventID: String? = nil) -> HermNotice {
        let raw = owner ?? navigationSessionID ?? "activity"
        let stable = rowSessionID(raw)
        let profile =
            quickSessionOwners[raw]?.profileID ?? sessions.first(where: { $0.id == stable })?.profileID
            ?? (currentSessionIDs.contains(raw) ? sessionProfileID ?? profileScopeID : nil)
        let request = sessionAttention[raw]?.responseTarget
        let identity =
            eventID ?? ([HermNotice.Kind.completion, .failure].contains(kind) ? completionNoticeIDs[stable] : nil)
            ?? (kind.blocking ? request?.requestID : nil) ?? messages.last?.id.uuidString ?? UUID().uuidString
        return HermNotice(
            kind: kind, source: raw == "activity" ? .activity : .session,
            profileID: profile, sourceID: stable, eventID: identity)
    }

    func publishWorkflowNotice(_ notice: HermNotice, body: String, openURL: URL? = nil) {
        if interruptionCoordinator?.admit(notice, channel: .system) == false { return }
        guard defaults.bool(forKey: completionNotificationsKey), !isPopoverVisible,
            HermesAppRuntime.supportsUserNotifications
        else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.kind.title
        content.body = String(body.prefix(240))
        content.sound = .default
        if let openURL, openURL.scheme == "https", openURL.host == "github.com" {
            content.userInfo["herm.open-pr"] = openURL.absoluteString
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }

    func notify(
        title: String, body: String, identifier: String, approvalRequestID: String? = nil, replyRequestID: String? = nil
    ) {
        let kind: HermNotice.Kind =
            identifier.hasPrefix("completed:")
            ? .completion
            : identifier.hasPrefix("failure:")
                ? .failure : identifier.hasPrefix("approval:") ? .approval : .clarification
        let owner = identifier.split(separator: ":", maxSplits: 1).last.map(String.init)
        if interruptionCoordinator?.admit(interruptionNotice(kind, owner: owner), channel: .system) == false { return }
        guard !isPopoverVisible, HermesAppRuntime.supportsUserNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(240))
        content.sound = .default
        content.userInfo = ["attention_id": identifier]
        if kind == .approval, let approvalRequestID, !approvalRequestID.isEmpty {
            content.categoryIdentifier = HermNotificationAction.approvalCategory
            content.userInfo[HermNotificationAction.requestIDKey] = approvalRequestID
        } else if kind == .clarification, let replyRequestID, !replyRequestID.isEmpty {
            content.categoryIdentifier = HermNotificationAction.clarifyCategory
            content.userInfo[HermNotificationAction.requestIDKey] = replyRequestID
        }
        // A stable ID lets the on-device explanation below replace this banner in place.
        let requestIdentifier = "\(identifier)-\(approvalRequestID ?? UUID().uuidString)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: requestIdentifier, content: content, trigger: nil))
        guard kind == .approval, approvalRequestID != nil, defaults.bool(forKey: OnDeviceAssist.explainApprovalsKey)
        else { return }
        Task {
            guard let explanation = await OnDeviceAssist.explainApproval(title: title, detail: body),
                let updated = content.mutableCopy() as? UNMutableNotificationContent
            else { return }
            updated.subtitle = "\(OnDeviceAssist.attribution) · \(explanation)"
            updated.sound = nil
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: requestIdentifier, content: updated, trigger: nil))
        }
    }
}

/// Banner buttons for approvals. The request ID rides in `userInfo` so a stale banner can only answer the exact request it announced.
enum HermNotificationAction {
    static let approvalCategory = "herm.approval"
    static let approve = "herm.approval.approve"
    static let deny = "herm.approval.deny"
    static let clarifyCategory = "herm.clarify"
    static let reply = "herm.clarify.reply"
    static let requestIDKey = "approval_request_id"

    static var categories: Set<UNNotificationCategory> {
        [
            UNNotificationCategory(
                identifier: approvalCategory,
                actions: [
                    UNNotificationAction(identifier: approve, title: "Approve once", options: []),
                    UNNotificationAction(identifier: deny, title: "Deny", options: [.destructive]),
                ], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: clarifyCategory,
                actions: [
                    UNTextInputNotificationAction(
                        identifier: reply, title: "Reply", options: [],
                        textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
                ], intentIdentifiers: []),
        ]
    }

    static func choice(for actionIdentifier: String) -> String? {
        switch actionIdentifier {
        case approve: ApprovalChoice.once
        case deny: ApprovalChoice.deny
        default: nil
        }
    }
}

extension DockModel {
    /// Answers the approval a banner announced; a no-op once that request is no longer pending.
    func answerApproval(requestID: String, choice: String) {
        guard
            let request = sessionAttention.values.compactMap(\.responseTarget).first(where: {
                $0.requestID == requestID
            })
        else { return }
        answerAttention(request, choice: choice)
    }

    /// Answers a single-question clarification from a banner reply; a no-op once that request is no longer pending.
    func answerClarification(requestID: String, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
            let request = sessionAttention.values.compactMap(\.responseTarget).first(where: {
                $0.requestID == requestID
            })
        else { return }
        answerAttention(request, choice: text, freeText: true)
    }
}
