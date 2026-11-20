import Foundation

/// Shared default-option ISO 8601 formatter for wire timestamps. Building an
/// `ISO8601DateFormatter` loads ICU state and costs several times the parse,
/// and parsers call this once per row while refreshing lists on the main
/// actor. `ISO8601DateFormatter` is documented as thread-safe, so one
/// instance serves every caller. `make perf-contract` rejects new inline
/// `ISO8601DateFormatter()` allocations outside a stored property.
enum ISO8601Parsing {
    private nonisolated(unsafe) static let formatter = ISO8601DateFormatter()
    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated static func date(_ string: String) -> Date? {
        formatter.date(from: string)
    }

    /// Timestamps with fractional seconds (`2026-11-20T02:10:27.123Z`).
    nonisolated static func fractionalDate(_ string: String) -> Date? {
        fractionalFormatter.date(from: string)
    }

    nonisolated static func string(_ date: Date) -> String {
        formatter.string(from: date)
    }
}
