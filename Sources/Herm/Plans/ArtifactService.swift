import Foundation

/// Mirrors Hermes Desktop's artifact index (apps/desktop/src/app/artifacts/artifact-utils.ts):
/// artifacts are deliverables the agent surfaced — `MEDIA:` tags, images, links and
/// document/media paths in replies, plus paths returned by producer tools. Source
/// edits (write_file/patch on code) are not artifacts.
struct ArtifactService {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
    private static let mediaPattern = regex(#"[`"']?MEDIA:\s*(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|\S+)"#)
    private static let markdownImagePattern = regex(#"!\[[^\]]*\]\(([^)\s]+)\)"#)
    private static let markdownLinkPattern = regex(#"\[[^\]]+\]\(([^)\s]+)\)"#)
    private static let urlPattern = regex(#"(https?://[^\s<>"')`]+)"#)
    private static let windowsPathPattern = regex(#"(?:^|[\s("'`])((?:[A-Za-z]:[\\/]|\\\\)[^\s"'`<>]+)"#)
    private static let pathPattern = regex(#"(?:^|[\s("'`])((?:/|~[\\/]|\.\.?[\\/])[^\s"'`<>]+)"#)
    private static let screenshotPattern = regex(#"Screenshot path:\s*([^\r\n<>]+)"#)
    private static let imageExtension = regex(#"\.(?:png|jpe?g|gif|webp|svg|bmp)(?:\?.*)?$"#)
    private static let fileExtension = regex(
        #"\.(?:png|jpe?g|gif|webp|svg|bmp|pdf|txt|json|md|csv|xlsx?|docx?|pptx?|html|zip|tar|gz|avi|flac|m4a|mkv|mp3|ogg|opus|wav|webm|mp4|mov)(?:\?.*)?$"#
    )
    private static let filePathPrefix = regex(#"^(?:file:|/|[~.][\\/]|\.\.[\\/]|[A-Za-z]:[\\/]|\\\\)"#)
    private static let producerTool = regex(
        #"(?:^|_)(?:creat(?:e|ion)|download|export|generat(?:e|ion)|render|save|speech|tts|write)(?:_|$)"#)
    private static let strongKey = regex(
        #"^(?:artifact_(?:file|image|path|url)|files?_(?:created|modified|written)|generated_(?:file|image|path|url)|media_tag|output_(?:file|path|url)|result_(?:file|path|url)|saved_to|screenshot_path)$"#
    )
    private static let producerKey = regex(
        #"^(?:artifact(?:s|_(?:file|image|path|url))?|attachment(?:s|_(?:file|image|path|url))?|download(?:s|_(?:file|path|url))?|(?:audio|image|video)(?:_(?:file|path|url))?|file_path|local_path|media(?:_(?:file|path|url))?|path)$"#
    )

    struct PageResult: Sendable {
        let records: [ArtifactRecord]
        let messageCount: Int
        let hasMore: Bool
    }

    // Consume the entire response off the main actor; retain only compact artifact records.
    nonisolated static func extractPageInBackground(session: HermesSession, page: sending [String: Any]) async throws
        -> PageResult
    {
        try Task.checkCancellation()
        guard let messages = page["data"] as? [[String: Any]] ?? page["messages"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        let pagination = page["pagination"] as? [String: Any]
        let limit = pagination?["limit"] as? Int
        if pagination != nil && (limit ?? 0) <= 0 {
            throw HermesGateway.GatewayError.malformedResponse
        }
        let records = extract(session: session, messages: messages)
        try Task.checkCancellation()
        return PageResult(
            records: records, messageCount: messages.count,
            hasMore: limit.map { messages.count >= $0 } ?? false)
    }

    static func extract(session: HermesSession, messages: [[String: Any]]) -> [ArtifactRecord] {
        let fallback = session.lastUpdatedAt ?? session.startedAt ?? .now
        var found: [String: ArtifactRecord] = [:]

        for message in messages {
            guard !Task.isCancelled else { return [] }
            let role = (message["role"] as? String ?? "").lowercased()
            let date =
                (message["timestamp"] as? Double).map {
                    Date(timeIntervalSince1970: $0 < 10_000_000_000 ? $0 : $0 / 1000)
                } ?? fallback
            // First mention wins, like Desktop.
            func push(_ raw: String, explicit: Bool = false) {
                let value = normalize(raw)
                guard !value.isEmpty, found[value] == nil, looksLikeArtifact(value, explicit: explicit) else { return }
                found[value] = ArtifactRecord(
                    value: value, sessionID: session.id, sessionTitle: session.displayTitle,
                    timestamp: date, origin: role == "tool" ? .generated : .shared, profileID: session.profileID)
            }
            let text = messageText(message)

            if role == "assistant" {
                collectText(text, push)
                continue
            }
            guard role == "tool" else { continue }

            let name = ((message["tool_name"] as? String) ?? (message["name"] as? String) ?? "").trimmingCharacters(
                in: .whitespacesAndNewlines
            ).lowercased()
            let producer = test(producerTool, name) || name.hasPrefix("bfl_flux3_")
            if producer || name == "terminal" { collectText(text, push) }
            if name == "browser_vision" { for match in matches(screenshotPattern, in: text) { push(match) } }

            var payloads = [text, untrustedPayload(text)].compactMap { $0 }.compactMap(parseJSON)
            if let content = message["content"], content is [Any] || content is [String: Any] {
                let object = content as? [String: Any]
                payloads.append(object?["_multimodal"] as? Bool == true ? object?["meta"] as Any : content)
            }
            for payload in payloads {
                collectStrings(payload, keyPath: "tool_result") { value, keyPath in
                    let shellOutput =
                        name == "terminal"
                        && keyPath.split(separator: ".").contains { ["output", "stdout", "path"].contains(String($0)) }
                    if shellOutput {
                        collectText(value, push)
                        return
                    }
                    guard explicitKey(keyPath, producer: producer) else { return }
                    for media in mediaValues(value) { push(media, explicit: true) }
                    push(value)
                }
            }
        }
        return found.values.sorted { $0.timestamp > $1.timestamp }
    }

    /// Files a response's own producer tool calls (image_generate, text_to_speech,
    /// document/PDF writers…) delivered, for inline display under the reply.
    static func deliveredFiles(in calls: [ActiveToolCall]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for call in calls where call.isComplete {
            let name = call.name.lowercased()
            let producer = test(producerTool, name) || name.hasPrefix("bfl_flux3_")
            guard producer, let text = call.result else { continue }
            func push(_ raw: String, explicit: Bool) {
                let value = normalize(raw)
                guard !value.isEmpty, looksLikeArtifact(value, explicit: explicit), seen.insert(value).inserted else {
                    return
                }
                out.append(value)
            }
            for media in mediaValues(text) { push(media, explicit: true) }
            for payload in [text, untrustedPayload(text)].compactMap({ $0 }).compactMap(parseJSON) {
                collectStrings(payload, keyPath: "tool_result") { value, keyPath in
                    guard explicitKey(keyPath, producer: true) else { return }
                    push(value, explicit: true)
                }
            }
        }
        return out
    }

    static func filter(_ records: [ArtifactRecord], query: String = "", kind: ArtifactKind? = nil) -> [ArtifactRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { record in
            (kind == nil || record.kind == kind)
                && (normalized.isEmpty || record.label.lowercased().contains(normalized)
                    || record.value.lowercased().contains(normalized)
                    || record.sessionTitle.lowercased().contains(normalized))
        }
    }

    static func kind(for value: String) -> ArtifactKind {
        if value.hasPrefix("data:image/") || test(imageExtension, value) { return .image }
        return isFilePath(value) ? .file : .link
    }

    // MARK: - Desktop rules

    private static func looksLikeArtifact(_ value: String, explicit: Bool) -> Bool {
        if !explicit {
            let path = (URL(string: value)?.path.removingPercentEncoding ?? value).replacingOccurrences(
                of: "\\", with: "/"
            ).lowercased()
            if path.contains("/.cache/pip/") || path.contains("/library/caches/pip/")
                || path.contains("/appdata/local/pip/cache/") || path.hasSuffix(".whl")
                || path.hasSuffix(".whl.metadata")
            {
                return false
            }
            if value.lowercased().hasPrefix("http"), path.contains("/packages/"),
                [
                    ".tar.gz", ".tar.bz2", ".zip", ".egg", ".zip.metadata", ".egg.metadata", ".tar.gz.metadata",
                    ".tar.bz2.metadata",
                ].contains(where: path.hasSuffix)
            {
                return false
            }
        }
        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("data:image/") { return true }
        guard isFilePath(value) else { return false }
        // An explicit MEDIA: delivery counts even without a known extension.
        return explicit || test(fileExtension, value)
    }

    private static func isFilePath(_ value: String) -> Bool {
        test(filePathPrefix, value)
    }

    private static func collectText(_ text: String, _ push: (String, Bool) -> Void) {
        for media in mediaValues(text) { push(media, true) }
        for match in matches(markdownImagePattern, in: text) { push(match, false) }
        for match in matches(markdownLinkPattern, in: text) { push(match, false) }
        for match in matches(urlPattern, in: text) { push(match, false) }
        for match in matches(pathPattern, in: text) { push(match, false) }
        for match in matches(windowsPathPattern, in: text) { push(match, false) }
    }

    static func mediaValues(_ text: String) -> [String] {
        guard text.contains("MEDIA:") else { return [] }
        return matches(mediaPattern, in: text).map { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let quote = trimmed.first, "\"'`".contains(quote), trimmed.count > 1, trimmed.last == quote {
                return String(trimmed.dropFirst().dropLast())
            }
            return trimmed.replacingOccurrences(of: #"[`"'*_]{1,3}$"#, with: "", options: .regularExpression)
        }
    }

    private static func explicitKey(_ keyPath: String, producer: Bool) -> Bool {
        keyPath.split(separator: ".").map(String.init).filter { Int($0) == nil }.contains { segment in
            test(strongKey, segment) || (producer && test(producerKey, segment))
        }
    }

    private static func messageText(_ message: [String: Any]) -> String {
        for key in ["content", "text", "context"] {
            if let text = message[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return ""
    }

    private static func untrustedPayload(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<untrusted_tool_result"), let open = trimmed.firstIndex(of: ">"),
            let close = trimmed.range(of: "</untrusted_tool_result>", options: .backwards), open < close.lowerBound
        else { return nil }
        let wrapped = trimmed[trimmed.index(after: open)..<close.lowerBound].trimmingCharacters(
            in: .whitespacesAndNewlines)
        return wrapped.range(of: "\n\n").map { String(wrapped[$0.upperBound...]) } ?? wrapped
    }

    private static func parseJSON(_ text: String) -> Any? {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func collectStrings(_ value: Any, keyPath: String, _ collector: (String, String) -> Void) {
        if let string = value as? String { collector(string, keyPath) }
        if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                collectStrings(child, keyPath: "\(keyPath).\(index)", collector)
            }
        }
        if let object = value as? [String: Any] {
            for (key, child) in object { collectStrings(child, keyPath: "\(keyPath).\(key)", collector) }
        }
    }

    private static func test(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> [String] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func normalize(_ value: String) -> String {
        var trimmed = value
        if trimmed.hasPrefix("#media:") {
            trimmed = String(trimmed.dropFirst(7)).removingPercentEncoding ?? trimmed
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<3 {
            guard let quote = trimmed.first, "\"'`".contains(quote), trimmed.count > 1, trimmed.last == quote else {
                break
            }
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        trimmed = trimmed.replacingOccurrences(of: #"[`*]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[),.;]+$"#, with: "", options: .regularExpression)
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) { return url.path }
        return trimmed
    }
}
