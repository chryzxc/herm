import Foundation

struct RichCode: Codable, Equatable, Sendable {
    let code: String
    var language: String?
    var filename: String?

    func validate() -> Bool {
        !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && code.utf8.count <= 65_536
            && (language?.count ?? 0) <= 64 && (filename?.count ?? 0) <= 512
    }
    var plainText: String { [filename, language, code].compactMap { $0 }.joined(separator: "\n") }
}

struct RichFindings: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable, Identifiable {
        enum Severity: String, Codable, Sendable { case info, warning, critical }
        let id: String
        let title: String
        let severity: Severity
        let detail: String
        var location: String?
        var recommendation: String?

        var plainText: String {
            ["\(severity.rawValue.capitalized): \(title)", location, detail, recommendation]
                .compactMap { $0 }.joined(separator: "\n")
        }
    }
    let items: [Item]

    func validate() -> Bool {
        !items.isEmpty && items.count <= 200 && RichIdentity.unique(items.map(\.id))
            && items.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty }
    }
}

struct RichWorkflow: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable, Identifiable {
        enum Status: String, Codable, Sendable { case proposed, running, passed, failed, blocked, skipped }
        let id: String
        let title: String
        let status: Status
        var detail: String?
        var evidence: String?

        var plainText: String {
            ["\(status.rawValue.capitalized): \(title)", detail, evidence].compactMap { $0 }.joined(separator: "\n")
        }
    }
    let items: [Item]

    func validate() -> Bool {
        !items.isEmpty && items.count <= 200 && RichIdentity.unique(items.map(\.id))
            && items.allSatisfy {
                !$0.title.isEmpty
                    && ($0.status == .proposed
                        || $0.evidence?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            }
    }
}
