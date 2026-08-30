import Foundation

/// The bounded, UI-safe outcome of a read-only Hermes fixture projection.
enum WorktreeReadState: String, Codable, Equatable, Sendable {
    case ready
    case unavailable
    case unsupported
    case malformed
    case stale
}

enum WorktreeAvailability: String, Codable, Equatable, Sendable {
    case ready
    case unavailable
    case unsupported
    case malformed
    case stale
}

struct SessionExportSummary: Equatable, Sendable {
    let sessionID: String
    let format: String
    let recordCount: Int
}

struct SessionHistorySummary: Equatable, Sendable {
    let sessionID: String
    let eventCount: Int
    let latestAt: Date?
}

/// Worktree metadata deliberately contains no filesystem path or branch contents.
struct WorktreeSummary: Equatable, Sendable {
    let sessionID: String
    let worktreeID: String
    let state: WorktreeReadState
    let path: String? = nil
}

/// Immutable association prevents a context read for one session being reused by another.
struct SessionWorkspaceProjection: Equatable, Sendable {
    let sessionID: String
    let state: WorktreeReadState
    let export: SessionExportSummary?
    let history: SessionHistorySummary?
    let worktree: WorktreeSummary?
}

/// Read-only availability projection; no mutation or lifecycle operation is exposed.
struct SessionWorkspaceAvailability: Equatable, Sendable {
    let sessionID: String
    let export: WorktreeAvailability
    let history: WorktreeAvailability
    let worktree: WorktreeAvailability
}
