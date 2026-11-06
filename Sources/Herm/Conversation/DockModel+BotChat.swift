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
        resumeSession(
            HermesSession(
                id: chat.sessionID, title: bot.name, preview: chat.preview ?? "", startedAt: chat.lastActive,
                messageCount: 0, source: "hermes-bot"), profileID: chat.profileID)
    }

    /// Routes an explicit, unambiguous Bot mention to its profile-scoped Bot Chat.
    /// The recipient owns the turn; this model keeps the foreground
    /// session untouched and projects the streamed reply into its transcript.
    /// Generic `delegate_task` workers are never relabelled as the Bot.
    func sendDirectBotRequest(
        profileID: String, displayName: String, text: String, chatSessionID: String? = nil, quote: ReplyQuote? = nil,
        originalText: String? = nil, botMentions: [ComposerBotMention] = [], clearsComposer: Bool = true
    ) {
        guard sessionActionsReady else { return }
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // First message of a new chat: create the origin, then contact the Bot.
        if sessionID == nil, !request.isEmpty, !isSending, !isRestoringSession,
            newSessionCreationAuthorized, !isCreatingSession
        {
            Task {
                guard (try? await createAuthorizedSession(source: HermesFeatureIDs.sessionSource)) != nil else {
                    return
                }
                sendDirectBotRequest(
                    profileID: profileID, displayName: displayName, text: text, chatSessionID: chatSessionID,
                    quote: quote, originalText: originalText, botMentions: botMentions, clearsComposer: clearsComposer
                )
            }
            return
        }
        guard !request.isEmpty,
            !isUpdatingSessionModel,
            !isRestoringSession,
            !clearsComposer || (pendingImages.isEmpty && pendingPDFURL == nil),
            let currentSessionID = sessionID,
            !currentSessionID.isEmpty,
            let originSessionID = sessionStorageID ?? sessionID,
            !originSessionID.isEmpty
        else { return }

        let explicitBotSessionID =
            chatSessionID
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let activity = BotActivityRecord(
            originSessionID: originSessionID, botID: profileID, botName: displayName, summary: request,
            botChatSessionID: explicitBotSessionID)
        inFlightBotActivities[activity.id] = InFlightBotActivity(
            activityID: activity.id, originSessionID: originSessionID, botID: profileID,
            botChatSessionID: explicitBotSessionID, clarificationRequestID: nil)
        insertBotActivity(activity)
        if explicitBotSessionID != nil {
            updateBotActivity(id: activity.id, state: .working)
        }
        let sendGeneration = sessionResumeGeneration
        let visibleText = originalText ?? "@\(displayName) \(request)"
        let transcriptText = quote?.composing(visibleText) ?? visibleText
        let relayMessage = GenerativeUIIntegration.preparePrompt(
            Self.botRelayMessage(request: quote?.composing(request) ?? request, transcript: messages),
            context: generationContext(
                for: QuickDestination(
                    profileID: profileID, sessionID: explicitBotSessionID, title: displayName)))
        if clearsComposer {
            draft = ""
            replyQuote = nil
            clearAttachmentErrors()
        }
        messages.append(
            ChatMessage(
                role: .user, text: transcriptText, botProfileID: profileID, botDisplayName: displayName,
                botMentions: ComposerBotMention.rebasing(botMentions, from: visibleText, to: transcriptText)))
        // A running foreground turn keeps owning status/isSending; the request
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
                    self.sessionID == currentSessionID
                else { return }
                let botSessionID = try await HermesControlRPC(client: sessionRPCClient).submitBotMessage(
                    profileID: profileID, message: relayMessage, chatSessionID: explicitBotSessionID
                ) { botSessionID in
                    guard self.sessionResumeGeneration == sendGeneration, self.sessionID == currentSessionID else {
                        throw CancellationError()
                    }
                    guard
                        !self.inFlightBotActivities.values.contains(where: {
                            $0.activityID != activity.id && $0.botChatSessionID == botSessionID
                        })
                    else {
                        throw QuickDraftError.message(
                            "This Bot is already answering an earlier mention. Wait for its reply before sending again."
                        )
                    }
                    self.inFlightBotActivities[activity.id]?.botChatSessionID = botSessionID
                    self.inFlightBotActivities[activity.id]?.submissionStarted = true
                    self.updateBotActivity(id: activity.id, state: .working, botChatSessionID: botSessionID)
                }
                guard self.sessionResumeGeneration == sendGeneration,
                    self.sessionID == currentSessionID
                else { return }
                if ownsTurn, !currentSessionIDs.contains(botSessionID) {
                    status = .idle
                    isSending = false
                }
            } catch {
                guard self.inFlightBotActivities[activity.id] != nil else { return }
                let message =
                    "\(displayName) couldn’t process this request: \(Self.safeUserDiagnostic(error.localizedDescription))"
                updateBotActivity(id: activity.id, state: .failed, result: message)
                inFlightBotActivities.removeValue(forKey: activity.id)
                guard self.sessionResumeGeneration == sendGeneration,
                    self.sessionID == currentSessionID
                else { return }
                messages.append(
                    ChatMessage(
                        role: .hermes, text: message, isError: true, botProfileID: profileID,
                        botDisplayName: displayName))
                if ownsTurn {
                    status = .idle
                    isSending = false
                }
                drainQueuedPromptIfIdle()
            }
        }
    }

    func submitComposerInput(bots: [BotSummary]) {
        let selected = composer.selectedBots
        let roster = selected + bots.filter { bot in !selected.contains(where: { $0.id == bot.id }) }
        let recipients = selected.isEmpty ? roster : selected
        composerMentionBots = recipients
        composerMentionProfiles = roster.map(\.id)
        if !selected.isEmpty {
            guard attachedContexts.isEmpty, pendingImages.isEmpty, pendingPDFURL == nil else {
                reportAttachmentError(
                    "Bot messages support text only. Remove attachments and context. Your draft is kept.")
                return
            }
            guard selected.count == 1,
                ComposerMentionPresentation.botRelayRequest(in: draft, profileIDs: recipients.map(\.id)) != nil
            else {
                reportAttachmentError("Select one Bot per message and include a request. Your draft is kept.")
                return
            }
        }
        if attachedContexts.isEmpty,
            ComposerMentionPresentation.canDirectRouteBot(
                hasImages: !pendingImages.isEmpty, hasPDF: pendingPDFURL != nil),
            let request = ComposerMentionPresentation.botRelayRequest(in: draft, profileIDs: recipients.map(\.id)),
            let bot = recipients.first(where: { $0.id == request.profileID })
        {
            if hasQueuedOrRedirectingPrompt {
                queueDraft()
                return
            }
            sendDirectBotRequest(
                profileID: bot.id, displayName: bot.name, text: request.text,
                chatSessionID: bot.chat?.sessionID, quote: replyQuote, originalText: draft,
                botMentions: composer.botMentions)
            return
        }
        submitComposerInput(mentionProfiles: roster.map(\.id))
    }

    func projectBotMessagesIntoActivity() {
        guard let originSessionID = sessionStorageID ?? sessionID, !originSessionID.isEmpty else { return }
        var existing = Set(botActivityBySessionID[originSessionID, default: []].compactMap { $0.result })
        for (index, message) in messages.enumerated() {
            guard message.role == .hermes, let botID = message.botProfileID,
                !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !existing.contains(message.text)
            else { continue }
            let request =
                index > 0 && messages[index - 1].role == .user
                ? messages[index - 1].text
                : "Bot response"
            insertBotActivity(
                BotActivityRecord(
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
        return
            "[CURRENT SESSION CONTEXT — reference only]\n\(context)\n[END CURRENT SESSION CONTEXT]\n\nRespond to this request: \(request)"
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
                if result.isEmpty || record.isLive {
                    if record.summary != "Bot response", !record.id.hasPrefix("bot-dispatch:"),
                        !messages.contains(where: {
                            $0.role == .user && $0.botProfileID == record.botID && $0.text.hasSuffix(record.summary)
                        })
                    {
                        messages.append(
                            ChatMessage(
                                role: .user, text: "@\(record.botName) \(record.summary)", timestamp: record.createdAt,
                                botProfileID: record.botID, botDisplayName: record.botName))
                    }
                    continue
                }
                let alreadyPresent = messages.contains { $0.text == result && $0.botProfileID == record.botID }
                guard !alreadyPresent else { continue }
                // Kanban notices replay as notice cards, not as a bot request.
                if let notices = Self.kanbanNotices(from: result) {
                    for notice in notices {
                        messages.append(
                            ChatMessage(
                                role: .hermes, text: notice.body, timestamp: record.updatedAt,
                                botProfileID: record.botID, botDisplayName: record.botName,
                                kanbanNotice: KanbanNotice(text: notice.body)))
                    }
                    continue
                }
                // A card's outcome already arrives as a Kanban notice.
                if record.linkedCardID != nil { continue }
                // Another Bot asked, not the user: no request bubble.
                if record.id.hasPrefix("bot-dispatch:") {
                    let reply = Self.botReply(from: result).reply
                    guard !reply.isEmpty,
                        !messages.contains(where: { $0.text == reply && $0.botProfileID == record.botID })
                    else { continue }
                    messages.append(
                        ChatMessage(
                            role: .hermes, text: reply, timestamp: record.updatedAt, botProfileID: record.botID,
                            botDisplayName: record.botName, isBotHandoffReply: true))
                    continue
                }
                // "Bot response" marks a bot message nobody asked for (a
                // delivery); show the message without inventing a user bubble.
                if record.summary != "Bot response",
                    !messages.contains(where: {
                        $0.role == .user && $0.botProfileID == record.botID && $0.text.hasSuffix(record.summary)
                    })
                {
                    messages.append(
                        ChatMessage(
                            role: .user, text: "@\(record.botName) \(record.summary)", timestamp: record.createdAt,
                            botProfileID: record.botID, botDisplayName: record.botName))
                }
                messages.append(
                    ChatMessage(
                        role: .hermes, text: result, timestamp: record.updatedAt,
                        isError: record.state == .failed || record.state == .canceled,
                        botProfileID: record.botID, botDisplayName: record.botName))
            }
        }
        // Saved timestamps can tie; stable sorting keeps requests before their replies.
        messages.sort { $0.timestamp < $1.timestamp }
    }

    /// A Bot this turn hands work to: Hermes' `message_agent` tool, a
    /// `hermes chat` command run as another profile (`chatProfile`), or a
    /// Kanban card created for a Bot.
    static func botDispatch(
        toolName: String, args: [String: Any], alias: (String) -> String? = hermesProfileAlias
    ) -> (profileID: String, summary: String)? {
        if toolName == "kanban_create" {
            let assignee = ((args["assignee"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingPrefix("@").lowercased()
            guard !assignee.isEmpty else { return nil }
            return (assignee, String(((args["title"] as? String) ?? "Kanban card").prefix(400)))
        }
        if toolName == "message_agent" {
            let target = ((args["target"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingPrefix("@").lowercased()
            guard !target.isEmpty else { return nil }
            return (target, String(((args["message"] as? String) ?? "").prefix(400)))
        }
        guard let command = args["command"] as? String, let profile = chatProfile(command, alias: alias) else {
            return nil
        }
        let query =
            command.firstMatch(of: /\s-q\s+'([^']*)'/).map { String($0.1) }
            ?? command.firstMatch(of: /\s-q\s+"([^"]*)"/).map { String($0.1) }
        let brief = command.firstMatch(of: /--query-file\s+(\S+)/).map {
            "Brief: " + URL(fileURLWithPath: String($0.1)).lastPathComponent
        }
        return (profile, String((query ?? brief ?? command).prefix(400)))
    }

    /// The profile a shell command starts `hermes chat` as, in every form
    /// Hermes accepts (`main._apply_profile_override`): `-p`/`--profile`
    /// anywhere in its arguments, `--profile=<p>`, `HERMES_HOME=…/profiles/<p>`,
    /// or a profile alias wrapper (`<p> chat`). Nil for the default profile.
    nonisolated static func chatProfile(_ command: String, alias: (String) -> String? = hermesProfileAlias)
        -> String?
    {
        // Quoted text is a prompt or a path, never a flag.
        let bare = command.replacing(/'[^']*'|"[^"]*"/, with: "''")
        for segment in bare.split(whereSeparator: { ";|&\n".contains($0) }) {
            let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let chat = words.firstIndex(of: "chat") else { continue }
            if let start = words[..<chat].lastIndex(where: { ($0 as NSString).lastPathComponent == "hermes" }) {
                let flags = words[(start + 1)...]
                if let index = flags.firstIndex(where: { $0 == "-p" || $0 == "--profile" }), index + 1 < words.count {
                    return words[index + 1].lowercased()
                }
                if let flag = flags.first(where: { $0.hasPrefix("--profile=") }) {
                    return String(flag.dropFirst("--profile=".count)).lowercased()
                }
                if let home = words[..<start].last(where: { $0.hasPrefix("HERMES_HOME=") }),
                    let match = home.firstMatch(of: /\/profiles\/([\w-]+)\/?$/)
                {
                    return String(match.1).lowercased()
                }
            } else if chat > 0, let profile = alias((words[chat - 1] as NSString).lastPathComponent) {
                return profile
            }
        }
        return nil
    }

    /// Hermes' alias wrapper `~/.local/bin/<name>` is `exec hermes -p <profile> "$@"`
    /// (`hermes_cli/profiles.py`, `_is_our_wrapper`).
    nonisolated static func hermesProfileAlias(_ name: String) -> String? {
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }), !name.isEmpty,
            let handle = FileHandle(
                forReadingAtPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                    ".local/bin/\(name)"
                ).path),
            let head = try? handle.read(upToCount: 512), let text = String(data: head, encoding: .utf8)
        else { return nil }
        try? handle.close()
        return text.firstMatch(of: /hermes -p ([\w-]+)/).map { String($0.1).lowercased() }
    }

    func recordBotDispatch(toolCallID: String, toolName: String, args: [String: Any], at date: Date = Date()) {
        guard let dispatch = Self.botDispatch(toolName: toolName, args: args),
            let originSessionID = sessionStorageID ?? sessionID
        else { return }
        let id = "bot-dispatch:\(toolCallID)"
        guard !botActivityBySessionID[originSessionID, default: []].contains(where: { $0.id == id }) else { return }
        insertBotActivity(
            BotActivityRecord(
                id: id, originSessionID: originSessionID, botID: dispatch.profileID,
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
            // A card's status stays on the board, so any age can be resolved.
            guard finished || call.name == "kanban_create" || Date().timeIntervalSince(call.startedAt) < 3 * 3600 else {
                continue
            }
            recordBotDispatch(toolCallID: call.id, toolName: call.name, args: call.args ?? [:], at: call.startedAt)
            if let result = call.result { bindBotDispatch(toolCallID: call.id, result: result) }
        }
        notices.forEach(completeBotDispatch(from:))
    }

    static func dispatchProcessID(_ result: String) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] else {
            return nil
        }
        return [json["process_id"], json["session_id"]].compactMap { $0 as? String }.first { $0.hasPrefix("proc_") }
    }

    /// The dispatch tool returns at once with the background process id
    /// (`process_id` from message_agent, `session_id` from terminal).
    func bindBotDispatch(toolCallID: String, result: String) {
        let id = "bot-dispatch:\(toolCallID)"
        guard let json = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] else {
            // Compacted history keeps only `[terminal] ran `…` -> exit N`, and
            // a long result arrives truncated: either way the call returned,
            // and a background start always parses, so the Bot is done.
            let exit = result.firstMatch(of: /-> exit (-?\d+)/).flatMap { Int($0.1) } ?? 0
            updateBotActivity(id: id, state: exit == 0 ? .completed : .failed)
            return
        }
        let processID = Self.dispatchProcessID(result)
        let cardID = (json["task_id"] as? String).flatMap { $0.hasPrefix("t_") ? $0 : nil }
        let error = (json["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        for originSessionID in botActivityBySessionID.keys {
            guard let index = botActivityBySessionID[originSessionID]?.firstIndex(where: { $0.id == id }) else {
                continue
            }
            if let error {
                updateBotActivity(id: id, state: .failed, result: error)
            } else if let cardID {
                // The card runs on the board; `reconcileKanbanAssignments` follows it.
                botActivityBySessionID[originSessionID]![index].linkedCardID = cardID
                botActivityRevision &+= 1
                enqueueBotActivityPersistence()
            } else if let processID {
                botActivityBySessionID[originSessionID]![index].processID = processID
                botActivityRevision &+= 1
                enqueueBotActivityPersistence()
            } else {
                // A foreground `hermes -p <bot> chat` returns the reply itself:
                // no process, so no completion notice will ever arrive.
                let output = Self.botReply(from: (json["output"] as? String) ?? "")
                let ok = ((json["exit_code"] as? Int) ?? 0) == 0
                updateBotActivity(
                    id: id, state: ok ? .completed : .failed,
                    result: output.reply.isEmpty ? nil : String(output.reply.prefix(600)),
                    botChatSessionID: output.sessionID)
            }
            return
        }
    }

    /// Hermes' notice when a Bot DM's process exits:
    /// `Background process proc_… completed normally (exit code 0). … Output: … session_id: <id>`.
    func completeBotDispatch(from text: String) {
        // Several Bots finishing together arrive as one batched notice.
        let heads = text.matches(of: /Background process (proc_\w+) (\w+)/)
        guard heads.count <= 1 else {
            for (index, head) in heads.enumerated() {
                let end = index + 1 < heads.count ? heads[index + 1].range.lowerBound : text.endIndex
                completeBotDispatch(
                    from: String(text[head.range.lowerBound..<end]).replacing(/\s*\[IMPORTANT:\s*$/, with: ""))
            }
            return
        }
        guard let head = heads.first else { return }
        let processID = String(head.1)
        guard
            let record = botActivityBySessionID.values.lazy.flatMap({ $0 }).first(where: { $0.processID == processID })
        else { return }
        let output = text.range(of: "Output:\n").map { String(text[$0.upperBound...]) } ?? ""
        let (reply, botSessionID) = Self.botReply(from: output)
        let ok = head.2 == "completed" && text.contains("exit code 0")
        updateBotActivity(
            id: record.id, state: ok ? .completed : .failed, result: reply.isEmpty ? nil : String(reply.prefix(600)),
            botChatSessionID: botSessionID)
    }

    /// `hermes chat -Q` ends its answer with `session_id: <id>`; that line is
    /// plumbing, not part of the reply.
    static func botReply(from output: String) -> (reply: String, sessionID: String?) {
        let sessionID = output.matches(of: /session_id: (\S+)/).last.map { String($0.1) }
        let reply = output.replacing(/(\n*session_id: \S+)?\s*\]?\s*$/, with: "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        return (reply, sessionID)
    }

    /// Hermes' completion notice is not reliable: it can be compacted away,
    /// land while Herm is offline, or never be stored. Hermes' process
    /// registry is the truth: a DM whose process is no longer running is done.
    func reconcileBotDispatches() async {
        let pending = botActivityBySessionID.values.joined().filter {
            $0.id.hasPrefix("bot-dispatch:") && $0.processID != nil && ($0.state == .working || $0.state == .queued)
        }
        // `agents.list` lists every running and recently finished background
        // process without needing a live session. A transport ID, not a
        // capability: a failed call just leaves the records as they were.
        guard !pending.isEmpty,
            let result = try? await sessionRPCClient.request(HermesFeatureIDs.ID.agentsList.rawValue, params: [:]),
            let rows = result["processes"] as? [[String: Any]]
        else { return }
        let status = Dictionary(
            rows.compactMap { row in (row["session_id"] as? String).map { ($0, row["status"] as? String ?? "") } },
            uniquingKeysWith: { first, _ in first })
        for record in pending {
            switch status[record.processID!] {
            case "running": continue
            case "killed": updateBotActivity(id: record.id, state: .canceled)
            default: updateBotActivity(id: record.id, state: .completed)
            }
        }
    }

    /// Kanban cards this session assigned to a Bot, followed on the board
    /// until the Bot finishes, hands it back for review, or gets blocked.
    func reconcileKanbanAssignments(status: (String) async -> (status: String, summary: String?)?) async {
        // Hidden card references stay `.queued` forever and are not Bot work;
        // polling them spawned a `kanban show` per reference every pass.
        let pending = botActivityBySessionID.values.joined().filter {
            $0.linkedCardID != nil && $0.isLive && !$0.isKanbanReference
        }
        for record in pending {
            guard let card = await status(record.linkedCardID!) else { continue }
            let state: BotActivityState =
                switch card.status.lowercased() {
                case "done", "archived", "completed", "review": .completed
                case "blocked", "triage": .waiting
                case "running": .working
                default: .queued
                }
            if state != record.state {
                updateBotActivity(id: record.id, state: state, result: card.summary)
            }
        }
    }

    /// Reads what each working Bot DM is doing from the Bot's own session.
    /// Hermes does not link a DM to that session until it finishes, so the
    /// session is matched by profile and start time; an ambiguous match
    /// shows nothing rather than another conversation's step.
    func refreshBotLiveSteps() async {
        let generation = sessionResumeGeneration
        var steps: [String: String] = [:]
        for records in Dictionary(grouping: workingBotDispatches, by: \.botID).values {
            // Two DMs to one Bot at once cannot be told apart.
            guard records.count == 1, let record = records.first,
                let profile = record.botID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            else { continue }
            var sessionID = record.botChatSessionID
            if sessionID == nil,
                let rows = try? await sessionRPCClient.fetchHTTP(
                    "/api/sessions?limit=20&order=recent&profile=\(profile)")["sessions"] as? [[String: Any]]
            {
                sessionID = Self.liveBotSessionID(in: rows, dispatchedAt: record.createdAt)
            }
            guard let sessionID,
                let path = TranscriptHistoryPaging.pagePath(
                    sessionID: sessionID, profileID: record.botID, limit: 6, offset: 0),
                let rows = try? await sessionRPCClient.fetchHTTP(path)["messages"] as? [[String: Any]],
                let step = Self.latestBotStep(in: rows)
            else { continue }
            steps[record.id] = step
        }
        guard generation == sessionResumeGeneration, !Task.isCancelled else { return }
        // A mention may advance or finish while a DM's history read is awaiting Hermes.
        steps.merge(botLiveSteps.filter { inFlightBotActivities[$0.key] != nil }) { _, live in live }
        if steps != botLiveSteps { botLiveSteps = steps }
    }

    /// The one open session a Bot started after the DM was sent, if exactly one.
    static func liveBotSessionID(in rows: [[String: Any]], dispatchedAt: Date) -> String? {
        let open = rows.filter { row in
            guard row["ended_at"] == nil || row["ended_at"] is NSNull,
                let started = (row["started_at"] as? NSNumber)?.doubleValue
            else { return false }
            // A few seconds of slack for the Bot process starting before Herm records the DM.
            return started >= dispatchedAt.timeIntervalSince1970 - 5
        }
        return open.count == 1 ? open[0]["id"] as? String : nil
    }

    /// Title of the newest tool call in a page of stored session rows.
    static func latestBotStep(in rows: [[String: Any]]) -> String? {
        for row in TranscriptHistoryPaging.displayRows(fromStoredRows: rows).reversed()
        where row["role"] as? String == "assistant" {
            if let call = historyToolCalls(in: row, timestamp: Date()).last {
                return AgentActivityPresentation.toolActivityTitle(name: call.name, context: call.context)
            }
        }
        return nil
    }

    /// Bot DMs this session sent that have not finished.
    var workingBotDispatches: [BotActivityRecord] {
        guard let id = sessionStorageID ?? sessionID else { return [] }
        // ponytail: a completion notice Herm missed (offline, other client)
        // would leave a DM working forever; past 3h it is treated as stale,
        // matching `restoreBotDispatches`.
        let cutoff = Date().addingTimeInterval(-3 * 3600)
        return botActivityBySessionID[id, default: []].filter {
            $0.id.hasPrefix("bot-dispatch:") && ($0.state == .working || $0.state == .queued) && $0.createdAt > cutoff
        }
    }

    /// @mentions in this session that the Bot is still answering.
    var pendingBotMentions: [BotActivityRecord] {
        guard let id = sessionStorageID ?? sessionID else { return [] }
        // ponytail: a relay Hermes accepted without naming the Bot's session
        // can never be followed, so it stops reading as working after 10 min.
        let cutoff = Date().addingTimeInterval(-600)
        return botActivityBySessionID[id, default: []].filter {
            inFlightBotActivities[$0.id] != nil && $0.isLive && ($0.state != .queued || $0.createdAt > cutoff)
        }
    }

    /// This session's Bot DMs, keyed by the tool call that sent each one.
    var botDispatchesByToolCallID: [String: BotActivityRecord] {
        guard let id = sessionStorageID ?? sessionID else { return [:] }
        let prefix = "bot-dispatch:"
        return Dictionary(
            botActivityBySessionID[id, default: []].compactMap {
                $0.id.hasPrefix(prefix) ? (String($0.id.dropFirst(prefix.count)), $0) : nil
            }, uniquingKeysWith: { first, _ in first })
    }

    func insertBotActivity(_ record: BotActivityRecord) {
        botActivityBySessionID[record.originSessionID, default: []].append(record)
        botActivityRevision &+= 1
        enqueueBotActivityPersistence()
    }

    func updateBotActivity(id: String, state: BotActivityState, result: String? = nil, botChatSessionID: String? = nil)
    {
        for originSessionID in botActivityBySessionID.keys {
            guard let index = botActivityBySessionID[originSessionID]?.firstIndex(where: { $0.id == id }) else {
                continue
            }
            var record = botActivityBySessionID[originSessionID]![index]
            if record.state == .completed || record.state == .failed || record.state == .canceled {
                // The registry check can finish a DM before its notice lands;
                // the late notice still brings the reply and Bot session.
                guard record.result == nil || record.botChatSessionID == nil, result != nil || botChatSessionID != nil
                else { return }
                record.result = record.result ?? result
                record.botChatSessionID = record.botChatSessionID ?? botChatSessionID
                botActivityBySessionID[originSessionID]![index] = record
                botActivityRevision &+= 1
                enqueueBotActivityPersistence()
                return
            }
            record.state = state
            record.updatedAt = Date()
            if result != nil { record.result = result }
            if botChatSessionID != nil { record.botChatSessionID = botChatSessionID }
            botActivityBySessionID[originSessionID]![index] = record
            if !record.isLive { botLiveSteps.removeValue(forKey: id) }
            botActivityRevision &+= 1
            enqueueBotActivityPersistence()
            return
        }
    }

    static func botMentionActivityTitle(type: String, payload: [String: Any]) -> String? {
        switch type {
        case "tool.call", "tool.start", "tool.use", "tool_use":
            guard
                let name = (payload["name"] as? String) ?? (payload["tool"] as? String)
                    ?? (payload["tool_name"] as? String),
                !name.isEmpty
            else { return nil }
            let args =
                parseArgsDict(payload["arguments"]) ?? parseArgsDict(payload["input"])
                ?? parseArgsDict(payload["args"]) ?? parseArgsDict(payload["args_text"]) ?? [:]
            let context =
                payload["context"] as? String
                ?? ["command", "path", "file_path", "pattern", "query", "url", "goal"]
                .lazy.compactMap { args[$0] as? String }.first ?? ""
            return safeUserDiagnostic(AgentActivityPresentation.toolActivityTitle(name: name, context: context))
        case "reasoning.start", "reasoning.delta", "reasoning.available", "thinking", "thinking.delta":
            return "Thinking"
        case "message.start": return "Starting response"
        case "message.delta", "message.interim": return "Responding"
        case "approval.request": return "Waiting for approval"
        case "clarification.request", "clarify.request": return "Waiting for your answer"
        default: return nil
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

    func detachInFlightBotActivities(as state: BotActivityState, keepingSubmitted: Bool = false) {
        let activities = Array(inFlightBotActivities.values)
        // Navigation cannot cancel a turn already submitted to another Bot.
        for activity in activities where !keepingSubmitted || !activity.submissionStarted {
            updateBotActivity(id: activity.activityID, state: state)
            inFlightBotActivities.removeValue(forKey: activity.activityID)
        }
    }
}
