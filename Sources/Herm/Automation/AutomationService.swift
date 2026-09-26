import Foundation

/// Typed, fail-closed boundary for secondary automation projections.
@MainActor
final class AutomationService {
    private(set) var state: AutomationProjectionState = .loading

    static func parseSnapshot(_ payload: [String: Any]) throws -> AutomationSnapshot {
        guard let cronPayload = payload["cron"] as? [String: Any],
              let kanbanPayload = payload["kanban"] as? [String: Any],
              let goalsPayload = payload["goals"] as? [String: Any],
              let loopsPayload = payload["loops"] as? [String: Any],
              let heartbeatsPayload = payload["heartbeats"] as? [String: Any],
              let cron = parseCron(cronPayload),
              let kanban = parseKanban(kanbanPayload),
              let goals = parseGoals(goalsPayload),
              let loops = parseLoops(loopsPayload),
              let heartbeats = parseHeartbeats(heartbeatsPayload) else {
            throw AutomationParseError.malformedEnvelope
        }
        return AutomationSnapshot(cron: cron, kanban: kanban, goals: goals, loops: loops, heartbeats: heartbeats)
    }

    static func parseCron(_ payload: [String: Any]) -> [AutomationCronJob]? {
        guard let rows = payload["jobs"] as? [[String: Any]] else { return nil }
        return parseRows(rows, id: { $0["id"] ?? $0["job_id"] }) { row in
            guard let id = nonEmpty(row["id"] ?? row["job_id"]),
                  let name = nonEmpty(row["name"]), let schedule = nonEmpty(row["schedule"]) else { return nil }
            let skills = (row["skills"] as? [String]) ?? []
            return AutomationCronJob(id: id, name: name, schedule: schedule,
                enabled: (row["enabled"] as? Bool) ?? !(row["paused"] as? Bool ?? false),
                skills: skills, prompt: row["prompt"] as? String ?? row["request"] as? String ?? row["task"] as? String,
                model: row["model"] as? String, provider: row["provider"] as? String,
                workdir: row["workdir"] as? String, delivery: row["delivery"] as? String ?? row["deliver"] as? String,
                script: row["script"] as? String, noAgent: row["no_agent"] as? Bool,
                chain: row["chain"] as? String, monitor: row["monitor"] as? String,
                attachSession: row["attach_session"] as? Bool, repeatStatus: row["repeat_status"] as? String)
        }
    }

    static func parseKanban(_ payload: [String: Any]) -> [AutomationKanbanTask]? {
        guard let rows = payload["tasks"] as? [[String: Any]] else { return nil }
        return parseRows(rows, id: { $0["id"] }) { row in
            guard let id = nonEmpty(row["id"]), let title = nonEmpty(row["title"]), let status = nonEmpty(row["status"]) else { return nil }
            return AutomationKanbanTask(id: id, title: title, status: status)
        }
    }

    static func parseGoals(_ payload: [String: Any]) -> [AutomationGoal]? {
        guard let rows = payload["goals"] as? [[String: Any]] else { return nil }
        return parseRows(rows, id: { $0["id"] }) { row in
            guard let id = nonEmpty(row["id"]), let title = nonEmpty(row["title"]), let status = nonEmpty(row["status"]) else { return nil }
            return AutomationGoal(id: id, title: title, status: status)
        }
    }

    static func parseLoops(_ payload: [String: Any]) -> [AutomationLoop]? {
        guard let rows = payload["loops"] as? [[String: Any]] else { return nil }
        return parseRows(rows, id: { $0["id"] }) { row in
            guard let id = nonEmpty(row["id"]), let name = nonEmpty(row["name"]), let status = nonEmpty(row["status"]) else { return nil }
            return AutomationLoop(id: id, name: name, status: status)
        }
    }

    static func parseHeartbeats(_ payload: [String: Any]) -> [AutomationHeartbeat]? {
        guard let rows = payload["heartbeats"] as? [[String: Any]] else { return nil }
        return parseRows(rows, id: { $0["id"] }) { row in
            guard let id = nonEmpty(row["id"]), let status = nonEmpty(row["status"]) else { return nil }
            return AutomationHeartbeat(id: id, status: status, lastSeen: row["last_seen"] as? String ?? row["lastSeen"] as? String)
        }
    }

    func refresh(using transport: AutomationTransport) async {
        do { state = .ready(try await transport.fetchAutomationSnapshot()) }
        catch {
            if case .ready(let snapshot) = state { state = .stale(snapshot, safeMessage: "Automation refresh failed; showing the last successful snapshot.") }
            else { state = .failed("Automation refresh failed. Try again.") }
        }
    }

    /// Confirmation belongs to the caller. A successful mutation is not shown
    /// until Hermes has been read back through a fresh snapshot.
    func perform(_ request: AutomationOperationRequest, confirmed: Bool, gate: AutomationCapabilityGate, using transport: AutomationTransport) async -> Bool {
        guard confirmed, gate.allows(request.operation) else { return false }
        do {
            try await transport.perform(request)
            await refresh(using: transport)
            return true
        } catch { return false }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func parseRows<T>(_ rows: [[String: Any]], id: ([String: Any]) -> Any?, _ parser: ([String: Any]) -> T?) -> [T]? {
        var seen = Set<String>(); var result: [T] = []
        for row in rows {
            guard let value = parser(row), let rawID = nonEmpty(id(row)) else { return nil }
            guard seen.insert(rawID).inserted else { return nil }
            result.append(value)
        }
        return result
    }
}

enum AutomationParseError: Error { case malformedEnvelope }
