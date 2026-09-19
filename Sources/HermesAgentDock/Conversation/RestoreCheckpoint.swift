import Foundation

/// A checkpoint that can be restored for one selected conversation context.
/// Hermes owns the hash and timestamp; the Dock only retains bounded display
/// metadata and the identity needed to prevent cross-session restores.
struct RestoreCheckpoint: Identifiable, Equatable, Sendable {
    let sessionID: String
    let projectID: String?
    let selectionID: String?
    let hash: String
    let timestamp: String
    let message: String

    var id: String { "\(sessionID):\(hash)" }

    init?(sessionID: String, projectID: String? = nil, selectionID: String? = nil, hash: String, timestamp: String = "", message: String = "") {
        let sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = hash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty, !hash.isEmpty, hash.count <= 128 else { return nil }
        self.sessionID = sessionID
        self.projectID = Self.normalized(projectID)
        self.selectionID = Self.normalized(selectionID)
        self.hash = hash
        self.timestamp = String(timestamp.prefix(128))
        self.message = String(message.prefix(512))
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(256))
    }
}

enum RestoreCheckpointEligibility {
    /// Checkpoints are scoped to the exact selected session and optional
    /// project/selection. A missing optional scope in a checkpoint is treated
    /// as compatible for older Hermes payloads; a conflicting scope is not.
    static func isEligible(
        _ checkpoint: RestoreCheckpoint,
        sessionID: String,
        projectID: String? = nil,
        selectionID: String? = nil
    ) -> Bool {
        guard checkpoint.sessionID == sessionID.trimmingCharacters(in: .whitespacesAndNewlines),
              compatible(checkpoint.projectID, with: projectID),
              compatible(checkpoint.selectionID, with: selectionID) else { return false }
        return true
    }

    static func eligible(
        _ checkpoints: [RestoreCheckpoint],
        sessionID: String,
        projectID: String? = nil,
        selectionID: String? = nil
    ) -> [RestoreCheckpoint] {
        var seen = Set<String>()
        return checkpoints.filter { checkpoint in
            isEligible(checkpoint, sessionID: sessionID, projectID: projectID, selectionID: selectionID)
                && seen.insert(checkpoint.id).inserted
        }
    }

    private static func compatible(_ checkpointScope: String?, with requestedScope: String?) -> Bool {
        guard let requestedScope = requestedScope?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedScope.isEmpty else { return true }
        guard let checkpointScope else { return true }
        return checkpointScope == requestedScope
    }
}

enum RestoreCheckpointState: Equatable, Sendable {
    case idle
    case pending(RestoreCheckpoint)
    case failed(RestoreCheckpoint, message: String)
    case completed(RestoreCheckpoint)

    var checkpoint: RestoreCheckpoint? {
        switch self {
        case .idle: nil
        case .pending(let checkpoint), .failed(let checkpoint, _), .completed(let checkpoint): checkpoint
        }
    }

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

/// Main-actor state machine for the confirmation/pending/failure surface.
/// It is deliberately independent of SwiftUI so cancellation and duplicate
/// prevention are testable without rendering a view or calling Hermes.
@MainActor
final class RestoreCheckpointCoordinator {
    private(set) var state: RestoreCheckpointState = .idle

    @discardableResult
    func begin(_ checkpoint: RestoreCheckpoint) -> Bool {
        guard !state.isPending else { return false }
        if case .completed(let completed) = state, completed.id == checkpoint.id { return false }
        state = .pending(checkpoint)
        return true
    }

    func cancel() {
        guard state.isPending || isFailed else { return }
        state = .idle
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    func succeed() {
        guard case .pending(let checkpoint) = state else { return }
        state = .completed(checkpoint)
    }

    func fail(_ message: String) {
        guard case .pending(let checkpoint) = state else { return }
        state = .failed(checkpoint, message: String(message.prefix(512)))
    }

    func reset() {
        state = .idle
    }
}
