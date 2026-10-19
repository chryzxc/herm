import Foundation
import SwiftUI

/// A mutation intent is inert until the detail surface explicitly confirms it.
/// No GitHub write should be reachable from a row/menu action directly.
enum PullRequestMutationRequest: Identifiable, Equatable {
    case comment(record: PullRequestRecord, body: String)
    case status(record: PullRequestRecord, status: PullRequestStatus)

    var id: String {
        switch self {
        case let .comment(record, body): return "comment:\(record.id):\(body)"
        case let .status(record, status): return "status:\(record.id):\(status.rawValue)"
        }
    }
}

@MainActor
final class PullRequestMutationCoordinator: ObservableObject {
    @Published private(set) var pending: PullRequestMutationRequest?

    func requestComment(_ body: String, for record: PullRequestRecord) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pending = .comment(record: record, body: trimmed)
    }

    func requestStatus(_ status: PullRequestStatus, for record: PullRequestRecord) {
        pending = .status(record: record, status: status)
    }

    func cancel() {
        pending = nil
    }

    func confirm(using center: PullRequestCenterModel) async -> Bool {
        guard let pending else { return false }
        return await confirm(pending, using: center)
    }

    func confirm(_ request: PullRequestMutationRequest, using center: PullRequestCenterModel) async -> Bool {
        pending = nil
        switch request {
        case let .comment(record, body):
            return await center.addComment(body, to: record)
        case let .status(record, status):
            return await center.updateStatus(status, for: record)
        }
    }
}

