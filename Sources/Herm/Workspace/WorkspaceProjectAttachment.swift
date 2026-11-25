import Foundation

/// A project inventory refresh changes local attachments, not Hermes sessions.
struct WorkspaceProjectAttachment {
    let tasks: [WorkspaceTask]?
    let references: [ControlReference]?

    init(
        path: String, sessions: [SessionSummary], tasks: [WorkspaceTask], indexBySessionID: [String: Int],
        references: [ControlReference], now: Date
    ) {
        var changed = false
        var updated = tasks
        var added: [WorkspaceTask] = []
        var seen = Set<String>()
        for session in sessions where seen.insert(session.id).inserted {
            if let index = indexBySessionID[session.id] {
                guard updated[index].projectPath != path else { continue }
                updated[index].projectPath = path
                updated[index].updatedAt = now
                changed = true
            } else {
                added.append(
                    WorkspaceTask(
                        title: session.title, status: .inProgress, projectPath: path, sessionID: session.id,
                        createdAt: now, updatedAt: now))
            }
        }
        self.tasks = added.isEmpty ? (changed ? updated : nil) : Array(added.reversed()) + updated
        if added.isEmpty {
            self.references = nil
        } else {
            var seenReferences = Set(references.map(\.id))
            let additions = added.compactMap { task -> ControlReference? in
                guard let sessionID = task.sessionID else { return nil }
                let reference = ControlReference(
                    source: .hermesSession, sourceID: sessionID, sessionID: sessionID, projectID: path)
                return seenReferences.insert(reference.id).inserted ? reference : nil
            }
            self.references = additions.isEmpty ? nil : references + additions
        }
    }
}
