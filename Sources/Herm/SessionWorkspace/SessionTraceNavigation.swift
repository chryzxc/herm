import Foundation

enum SessionTraceNavigation {
    static func nextFailure(in rows: [SessionTraceRow], after selectedID: String?) -> String? {
        let failures = rows.filter { $0.kind != .turn && $0.failed }
        guard !failures.isEmpty else { return nil }
        guard let index = failures.firstIndex(where: { $0.id == selectedID }) else { return failures[0].id }
        return failures[(index + 1) % failures.count].id
    }
}
