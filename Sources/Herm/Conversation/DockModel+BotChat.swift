import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    func resumeBotChat(_ bot: BotSummary) {
        // Every Bot has a canonical, persistent Bot Chat. When the roster row
        // has no canonical session pointer yet, Hermes resolves (and lazily
        // creates) the chat by its exact title during profile-scoped resume.
        let chat = bot.chat ?? BotChatReference(sessionID: BotService.canonicalBotChatTitle, profileID: bot.id)
        Task { _ = await resumeSession(HermesSession(id: chat.sessionID, title: bot.name, preview: chat.preview ?? "", startedAt: chat.lastActive, messageCount: 0, source: "hermes-bot"), reportFailure: true, profileID: chat.profileID) }
    }

    /// Routes an explicit, unambiguous Bot mention through Hermes' relay
    /// contract. Relay owns the Bot Chat turn; this model keeps the foreground
    /// session untouched and projects the returned reply into its transcript.
    /// Generic `delegate_task` workers are never relabelled as the Bot.
    func sendDirectBotRequest(profileID: String, displayName: String, text: String, chatSessionID: String? = nil, quote: ReplyQuote? = nil) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // First message of a new chat: create the session, then relay.
        if sessionID == nil, !request.isEmpty, !isSending, !isRestoringSession,
           newSessionCreationAuthorized, !isCreatingSession {
            Task {
                guard (try? await createAuthorizedSession(source: "herm")) != nil else { return }
                sendDirectBotRequest(profileID: profileID, displayName: displayName, text: text, chatSessionID: chatSessionID, quote: quote)
            }
            return
        }
        guard !request.isEmpty,
              !isUpdatingSessionModel,
              !isRestoringSession,
              pendingImages.isEmpty,
              pendingPDFURL == nil,
              let currentSessionID = sessionID,
              !currentSessionID.isEmpty,
              let originSessionID = sessionStorageID ?? sessionID,
              !originSessionID.isEmpty else { return }

        let explicitBotSessionID = chatSessionID
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let activity = BotActivityRecord(originSessionID: originSessionID, botID: profileID, botName: displayName, summary: request, botChatSessionID: explicitBotSessionID)
        inFlightBotActivities[activity.id] = InFlightBotActivity(activityID: activity.id, originSessionID: originSessionID, botID: profileID, botChatSessionID: explicitBotSessionID, clarificationRequestID: nil)
        insertBotActivity(activity)
        if explicitBotSessionID != nil {
            updateBotActivity(id: activity.id, state: .working)
        }
        let sendGeneration = sessionResumeGeneration
        let transcriptText = quote?.composing("@\(displayName) \(request)") ?? "@\(displayName) \(request)"
        let relayMessage = Self.botRelayMessage(request: quote?.composing(request) ?? request, transcript: messages)
        draft = ""
        replyQuote = nil
        messages.append(ChatMessage(role: .user, text: transcriptText, botProfileID: profileID, botDisplayName: displayName))
        // A running foreground turn keeps owning status/isSending; the relay
        // is tracked by its activity and must not mark that turn idle.
        let ownsTurn = !isSending && status != .working
        if ownsTurn {
            status = .working
            isSending = true
        }
        Task {
            do {
                try await sessionRPCClient.connect()
                guard self.sessionResumeGeneration == sendGeneration,
                      self.sessionID == currentSessionID else { return }
                let result = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.botRelayDeliver.rawValue,
                    params: ["profile": profileID, "message": relayMessage]
                )
                guard self.sessionResumeGeneration == sendGeneration,
                      self.sessionID == currentSessionID else { return }
                let reply = (result["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let reportedBotSessionID = (result["session_id"] as? String) ?? (result["bot_session_id"] as? String)
                let botSessionID = reportedBotSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let botSessionID, !botSessionID.isEmpty {
                    self.inFlightBotActivities[activity.id]?.botChatSessionID = botSessionID
                    self.updateBotActivity(id: activity.id, state: .working, botChatSessionID: botSessionID)
                }
                if reply.isEmpty {
                    // Relay already accepted and owns the asynchronous turn.
                    // Without Hermes' explicit session correlation, retain
                    // this activity as unresolved rather than guessing or
                    // resubmitting through a canonical Bot Chat.
                    if ownsTurn {
                        status = .idle
                        isSending = false
                    }
                    return
                }
                messages.append(ChatMessage(role: .hermes, text: reply, botProfileID: profileID, botDisplayName: displayName))
                updateBotActivity(id: activity.id, state: .completed, result: reply)
                inFlightBotActivities.removeValue(forKey: activity.id)
                if ownsTurn {
                    status = .idle
                    isSending = false
                }
            } catch {
                guard self.sessionResumeGeneration == sendGeneration,
                      self.sessionID == currentSessionID else { return }
                let message = "\(displayName) couldn’t process this request: \(Self.safeUserDiagnostic(error.localizedDescription))"
                messages.append(ChatMessage(role: .hermes, text: message, isError: true, botProfileID: profileID, botDisplayName: displayName))
                updateBotActivity(id: activity.id, state: .failed, result: message)
                inFlightBotActivities.removeValue(forKey: activity.id)
                if ownsTurn {
                    status = .idle
                    isSending = false
                }
            }
        }
    }

    func projectBotMessagesIntoActivity() {
        guard let originSessionID = sessionStorageID ?? sessionID, !originSessionID.isEmpty else { return }
        var existing = Set(botActivityBySessionID[originSessionID, default: []].compactMap { $0.result })
        for (index, message) in messages.enumerated() {
            guard message.role == .hermes, let botID = message.botProfileID,
                  !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !existing.contains(message.text) else { continue }
            let request = index > 0 && messages[index - 1].role == .user
                ? messages[index - 1].text
                : "Bot response"
            insertBotActivity(BotActivityRecord(
                originSessionID: originSessionID,
                botID: botID,
                botName: message.botDisplayName ?? botID,
                summary: request,
                state: .completed,
                createdAt: message.timestamp,
                updatedAt: message.timestamp,
                result: message.text
            ))
            existing.insert(message.text)
        }
    }

    static func botRelayMessage(request: String, transcript: [ChatMessage]) -> String {
        let context = transcript.suffix(24).compactMap { message -> String? in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let role = message.role == .user ? "User" : (message.botDisplayName ?? "Assistant")
            return "\(role): \(text.prefix(1000))"
        }.joined(separator: "\n")
        guard !context.isEmpty else { return request }
        return "[CURRENT SESSION CONTEXT — reference only]\n\(context)\n[END CURRENT SESSION CONTEXT]\n\nRespond to this request: \(request)"
    }

    func mergePersistedBotActivities(for sessionIDs: [String?]) {
        var seenActivityIDs = Set<String>()
        for sessionID in sessionIDs.compactMap({ $0 }).filter({ !$0.isEmpty }) {
            guard let records = botActivityBySessionID[sessionID] else { continue }
            for record in records {
                guard seenActivityIDs.insert(record.id).inserted else { continue }
                let result = record.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // The request bubble belongs to this session even while the bot
                // is still working, has no inline reply, or failed.
                if result.isEmpty || record.state != .completed {
                    if record.summary != "Bot response",
                       !messages.contains(where: { $0.role == .user && $0.botProfileID == record.botID && $0.text.hasSuffix(record.summary) }) {
                        messages.append(ChatMessage(role: .user, text: "@\(record.botName) \(record.summary)", timestamp: record.createdAt, botProfileID: record.botID, botDisplayName: record.botName))
                    }
                    continue
                }
                let alreadyPresent = messages.contains { $0.text == result && $0.botProfileID == record.botID }
                guard !alreadyPresent else { continue }
                // Kanban notices replay as notice cards, not as a bot request.
                if let notices = Self.kanbanNotices(from: result) {
                    for notice in notices {
                        messages.append(ChatMessage(role: .hermes, text: notice.body, timestamp: record.updatedAt,
                                                    botProfileID: record.botID, botDisplayName: record.botName,
                                                    kanbanNotice: KanbanNotice(text: notice.body)))
                    }
                    continue
                }
                // "Bot response" marks a bot message nobody asked for (a
                // delivery); show the message without inventing a user bubble.
                if record.summary != "Bot response",
                   !messages.contains(where: { $0.role == .user && $0.botProfileID == record.botID && $0.text.hasSuffix(record.summary) }) {
                    messages.append(ChatMessage(role: .user, text: "@\(record.botName) \(record.summary)", timestamp: record.createdAt, botProfileID: record.botID, botDisplayName: record.botName))
                }
                messages.append(ChatMessage(role: .hermes, text: result, timestamp: record.updatedAt, botProfileID: record.botID, botDisplayName: record.botName))
            }
        }
        messages.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func insertBotActivity(_ record: BotActivityRecord) {
        botActivityBySessionID[record.originSessionID, default: []].append(record)
        botActivityRevision &+= 1
        enqueueBotActivityPersistence()
    }

    func updateBotActivity(id: String, state: BotActivityState, result: String? = nil, botChatSessionID: String? = nil) {
        for originSessionID in botActivityBySessionID.keys {
            guard let index = botActivityBySessionID[originSessionID]?.firstIndex(where: { $0.id == id }) else { continue }
            var record = botActivityBySessionID[originSessionID]![index]
            guard record.state != .completed, record.state != .failed, record.state != .canceled else { return }
            record.state = state
            record.updatedAt = Date()
            if result != nil { record.result = result }
            if botChatSessionID != nil { record.botChatSessionID = botChatSessionID }
            botActivityBySessionID[originSessionID]![index] = record
            botActivityRevision &+= 1
            enqueueBotActivityPersistence()
            return
        }
    }

    func enqueueBotActivityPersistence() {
        let snapshot = botActivityBySessionID
        Task { await botActivityWriter.enqueue(snapshot) }
    }

    func markBotActivityFailed(originSessionID: String?, result: String) {
        let activities = Array(inFlightBotActivities.values)
        for activity in activities where activity.originSessionID == originSessionID {
            updateBotActivity(id: activity.activityID, state: .failed, result: result)
            inFlightBotActivities.removeValue(forKey: activity.activityID)
        }
    }

    func markBotActivityFailed(id: String, result: String) {
        guard inFlightBotActivities[id] != nil else { return }
        updateBotActivity(id: id, state: .failed, result: result)
        inFlightBotActivities.removeValue(forKey: id)
    }

    func updateInFlightBotActivity(for eventSessionID: String?, state: BotActivityState, result: String? = nil) {
        guard let eventSessionID else { return }
        let activities = Array(inFlightBotActivities.values)
        for activity in activities {
            guard activity.botChatSessionID == eventSessionID else { continue }
            updateBotActivity(id: activity.activityID, state: state, result: result)
            if state == .completed || state == .failed || state == .canceled {
                inFlightBotActivities.removeValue(forKey: activity.activityID)
            }
        }
    }

    func setInFlightBotActivityWorking(for eventSessionID: String?) {
        guard let eventSessionID else { return }
        for activity in inFlightBotActivities.values where activity.botChatSessionID == eventSessionID {
            updateBotActivity(id: activity.activityID, state: .working)
        }
    }

    func setInFlightBotActivityWaiting(for eventSessionID: String?, requestID: String? = nil) {
        guard let eventSessionID else { return }
        for activity in inFlightBotActivities.values where activity.botChatSessionID == eventSessionID {
            inFlightBotActivities[activity.activityID]?.clarificationRequestID = requestID
            updateBotActivity(id: activity.activityID, state: .waiting)
        }
    }

    func updateInFlightBotActivity(for requestID: String, state: BotActivityState, result: String?) {
        let activities = Array(inFlightBotActivities.values)
        for activity in activities where activity.clarificationRequestID == requestID {
            updateBotActivity(id: activity.activityID, state: state, result: result)
            if state == .completed || state == .failed || state == .canceled {
                inFlightBotActivities.removeValue(forKey: activity.activityID)
            }
        }
    }

    func detachInFlightBotActivities(as state: BotActivityState) {
        let activities = Array(inFlightBotActivities.values)
        for activity in activities {
            updateBotActivity(id: activity.activityID, state: state)
        }
        inFlightBotActivities.removeAll()
    }
}
