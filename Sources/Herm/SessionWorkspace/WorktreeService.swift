import Foundation

/// Parses only the documented, structured JSON summary fixture. It never invokes Hermes.
enum WorktreeService {
    private static let allowedTopLevel: Set<String> = ["session_id", "status", "export", "history", "worktree"]
    private static let allowedExportKeys: Set<String> = ["format", "record_count"]
    private static let allowedHistoryKeys: Set<String> = ["event_count", "latest_at"]
    private static let allowedWorktreeKeys: Set<String> = ["id", "session_id", "state"]
    private static let forbiddenKeys: Set<String> = [
        "prompt", "prompts", "transcript", "transcripts", "messages", "raw", "content",
        "path", "cwd", "branch", "branch_contents", "files", "secret", "token", "api_key", "credential"
    ]

    static func parse(data: Data, forSessionID expectedSessionID: String) -> SessionWorkspaceProjection? {
        guard !expectedSessionID.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let root = object as? [String: Any],
              root.keys.allSatisfy({ allowedTopLevel.contains($0) }),
              !containsForbiddenKey(root)
        else { return nil }

        guard let sessionID = root["session_id"] as? String,
              validIdentifier(sessionID), sessionID == expectedSessionID else {
            return projection(sessionID: expectedSessionID, state: .malformed)
        }

        let state: WorktreeReadState
        if let rawStatus = root["status"] {
            guard let status = rawStatus as? String, let parsed = WorktreeReadState(rawValue: status) else {
                return projection(sessionID: sessionID, state: .malformed)
            }
            state = parsed
        } else {
            state = .ready
        }

        var exportSummary: SessionExportSummary?
        if let raw = root["export"] {
            guard let value = raw as? [String: Any],
                  value.keys.allSatisfy({ allowedExportKeys.contains($0) }),
                  let format = value["format"] as? String,
                  let recordCount = integer(value["record_count"]), recordCount >= 0 else {
                return projection(sessionID: sessionID, state: .malformed)
            }
            guard ["jsonl", "md", "qmd", "html", "trace"].contains(format) else {
                return projection(sessionID: sessionID, state: .malformed)
            }
            guard format == "jsonl" else {
                return projection(sessionID: sessionID, state: .unsupported)
            }
            exportSummary = SessionExportSummary(sessionID: sessionID, format: format, recordCount: recordCount)
        }

        var historySummary: SessionHistorySummary?
        if let raw = root["history"] {
            guard let value = raw as? [String: Any],
                  value.keys.allSatisfy({ allowedHistoryKeys.contains($0) }),
                  let eventCount = integer(value["event_count"]), eventCount >= 0 else {
                return projection(sessionID: sessionID, state: .malformed)
            }
            var latestAt: Date?
            if let rawDate = value["latest_at"] {
                guard let dateString = rawDate as? String else {
                    return projection(sessionID: sessionID, state: .malformed)
                }
                latestAt = ISO8601DateFormatter().date(from: dateString)
                guard latestAt != nil else { return projection(sessionID: sessionID, state: .malformed) }
            }
            historySummary = SessionHistorySummary(sessionID: sessionID, eventCount: eventCount, latestAt: latestAt)
        }

        var worktreeSummary: WorktreeSummary?
        if let raw = root["worktree"] {
            guard let value = raw as? [String: Any],
                  value.keys.allSatisfy({ allowedWorktreeKeys.contains($0) }),
                  let worktreeID = value["id"] as? String,
                  let ownerID = value["session_id"] as? String,
                  let rawWorktreeState = value["state"] as? String,
                  validIdentifier(worktreeID), ownerID == sessionID,
                  let worktreeState = WorktreeReadState(rawValue: rawWorktreeState) else {
                return projection(sessionID: sessionID, state: .malformed)
            }
            worktreeSummary = WorktreeSummary(sessionID: sessionID, worktreeID: worktreeID, state: worktreeState)
        }

        return SessionWorkspaceProjection(sessionID: sessionID, state: state, export: exportSummary, history: historySummary, worktree: worktreeSummary)
    }

    private static func projection(sessionID: String, state: WorktreeReadState) -> SessionWorkspaceProjection {
        SessionWorkspaceProjection(sessionID: sessionID, state: state, export: nil, history: nil, worktree: nil)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 && !value.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7F })
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c",
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }

    private static func containsForbiddenKey(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary.keys.contains(where: { forbiddenKeys.contains($0.lowercased()) }) { return true }
            return dictionary.values.contains(where: containsForbiddenKey)
        }
        if let array = value as? [Any] { return array.contains(where: containsForbiddenKey) }
        return false
    }
}
