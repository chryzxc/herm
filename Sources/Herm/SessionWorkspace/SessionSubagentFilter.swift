import Foundation

enum SessionSubagentFilter: String, CaseIterable {
    case all = "All"
    case running = "Running"
    case failed = "Failed"

    static func rows(_ rows: [SessionTraceRow], matching filter: Self) -> [SessionTraceRow] {
        rows.filter { row in
            row.kind == .agent && row.crewProfileID == nil
                && (filter == .all || (filter == .running && row.active) || (filter == .failed && row.failed))
        }
    }
}
