import Foundation

struct ArtifactService {
    private static let mediaPattern = try! NSRegularExpression(pattern: #"(?:MEDIA:\s*|!\[[^\]]*\]\(|\[[^\]]+\]\()([^\s)]+)"#, options: [.caseInsensitive])
    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>\"')]+"#, options: [.caseInsensitive])
    private static let pathPattern = try! NSRegularExpression(pattern: #"(?:^|[\s(\"'`])((?:/|~/|\.\.?/)[^\s\"'`<>]+)"#, options: [.caseInsensitive])
    private static let windowsPathPattern = try! NSRegularExpression(pattern: #"(?:^|[\s(\"'`])([A-Za-z]:[\\/][^\s\"'`<>]+)"#, options: [.caseInsensitive])

    static func extract(session: HermesSession, messages: [[String: Any]]) -> [ArtifactRecord] {
        var values: [String] = []
        for message in messages {
            let role = (message["role"] as? String ?? "").lowercased()
            let producer = role == "tool" || role == "assistant"
            guard producer else { continue }
            collectStrings(message["content"], into: &values, allowBarePaths: role == "tool")
            if let text = message["text"] as? String { collect(text, into: &values, allowBarePaths: role == "tool") }
            if let content = message["content"] as? String { collect(content, into: &values, allowBarePaths: role == "tool") }
        }

        var seen = Set<String>()
        return values.compactMap { raw in
            let value = normalize(raw)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return ArtifactRecord(value: value, sessionID: session.id, sessionTitle: session.displayTitle, timestamp: session.lastUpdatedAt ?? session.startedAt ?? .now)
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    static func filter(_ records: [ArtifactRecord], query: String = "", kind: ArtifactKind? = nil) -> [ArtifactRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { record in
            (kind == nil || record.kind == kind) &&
            (normalized.isEmpty || record.label.lowercased().contains(normalized) || record.value.lowercased().contains(normalized) || record.sessionTitle.lowercased().contains(normalized))
        }
    }

    static func kind(for value: String) -> ArtifactKind {
        let lower = value.lowercased().split(separator: "?").first.map(String.init) ?? value.lowercased()
        if lower.hasPrefix("data:image/") || ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "heic"].contains(URL(fileURLWithPath: lower).pathExtension) { return .image }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return .link }
        return .file
    }

    private static func collectStrings(_ value: Any?, into values: inout [String], allowBarePaths: Bool) {
        if let string = value as? String { collect(string, into: &values, allowBarePaths: allowBarePaths); return }
        if let array = value as? [Any] { array.forEach { collectStrings($0, into: &values, allowBarePaths: allowBarePaths) }; return }
        if let object = value as? [String: Any] { object.forEach { collectStrings($0.value, into: &values, allowBarePaths: allowBarePaths) } }
    }

    private static func collect(_ text: String, into values: inout [String], allowBarePaths: Bool) {
        let range = NSRange(text.startIndex..., in: text)
        for match in mediaPattern.matches(in: text, range: range) { if let value = capture(match, in: text) { values.append(value) } }
        for match in urlPattern.matches(in: text, range: range) { if let value = capture(match, in: text) { values.append(value) } }
        values.append(contentsOf: text.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") })
        if allowBarePaths {
            for pattern in [pathPattern, windowsPathPattern] {
                for match in pattern.matches(in: text, range: range) { if let value = capture(match, in: text) { values.append(value) } }
            }
        }
    }

    private static func capture(_ match: NSTextCheckingResult, in text: String) -> String? {
        guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "`\"'.,;"))
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) { return url.path }
        return trimmed
    }
}
