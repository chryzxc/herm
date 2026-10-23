import Foundation

@MainActor
final class AppleRemindersAdapter {
    enum AdapterError: LocalizedError {
        case unavailable(String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .unavailable(let detail): detail
            case .malformedResponse: "Apple Reminders returned unreadable data."
            }
        }
    }

    private let client: HermesRPCClientProtocol

    init(client: HermesRPCClientProtocol) {
        self.client = client
    }

    func today() async throws -> [ReminderSummary] {
        let result = try await client.request(
            HermesFeatureIDs.ID.shellExec.rawValue,
            params: [
                "command": "remindctl today --json"
            ])
        guard Self.shellResultSucceeded(result) else {
            throw AdapterError.unavailable(
                (result["stderr"] as? String) ?? "remindctl could not access Apple Reminders.")
        }
        guard let output = result["stdout"] as? String else {
            throw AdapterError.malformedResponse
        }
        return Self.parse(output)
    }

    static func parse(_ output: String) -> [ReminderSummary] {
        guard let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        let rows: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rows = array
        } else if let dictionary = object as? [String: Any], let nested = dictionary["reminders"] as? [[String: Any]] {
            rows = nested
        } else {
            return []
        }
        return rows.compactMap { row in
            let id = (row["id"] as? String) ?? (row["identifier"] as? String)
            let title = (row["title"] as? String) ?? (row["name"] as? String)
            guard let id, let title, !title.isEmpty else { return nil }
            let dueValue = (row["dueDate"] as? String) ?? (row["due_date"] as? String)
            let dueDate = dueValue.flatMap { ISO8601DateFormatter().date(from: $0) }
            let overdue = (row["isOverdue"] as? Bool) ?? (row["overdue"] as? Bool) ?? false
            return ReminderSummary(
                id: id, title: title, list: row["list"] as? String, dueDate: dueDate, isOverdue: overdue)
        }
        .sorted { lhs, rhs in
            if lhs.isOverdue != rhs.isOverdue { return lhs.isOverdue }
            return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
        }
    }

    static func shellResultSucceeded(_ result: [String: Any]) -> Bool {
        if (result["success"] as? Bool) == false { return false }
        if let code = (result["code"] as? NSNumber)?.intValue { return code == 0 }
        if let exitCode = (result["exit_code"] as? NSNumber)?.intValue { return exitCode == 0 }
        return result["stdout"] != nil || result["output"] != nil
    }
}
