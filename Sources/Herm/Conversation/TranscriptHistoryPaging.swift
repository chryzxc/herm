import Foundation

/// Position in a stored Hermes transcript that is paged over REST instead of
/// being shipped whole in the `session.resume` response.
///
/// Hermes' `/api/sessions/{id}/messages?order=latest` measures `offset` back
/// from the newest stored row and returns each page in chronological order,
/// so `nextOffset` is simply the number of rows already fetched. Rows appended
/// by live turns while the reader pages shift those offsets forward; the
/// overlap they cause is removed by `seenRowIDs`.
struct TranscriptHistoryCursor: Equatable {
    let storageSessionID: String
    let profileID: String?
    var nextOffset = 0
    var hasMore = true
    var seenRowIDs: Set<Int> = []
}

/// A page of older history inserted at the front of the canonical transcript.
/// The transcript view shifts its mounted window by `count` so the rows the
/// reader is looking at stay mounted and in place.
/// A user prompt Hermes lists in a session's timeline. The navigator shows
/// prompts older than the loaded transcript so search and jump reach history
/// that has not been paged in yet.
struct TranscriptTimelineEntry: Equatable {
    let rowID: Int
    let preview: String
    let timestamp: Double?
}

struct TranscriptHistoryPrepend: Equatable {
    let generation: Int
    let count: Int
    let resultingCount: Int
}

enum TranscriptHistoryPaging {
    /// Rows per REST page. Matches the Hermes desktop client's tail size.
    static let pageRowLimit = 120
    /// Hermes caps a single page at 500 rows.
    static let maximumPageRowLimit = 500
    /// Tool-heavy stretches can yield pages with no visible message; keep
    /// reading older pages, but never unboundedly in one load.
    static let maximumPagesPerLoad = 8
    /// Hermes caps a timeline page at 500 prompts.
    static let timelinePageLimit = 500
    /// Bounds one timeline read at 10,000 prompts.
    static let maximumTimelinePages = 20

    static func pagePath(sessionID: String, profileID: String?, limit: Int, offset: Int) -> String? {
        sessionPath(
            sessionID: sessionID, endpoint: "messages", profileID: profileID,
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "order", value: "latest"),
                // Rows archived by in-place compaction are still display history;
                // without them the transcript ends at the compaction boundary.
                URLQueryItem(name: "include_compacted", value: "true"),
            ])
    }

    static func timelinePath(sessionID: String, profileID: String?, afterRowID: Int) -> String? {
        sessionPath(
            sessionID: sessionID, endpoint: "timeline", profileID: profileID,
            query: [
                URLQueryItem(name: "limit", value: String(timelinePageLimit)),
                URLQueryItem(name: "after_row_id", value: String(afterRowID)),
            ])
    }

    static func sessionPath(sessionID: String, endpoint: String, profileID: String?, query: [URLQueryItem]) -> String? {
        var pathAllowed = CharacterSet.urlPathAllowed
        pathAllowed.remove(charactersIn: "/")
        guard let encodedID = sessionID.addingPercentEncoding(withAllowedCharacters: pathAllowed) else { return nil }
        var components = URLComponents()
        components.percentEncodedPath = "/api/sessions/\(encodedID)/\(endpoint)"
        var query = query
        if let profileID = profileID?.trimmingCharacters(in: .whitespacesAndNewlines), !profileID.isEmpty {
            query.append(URLQueryItem(name: "profile", value: profileID))
        }
        components.queryItems = query
        return components.string
    }

    /// True when Hermes accepted the paged-resume flags and left the
    /// transcript out of the resume response. Older Hermes builds ignore the
    /// flags and inline the full transcript, which callers keep using.
    static func resumeResponseDefersTranscript(_ result: [String: Any]) -> Bool {
        if let inline = result["messages"] as? [[String: Any]], !inline.isEmpty { return false }
        return result["hydrating"] != nil || (result["messages_omitted"] as? Bool) == true
    }

    struct Page {
        let rows: [[String: Any]]
        /// Stored rows the server counted toward `offset`.
        let returned: Int
        /// Legacy backends without paging return the full transcript and no
        /// `pagination` object.
        let isPaginated: Bool
    }

    static func page(from response: [String: Any]) -> Page? {
        guard let rows = response["messages"] as? [[String: Any]] else { return nil }
        guard let pagination = response["pagination"] as? [String: Any] else {
            return Page(rows: rows, returned: rows.count, isPaginated: false)
        }
        let returned =
            (pagination["returned"] as? Int)
            ?? (pagination["returned"] as? NSNumber)?.intValue
            ?? rows.count
        return Page(rows: rows, returned: returned, isPaginated: true)
    }

    /// Advances `cursor` past `page` and returns the page's rows that were not
    /// already delivered, still in chronological order.
    static func advance(_ cursor: inout TranscriptHistoryCursor, with page: Page, limit: Int) -> [[String: Any]] {
        cursor.nextOffset += page.returned
        cursor.hasMore = page.isPaginated && page.returned >= limit && page.returned > 0
        return page.rows.filter { row in
            guard let id = rowID(row) else { return true }
            return cursor.seenRowIDs.insert(id).inserted
        }
    }

    static func rowID(_ row: [String: Any], key: String = "id") -> Int? {
        (row[key] as? Int) ?? (row[key] as? NSNumber)?.intValue
    }

    /// Entries of one timeline page and the cursor for the next, if any.
    static func timelinePage(from response: [String: Any]) -> (entries: [TranscriptTimelineEntry], nextCursor: Int?)? {
        guard let rows = response["entries"] as? [[String: Any]] else { return nil }
        let entries = rows.compactMap { row -> TranscriptTimelineEntry? in
            guard let id = rowID(row, key: "row_id") else { return nil }
            let timestamp = (row["timestamp"] as? Double) ?? (row["timestamp"] as? NSNumber)?.doubleValue
            return TranscriptTimelineEntry(rowID: id, preview: row["preview"] as? String ?? "", timestamp: timestamp)
        }
        let pagination = response["pagination"] as? [String: Any]
        guard (pagination?["has_more"] as? Bool) == true,
            let next = pagination.flatMap({ rowID($0, key: "next_cursor") })
        else { return (entries, nil) }
        return (entries, next)
    }

    /// Projects stored REST rows into the `{role, text, row_id, timestamp}` shape the
    /// gateway's resume transcript uses, applying the same display rules
    /// Hermes applies there: hidden scaffolding never renders, system rows
    /// keep their `display_kind` for the system card, compaction summaries show their display projection, and a
    /// slash-skill turn shows the invocation instead of the expanded skill.
    static func displayRows(fromStoredRows rows: [[String: Any]]) -> [[String: Any]] {
        rows.compactMap { row in
            guard let role = row["role"] as? String else { return nil }
            guard (row["display_kind"] as? String) != "hidden" else { return nil }
            // Tool rows and tool-only assistant rows carry the turn's
            // activity; `parseMessages` attaches it to the next reply.
            if role == "tool" {
                var tool: [String: Any] = [
                    "role": "tool", "name": (row["tool_name"] ?? row["name"]) as? String ?? "tool",
                ]
                for key in ["tool_call_id", "timestamp"] { tool[key] = row[key] }
                // The result feeds delivered-file cards, diffs and error states, as live.
                let result = storedText(row["content"])
                if !result.isEmpty { tool["content"] = result }
                return tool
            }
            guard role == "user" || role == "assistant" || role == "system" else { return nil }
            var activity: [String: Any] = [:]
            if role == "assistant" {
                var toolCalls = row["tool_calls"]
                if let encoded = toolCalls as? String {
                    toolCalls = try? JSONSerialization.jsonObject(with: Data(encoded.utf8))
                }
                activity["tool_calls"] = toolCalls as? [[String: Any]]
                // Codex commentary rides beside empty `content`; live it arrives as `message.interim`.
                activity["display_commentary"] = row["display_commentary"] as? [String]
                activity["reasoning"] =
                    (row["display_reasoning"] ?? row["reasoning"] ?? row["reasoning_content"]) as? String
            }
            var text = storedText(row["display_content"] as? String ?? row["content"])
            if role == "user" {
                text = text.replacingOccurrences(
                    of:
                        #"(^|\n)\[Triggering message id: `[^`\n]*` — use as `message_id` for reply/react/pin via the discord tools\.\]\n*"#,
                    with: "$1",
                    options: .regularExpression
                )
                if let invocation = skillInvocationText(text) { text = invocation }
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !activity.isEmpty else { return nil }
            var display: [String: Any] = activity.merging(["role": role, "text": text]) { _, new in new }
            if let id = rowID(row) { display["row_id"] = id }
            if let uid = row["message_uid"] as? String { display["message_uid"] = uid }
            if let timestamp = row["timestamp"] { display["timestamp"] = timestamp }
            if let kind = row["display_kind"] as? String { display["display_kind"] = kind }
            return display
        }
    }

    private static func storedText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { ($0["text"] as? String) ?? ($0["content"] as? String) }.joined()
        }
        return ""
    }

    private static let skillInvocationPrefix = "[IMPORTANT: The user has invoked the "

    /// Mirrors Hermes' `describe_skill_invocation(content, separator=" ")`.
    static func skillInvocationText(_ text: String) -> String? {
        guard text.hasPrefix(skillInvocationPrefix) else { return nil }
        let afterPrefix = text.dropFirst(skillInvocationPrefix.count)
        var name = ""
        if afterPrefix.first == "\"",
            let close = afterPrefix.dropFirst().firstIndex(of: "\"")
        {
            name = String(afterPrefix[afterPrefix.index(after: afterPrefix.startIndex)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let label = name.hasPrefix("/") ? name : "/\(name)"
        var instruction: String?
        if text.contains(" skill bundle,") {
            instruction = cut(text, after: "\nUser instruction: ", until: "\n\n[Loaded as part of the ", fromEnd: false)
        } else if text.contains("The full skill content is loaded below.]") {
            instruction = cut(
                text,
                after: "The user has provided the following instruction alongside the skill invocation: ",
                until: "\n\n[Runtime note:",
                fromEnd: true
            )
        }
        if let instruction {
            let collapsed = instruction.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !collapsed.isEmpty { return name.isEmpty ? collapsed : "\(label) \(collapsed)" }
        }
        return name.isEmpty ? nil : label
    }

    private static func cut(_ text: String, after marker: String, until stop: String, fromEnd: Bool) -> String? {
        guard let range = text.range(of: marker, options: fromEnd ? .backwards : []) else { return nil }
        let tail = text[range.upperBound...]
        let body = tail.range(of: stop).map { tail[..<$0.lowerBound] } ?? tail
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
