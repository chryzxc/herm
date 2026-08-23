import Foundation

/// Shared numeric/date coercions for provider quota JSON payloads. Provider
/// APIs disagree on whether quantities and timestamps arrive as numbers,
/// numeric strings, epoch seconds, epoch milliseconds, or ISO 8601 text.
enum QuotaJSON {
    static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? String { return Double(value) }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        if let number = number(value) {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
        }
        guard let value = value as? String else { return nil }
        return iso8601Date(value)
    }

    static func iso8601Date(_ value: String) -> Date? {
        if let date = standardFormatter.date(from: value) { return date }
        return fractionalFormatter.date(from: value)
    }

    static func iso8601String(from date: Date) -> String {
        standardFormatter.string(from: date)
    }

    // ISO8601DateFormatter is thread-safe, but not Sendable-annotated.
    private nonisolated(unsafe) static let standardFormatter = ISO8601DateFormatter()
    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
