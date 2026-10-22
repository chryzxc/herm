import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    /// Reconcile delayed index snapshots with newer activity observed directly
    /// from the gateway. The index remains authoritative for session metadata,
    /// while a live event remains authoritative for recency until the index
    /// catches up.
    static func mergingSessionIndex(_ loaded: [HermesSession], with existing: [HermesSession], keeping openSessionID: String? = nil, working: Set<String>? = nil) -> [HermesSession] {
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A just-created chat can be missing from an index read that raced
        // its creation; keep the open row until Hermes lists it.
        let pending = openSessionID.flatMap { id in
            loaded.contains { $0.id == id } ? nil : existingByID[id]
        }
        return (pending.map { [$0] } ?? []) + loaded.map { session in
            guard let observed = existingByID[session.id] else {
                guard working?.contains(session.id) == true else { return session }
                return HermesSession(id: session.id, profileID: session.profileID, title: session.title, preview: session.preview,
                                     startedAt: session.startedAt, updatedAt: session.updatedAt, messageCount: session.messageCount,
                                     source: session.source, isHidden: session.isHidden, isWorking: true, hasUnreadUpdate: session.hasUnreadUpdate)
            }
            let updatedAt: Date?
            if let observedDate = observed.lastUpdatedAt, observedDate > (session.lastUpdatedAt ?? .distantPast) {
                updatedAt = observedDate
            } else {
                updatedAt = session.updatedAt
            }
            return HermesSession(
                id: session.id,
                profileID: session.profileID,
                title: session.title,
                preview: session.preview,
                startedAt: session.startedAt,
                updatedAt: updatedAt,
                messageCount: session.messageCount,
                source: session.source,
                isHidden: session.isHidden,
                // A successful live snapshot also clears missed completion events.
                // Preserve stream state only when that snapshot is unavailable.
                isWorking: working.map { $0.contains(session.id) } ?? observed.isWorking,
                hasUnreadUpdate: observed.hasUnreadUpdate
            )
        }
    }

    static func parseSession(_ row: [String: Any], profileID: String? = nil) -> HermesSession? {
        guard let id = row["id"] as? String else { return nil }
        let timestamp = (row["started_at"] as? NSNumber)?.doubleValue ?? (row["started_at"] as? Double)
        // Hermes persists canonical recency as `last_activity_at`. Older
        // gateway versions may instead expose one of the legacy aliases.
        let updatedAt = dateValue(row["last_activity_at"])
            ?? dateValue(row["updated_at"])
            ?? dateValue(row["last_active"])
            ?? dateValue(row["last_message_at"])
            ?? timestamp.map { Date(timeIntervalSince1970: $0) }
        return HermesSession(
            id: id,
            profileID: profileID,
            title: row["title"] as? String ?? "",
            preview: row["preview"] as? String ?? "",
            startedAt: timestamp.map { Date(timeIntervalSince1970: $0) },
            updatedAt: updatedAt,
            messageCount: (row["message_count"] as? NSNumber)?.intValue ?? 0,
            source: row["source"] as? String ?? "",
            isHidden: row["hidden"] as? Bool ?? false
        )
    }

    static func dateValue(_ value: Any?) -> Date? {
        if let value, !(value is Bool), let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let string = value as? String {
            return sessionDateFormatter.date(from: string)
        }
        return nil
    }

    func rehydrateSubagents(from value: Any?) {
        guard let rows = value as? [[String: Any]] else { return }
        var delegationCalls: [(id: String, args: [String: Any])] = []
        var resultsByID: [String: String] = [:]
        for row in rows {
            scanForDelegation(in: row["content"], calls: &delegationCalls, results: &resultsByID)
            scanForDelegation(in: row["tool_calls"], calls: &delegationCalls, results: &resultsByID)
            scanForDelegation(in: row["parts"], calls: &delegationCalls, results: &resultsByID)
            if (row["role"] as? String) == "tool",
               let id = (row["tool_call_id"] as? String) ?? (row["tool_use_id"] as? String) {
                resultsByID[id] = (row["content"] as? String) ?? Self.messageText(row["content"])
            }
        }
        for (id, args) in delegationCalls {
            if !synthesizedSubagentIDs.contains(id) {
                synthesizeSubagent(toolCallID: id, args: args)
            }
            let matchingIDs = synthesizedSubagentIDs.filter { $0 == id || $0.hasPrefix("\(id):") }
            let needsCompletion = matchingIDs.contains { matchingID in
                activeSubagents.first(where: { $0.id == matchingID }).map {
                    !Self.isTerminalAgentStatus($0.status)
                } ?? false
            }
            if needsCompletion, let result = resultsByID[id] {
                completeSynthesizedSubagent(toolCallID: id, result: result, payload: [:])
            }
        }
    }

    func scanForDelegation(in value: Any?, calls: inout [(id: String, args: [String: Any])], results: inout [String: String]) {
        guard let parts = value as? [[String: Any]] else { return }
        for part in parts {
            let partType = (part["type"] as? String)?.lowercased() ?? ""
            if partType.contains("tool_use") || partType == "function_call" || partType == "tool_call" {
                let name = (part["name"] as? String)
                    ?? ((part["function"] as? [String: Any])?["name"] as? String)
                    ?? ""
                if Self.isDelegationTool(name) {
                    let id = (part["id"] as? String) ?? (part["tool_use_id"] as? String) ?? UUID().uuidString
                    let input = (part["input"] as? [String: Any])
                        ?? Self.parseArgsDict((part["function"] as? [String: Any])?["arguments"])
                        ?? Self.parseArgsDict(part["arguments"])
                        ?? [:]
                    calls.append((id, input))
                }
            }
            if partType.contains("tool_result") {
                if let id = (part["tool_use_id"] as? String) ?? (part["id"] as? String) {
                    let content = (part["content"] as? String) ?? Self.messageText(part["content"])
                    results[id] = content
                }
            }
        }
    }

    func applyTodos(_ todos: [[String: Any]], sessionID: String) {
        let items = todos.compactMap { todo in
            (todo["content"] as? String).map { TodoPlan.Item(content: $0, status: todo["status"] as? String ?? "pending") }
        }
        todoPlan = items.isEmpty ? nil : TodoPlan(sessionID: sessionID, items: items)
    }

    /// Tool arguments as short strings: text as-is, anything else as JSON.
    nonisolated static func textArgs(_ args: [String: Any]?) -> [String: String]? {
        guard let args, !args.isEmpty else { return nil }
        return args.mapValues { value in
            let text = (value as? String) ?? (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
            return String(text.prefix(600))
        }
    }

    nonisolated static func parseArgsDict(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        if let str = value as? String,
           let data = str.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }
        return nil
    }

    /// Reads deferred transcript image files off the main actor and attaches
    /// the decoded images to their messages. Returns the task so tests can
    /// await completion. A stale generation or a session mismatch drops the
    /// payload exactly like a stale resume response.
    @discardableResult
    func rehydratePendingTranscriptImages(
        _ pending: [RestoredTranscript.PendingImages],
        requestedSessionID: String,
        loadData: (@Sendable (URL) -> Data?)? = nil
    ) -> Task<Void, Never> {
        guard !pending.isEmpty else { return Task<Void, Never> {} }
        let generation = sessionResumeGeneration
        return Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) { () -> [(UUID, [Data])] in
                pending.map { entry in
                    (entry.messageID, entry.fileURLs.compactMap { url in
                        loadData.map { loader in loader(url) } ?? (try? Data(contentsOf: url))
                    })
                }
            }.value
            guard generation == sessionResumeGeneration, sessionID == requestedSessionID else { return }
            // One `messages` publication for the whole batch, not one per image.
            var updated = messages
            var changed = false
            for entry in loaded where !entry.1.isEmpty {
                let images = entry.1.compactMap { NSImage(data: $0) }
                guard !images.isEmpty,
                      let index = updated.firstIndex(where: { $0.id == entry.0 }) else { continue }
                updated[index] = updated[index].attachingImages(images)
                changed = true
            }
            if changed { messages = updated }
        }
    }

    /// Long transcripts stalled the main actor on resume. The rows are plain
    /// JSON values and the result carries no images yet, so neither is shared
    /// mutable state across the hop.
    static func parseMessagesOffMain(
        _ value: Any?,
        defaultBotProfileID: String?,
        defaultBotDisplayName: String?
    ) async -> RestoredTranscript {
        let rows = UncheckedTranscriptValue(value: value)
        return await Task.detached(priority: .userInitiated) {
            UncheckedTranscriptValue(value: parseMessages(
                rows.value,
                defaultBotProfileID: defaultBotProfileID,
                defaultBotDisplayName: defaultBotDisplayName
            ))
        }.value.value
    }

    /// The cpipe plugin queues slash commands as an expanded prompt, and that
    /// expansion is what Hermes stores. Restore what the user typed.
    nonisolated static func unwrappedSlashCommand(_ text: String) -> String {
        let intro = "The user explicitly invoked /"
        let marker = "User message (preserved verbatim):\n"
        guard text.hasPrefix(intro), let end = text.range(of: marker) else { return text }
        let name = text.dropFirst(intro.count).prefix { !$0.isWhitespace }
        return "/\(name) " + text[end.upperBound...]
    }

    nonisolated static func parseMessages(_ value: Any?, defaultBotProfileID: String? = nil, defaultBotDisplayName: String? = nil) -> RestoredTranscript {
        guard let rows = value as? [[String: Any]] else {
            return RestoredTranscript(messages: [], pendingImages: [])
        }
        var messages: [ChatMessage] = []
        var pendingImages: [RestoredTranscript.PendingImages] = []
        var rowIDs: [Int: UUID] = [:]
        // Tool calls since the last visible assistant reply; they attach to
        // the next one so restored turns show the same activity as live ones.
        var pendingActivity: [ActiveToolCall] = []
        var turnStartedAt: Date?
        for row in rows {
            guard let role = row["role"] as? String else { continue }
            let rowTimestamp = (row["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            // `display_reasoning` is `reasoning` minus the commentary shown below.
            if let reasoning = ((row["display_reasoning"] ?? row["reasoning"] ?? row["reasoning_content"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reasoning.isEmpty {
                pendingActivity.append(ActiveToolCall(
                    id: "thinking:\(UUID().uuidString)", name: ActiveToolCall.thinkingName, input: "", context: "",
                    startedAt: rowTimestamp ?? Date(), result: reasoning, isComplete: true
                ))
            }
            // Mid-turn Codex commentary splits the turn like live `message.interim`:
            // earlier steps above it, this row's own tool calls below.
            let commentary = ((row["display_commentary"] as? [String]) ?? [])
                .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if role == "assistant", !commentary.isEmpty {
                let activity = pendingActivity
                pendingActivity = []
                let message = ChatMessage(
                    role: .hermes, text: commentary, timestamp: rowTimestamp ?? Date(),
                    responseDuration: activity.isEmpty ? nil : turnStartedAt.flatMap { start in rowTimestamp.map { $0.timeIntervalSince(start) } },
                    botProfileID: defaultBotProfileID, botDisplayName: defaultBotDisplayName, activity: activity
                )
                messages.append(message)
                if let rowID = TranscriptHistoryPaging.rowID(row, key: "row_id") { rowIDs[rowID] = message.id }
            }
            pendingActivity.append(contentsOf: historyToolCalls(in: row, timestamp: rowTimestamp ?? Date()))
            // session.resume projects each tool call as its own compact
            // `{role: tool, name, context}` row.
            if role == "tool" {
                let id = (row["tool_call_id"] as? String) ?? (row["tool_use_id"] as? String) ?? UUID().uuidString
                let result = messageText(row["content"])
                if let index = pendingActivity.firstIndex(where: { $0.id == id }) {
                    if !result.isEmpty { pendingActivity[index].result = truncatedForPersistence(result) }
                } else if let name = row["name"] as? String, !name.isEmpty {
                    pendingActivity.append(ActiveToolCall(
                        id: id, name: name, input: "", context: row["context"] as? String ?? "",
                        startedAt: rowTimestamp ?? Date(), result: result.isEmpty ? nil : truncatedForPersistence(result),
                        isComplete: true
                    ))
                }
                continue
            }
            let persisted = persistedImageContent(from: messageText(row["text"] ?? row["content"]))
            let text = persisted.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !persisted.imageFileURLs.isEmpty else { continue }
            let timestamp = rowTimestamp ?? Date()
            guard role == "user" || role == "assistant" || role == "hermes" || role == "system" else { continue }
            if role == "user", let notices = kanbanNotices(from: text) {
                pendingActivity = []
                turnStartedAt = rowTimestamp
                for (index, notice) in notices.enumerated() {
                    let message = ChatMessage(role: .hermes, text: notice.body, timestamp: timestamp,
                                              botProfileID: notice.profileID, botDisplayName: notice.displayName,
                                              kanbanNotice: KanbanNotice(text: notice.body))
                    messages.append(message)
                    if index == 0, let rowID = TranscriptHistoryPaging.rowID(row, key: "row_id") { rowIDs[rowID] = message.id }
                }
                continue
            }
            if let event = SystemEvent.classify(role: role, text: text, displayKind: row["display_kind"] as? String) {
                let message = ChatMessage(role: .hermes, text: text, timestamp: timestamp, systemEvent: event)
                messages.append(message)
                if let rowID = TranscriptHistoryPaging.rowID(row, key: "row_id") { rowIDs[rowID] = message.id }
                continue
            }
            let attribution = role == "user" ? nil : botAttribution(from: text)
            var activity: [ActiveToolCall] = []
            if role == "user", row["display_kind"] as? String == "steer" {
                // A mid-turn message keeps the turn going: steps before it
                // stay above it instead of being dropped.
                if !pendingActivity.isEmpty {
                    messages.append(ChatMessage(
                        role: .hermes, text: "", timestamp: timestamp,
                        botProfileID: defaultBotProfileID, botDisplayName: defaultBotDisplayName, activity: pendingActivity
                    ))
                    pendingActivity = []
                }
            } else if role == "user" {
                pendingActivity = []
                turnStartedAt = rowTimestamp
            } else {
                activity = pendingActivity
                pendingActivity = []
            }
            let message = ChatMessage(
                role: role == "user" ? .user : .hermes,
                text: attribution?.body ?? (role == "user" ? unwrappedSlashCommand(text) : text),
                images: [],
                timestamp: timestamp,
                responseDuration: activity.isEmpty ? nil : turnStartedAt.flatMap { start in rowTimestamp.map { $0.timeIntervalSince(start) } },
                botProfileID: attribution?.profileID ?? defaultBotProfileID,
                botDisplayName: attribution?.displayName ?? defaultBotDisplayName,
                activity: activity
            )
            messages.append(message)
            if let rowID = TranscriptHistoryPaging.rowID(row, key: "row_id") {
                rowIDs[rowID] = message.id
            }
            if !persisted.imageFileURLs.isEmpty {
                pendingImages.append(RestoredTranscript.PendingImages(
                    messageID: message.id,
                    fileURLs: persisted.imageFileURLs
                ))
            }
        }
        return RestoredTranscript(messages: messages, pendingImages: pendingImages, rowIDs: rowIDs, trailingActivity: pendingActivity)
    }

    /// Tool calls an assistant history row requested, in either the OpenAI
    /// `tool_calls` shape or Anthropic-style `tool_use` content parts.
    nonisolated static func historyToolCalls(in row: [String: Any], timestamp: Date) -> [ActiveToolCall] {
        let parts = ((row["tool_calls"] as? [[String: Any]]) ?? [])
            + ((row["content"] as? [[String: Any]]) ?? []).filter {
                (($0["type"] as? String)?.lowercased() ?? "").contains("tool_use")
            }
        return parts.compactMap { part in
            let function = part["function"] as? [String: Any]
            guard let name = (part["name"] as? String) ?? (function?["name"] as? String), !name.isEmpty else { return nil }
            let args = (part["input"] as? [String: Any]) ?? parseArgsDict(function?["arguments"]) ?? [:]
            let context = ["command", "path", "file_path", "pattern", "query", "url", "goal"]
                .lazy.compactMap { args[$0] as? String }.first ?? ""
            return ActiveToolCall(
                id: (part["id"] as? String) ?? UUID().uuidString,
                name: name,
                input: truncatedForPersistence(args.compactMap { "\($0.key): \($0.value)" }.joined(separator: ", ")),
                context: context,
                startedAt: timestamp,
                isComplete: true,
                args: textArgs(args)
            )
        }
    }

    /// Hermes persists uploaded images as directive lines in the session
    /// transcript. Rehydrate those files for the native transcript instead of
    /// exposing the storage path as user-visible message text. Only file
    /// references are collected here; decoding happens off the main actor in
    /// `rehydratePendingTranscriptImages`.
    nonisolated static func persistedImageContent(from rawText: String) -> (text: String, imageFileURLs: [URL]) {
        let lines = rawText.components(separatedBy: .newlines)
        var imageFileURLs: [URL] = []
        var removedImageReference = false
        var remainingLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Hermes native attachments persist one `[Image attached at: <path>]` handle per line.
            let nativePrefix = "[Image attached at:"
            if trimmed.hasPrefix(nativePrefix), trimmed.hasSuffix("]") {
                removedImageReference = true
                let path = trimmed.dropFirst(nativePrefix.count).dropLast().trimmingCharacters(in: .whitespaces)
                imageFileURLs.append(URL(fileURLWithPath: path))
                continue
            }
            guard trimmed.hasPrefix("@image:") else {
                remainingLines.append(line)
                continue
            }

            removedImageReference = true
            var path = String(trimmed.dropFirst("@image:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if path.count >= 2, path.first == "`", path.last == "`" {
                path.removeFirst()
                path.removeLast()
            }
            imageFileURLs.append(URL(fileURLWithPath: path))
        }

        if removedImageReference {
            remainingLines.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "[screenshot]" }
        }
        // This boundary feeds every restored transcript message, not only
        // messages with image directives. Preserve real line breaks so the
        // Markdown renderer receives the exact persisted body rather than
        // literal `\\n` source characters.
        return (remainingLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), imageFileURLs)
    }

    /// Hermes Bot Mode's documented delivery envelope is:
    /// `Message from 🤖 <sender> (@<profile>): <body>`.
    /// Parse only that exact shape; ordinary assistant prose is untouched.
    nonisolated static func botAttribution(from text: String) -> (displayName: String, profileID: String, body: String)? {
        let prefix = "Message from 🤖 "
        guard text.hasPrefix(prefix),
              let handleStart = text.firstIndex(of: "("),
              handleStart < text.index(before: text.endIndex) else { return nil }
        let handleMarker = text.index(after: handleStart)
        guard text[handleMarker...].hasPrefix("@"),
              let handleEnd = text[handleStart...].firstIndex(of: ")"),
              handleEnd < text.index(before: text.endIndex) else { return nil }
        let colonIndex = text.index(after: handleEnd)
        guard text[colonIndex...].hasPrefix(":"),
              colonIndex < text.index(before: text.endIndex) else { return nil }
        let nameStart = text.index(text.startIndex, offsetBy: prefix.count)
        let displayName = String(text[nameStart..<handleStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        let profileID = String(text[text.index(handleMarker, offsetBy: 1)..<handleEnd])
        let body = String(text[text.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, !profileID.isEmpty, !body.isEmpty else { return nil }
        return (displayName, profileID, body)
    }

    /// Hermes' kanban wake text, e.g. `✔ [board] @sentry Kanban t_c891be93 done — …`.
    /// Hermes tags these rows with nothing, so match only the stable parts: a
    /// leading status glyph and a card id (`t_` + 8 hex). The wording around
    /// them may change. One notice per head line; following lines belong to it.
    /// Stored as `user` rows and streamed live as `status.update` `process`
    /// text; both render as a bubble from the card's bot (first `@name`).
    nonisolated static func kanbanNotices(from text: String) -> [(profileID: String, displayName: String?, body: String)]? {
        var notices: [(profileID: String, displayName: String?, body: String)] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("[INTERNAL NOTIFICATION") { continue }
            if let match = line.wholeMatch(of: kanbanNoticeHead) {
                let profile = match.2.firstMatch(of: /@([\w-]+)/).map { String($0.1) }
                let event = match.2.replacing(/^(?:\[[^\]]+\] )?(?:@[\w-]+ )?/, with: "")
                notices.append((profile ?? "kanban", profile == nil ? "Kanban" : nil, "\(match.1) \(event)"))
            } else if !notices.isEmpty {
                notices[notices.count - 1].body += "\n" + line
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                return nil
            }
        }
        return notices.isEmpty ? nil : notices.map { ($0.profileID, $0.displayName, $0.body.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    nonisolated static func messageText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part in
                if let text = part["text"] as? String { return text }
                if let text = part["content"] as? String { return text }
                return nil
            }.joined()
        }
        return ""
    }
}

private struct UncheckedTranscriptValue<Value>: @unchecked Sendable {
    let value: Value
}
