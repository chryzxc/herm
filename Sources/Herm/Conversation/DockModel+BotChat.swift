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

    /// A Bot this turn hands work to: Hermes' `message_agent` tool, or the
    /// `hermes -p <bot> chat` command Bots use to DM each other.
    static func botDispatch(toolName: String, args: [String: Any]) -> (profileID: String, summary: String)? {
        if toolName == "message_agent" {
            let target = ((args["target"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingPrefix("@").lowercased()
            guard !target.isEmpty else { return nil }
            return (target, String(((args["message"] as? String) ?? "").prefix(400)))
        }
        guard let command = args["command"] as? String,
              let match = command.firstMatch(of: /\bhermes\s+(?:-p|--profile)\s+([\w-]+)\s+chat\b/) else { return nil }
        let query = command.firstMatch(of: /\s-q\s+'([^']*)'/).map { String($0.1) }
            ?? command.firstMatch(of: /\s-q\s+"([^"]*)"/).map { String($0.1) }
        let brief = command.firstMatch(of: /--query-file\s+(\S+)/).map { "Brief: " + URL(fileURLWithPath: String($0.1)).lastPathComponent }
        return (String(match.1), String((query ?? brief ?? command).prefix(400)))
    }

    func recordBotDispatch(toolCallID: String, toolName: String, args: [String: Any], at date: Date = Date()) {
        guard let dispatch = Self.botDispatch(toolName: toolName, args: args),
              let originSessionID = sessionStorageID ?? sessionID else { return }
        let id = "bot-dispatch:\(toolCallID)"
        guard !botActivityBySessionID[originSessionID, default: []].contains(where: { $0.id == id }) else { return }
        insertBotActivity(BotActivityRecord(id: id, originSessionID: originSessionID, botID: dispatch.profileID,
                                            botName: dispatch.profileID, summary: dispatch.summary, state: .working,
                                            createdAt: date, updatedAt: date))
    }

    /// Bot DMs in stored history, including ones Herm never saw live. A DM
    /// whose completion notice is not in the loaded rows only shows while
    /// recent, so old ones never read as still working.
    func restoreBotDispatches(calls: [ActiveToolCall], rows: [[String: Any]]) {
        let notices = rows.compactMap { $0["text"] as? String }.filter { $0.contains("Background process proc_") }
        for call in calls {
            guard Self.botDispatch(toolName: call.name, args: call.args ?? [:]) != nil else { continue }
            let processID = call.result.flatMap(Self.dispatchProcessID)
            let finished = processID.map { id in notices.contains { $0.contains(id) } } ?? false
            guard finished || Date().timeIntervalSince(call.startedAt) < 3 * 3600 else { continue }
            recordBotDispatch(toolCallID: call.id, toolName: call.name, args: call.args ?? [:], at: call.startedAt)
            if let result = call.result { bindBotDispatch(toolCallID: call.id, result: result) }
        }
        notices.forEach(completeBotDispatch(from:))
    }

    static func dispatchProcessID(_ result: String) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] else { return nil }
        return [json["process_id"], json["session_id"]].compactMap { $0 as? String }.first { $0.hasPrefix("proc_") }
    }

    /// The dispatch tool returns at once with the background process id
    /// (`process_id` from message_agent, `session_id` from terminal).
    func bindBotDispatch(toolCallID: String, result: String) {
        let id = "bot-dispatch:\(toolCallID)"
        guard let json = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] else { return }
        let processID = Self.dispatchProcessID(result)
        let error = (json["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        for originSessionID in botActivityBySessionID.keys {
            guard let index = botActivityBySessionID[originSessionID]?.firstIndex(where: { $0.id == id }) else { continue }
            if let error {
                updateBotActivity(id: id, state: .failed, result: error)
            } else if let processID {
                botActivityBySessionID[originSessionID]![index].processID = processID
                botActivityRevision &+= 1
                enqueueBotActivityPersistence()
            }
            return
        }
    }

    /// Hermes' notice when a Bot DM's process exits:
    /// `Background process proc_… completed normally (exit code 0). … Output: … session_id: <id>`.
    func completeBotDispatch(from text: String) {
        guard let head = text.firstMatch(of: /Background process (proc_\w+) (\w+)/) else { return }
        let processID = String(head.1)
        guard let record = botActivityBySessionID.values.lazy.flatMap({ $0 }).first(where: { $0.processID == processID }) else { return }
        let output = text.range(of: "Output:\n").map { String(text[$0.upperBound...]) } ?? ""
        let botSessionID = output.matches(of: /session_id: (\S+)/).last.map { String($0.1) }
        let reply = output.replacing(/\n*session_id: \S+\s*\]?\s*$/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = head.2 == "completed" && text.contains("exit code 0")
        updateBotActivity(id: record.id, state: ok ? .completed : .failed, result: reply.isEmpty ? nil : String(reply.prefix(600)), botChatSessionID: botSessionID)
    }

    /// Bot DMs this session sent that have not finished.
    var workingBotDispatches: [BotActivityRecord] {
        guard let id = sessionStorageID ?? sessionID else { return [] }
        return botActivityBySessionID[id, default: []].filter {
            $0.id.hasPrefix("bot-dispatch:") && ($0.state == .working || $0.state == .queued)
        }
    }

    /// This session's Bot DMs, keyed by the tool call that sent each one.
    var botDispatchesByToolCallID: [String: BotActivityRecord] {
        guard let id = sessionStorageID ?? sessionID else { return [:] }
        let prefix = "bot-dispatch:"
        return Dictionary(botActivityBySessionID[id, default: []].compactMap {
            $0.id.hasPrefix(prefix) ? (String($0.id.dropFirst(prefix.count)), $0) : nil
        }, uniquingKeysWith: { first, _ in first })
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
