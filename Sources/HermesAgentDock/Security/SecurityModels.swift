import Foundation

public enum SecurityProjectionState: String, Codable, CaseIterable, Equatable, Sendable { case ready, unavailable, unsupported, malformed, stale }
public enum SecurityOutputFormat: Sendable { case json, human, humanTable }
public typealias SecurityControlPlaneSnapshot = SecuritySnapshot

public struct SecurityApprovals: Codable, Equatable, Sendable { public let state: String; public let pending: Int; public init(state: String, pending: Int) { self.state = state; self.pending = pending } }
public struct SecuritySafeMode: Codable, Equatable, Sendable { public let state: String; public let reason: String; public init(state: String, reason: String) { self.state = state; self.reason = reason } }
public struct SecurityCheckpoints: Codable, Equatable, Sendable { public let state: String; public let count: Int; public init(state: String, count: Int) { self.state = state; self.count = count } }
public struct SecuritySecretSource: Codable, Equatable, Sendable { public let id: String; public let kind: String; public let present: Bool; public init(id: String, kind: String, present: Bool) { self.id = id; self.kind = kind; self.present = present } }
public struct SecuritySecretSources: Codable, Equatable, Sendable { public let state: String; public let sources: [SecuritySecretSource]; public init(state: String, sources: [SecuritySecretSource]) { self.state = state; self.sources = sources } }
public struct SecurityEgress: Codable, Equatable, Sendable { public let state: String; public let network: String; public let allowlistedHosts: Int; public init(state: String, network: String, allowlistedHosts: Int) { self.state = state; self.network = network; self.allowlistedHosts = allowlistedHosts } }
public struct SecurityDoctor: Codable, Equatable, Sendable { public let state: String; public let checks: Int; public let failures: Int; public init(state: String, checks: Int, failures: Int) { self.state = state; self.checks = checks; self.failures = failures } }
public struct SecurityStatus: Codable, Equatable, Sendable { public let state: String; public let score: String; public init(state: String, score: String) { self.state = state; self.score = score } }
public struct SecurityLogStatus: Codable, Equatable, Sendable { public let state: String; public let events: Int; public init(state: String, events: Int) { self.state = state; self.events = events } }

public struct SecuritySnapshot: Codable, Equatable, Sendable {
    public let state: SecurityProjectionState
    public let approvals: SecurityApprovals
    public let safeMode: SecuritySafeMode
    public let checkpoints: SecurityCheckpoints
    public let secretSources: SecuritySecretSources
    public let egress: SecurityEgress
    public let doctor: SecurityDoctor
    public let security: SecurityStatus
    public let logs: SecurityLogStatus
    public init(state: SecurityProjectionState = .unavailable, approvals: SecurityApprovals = .init(state: "unavailable", pending: 0), safeMode: SecuritySafeMode = .init(state: "unavailable", reason: "Unavailable"), checkpoints: SecurityCheckpoints = .init(state: "unavailable", count: 0), secretSources: SecuritySecretSources = .init(state: "unavailable", sources: []), egress: SecurityEgress = .init(state: "unavailable", network: "Unavailable", allowlistedHosts: 0), doctor: SecurityDoctor = .init(state: "unavailable", checks: 0, failures: 0), security: SecurityStatus = .init(state: "unavailable", score: "Unavailable"), logs: SecurityLogStatus = .init(state: "unavailable", events: 0)) { self.state = state; self.approvals = approvals; self.safeMode = safeMode; self.checkpoints = checkpoints; self.secretSources = secretSources; self.egress = egress; self.doctor = doctor; self.security = security; self.logs = logs }
}

public enum SecurityAction: CaseIterable, Hashable, Equatable, Sendable { case refresh, copyRecoveryInstructions, deleteCheckpoint, disableSafeMode, rotateSecret, clearLogs }
public enum SecurityActionResult: Equatable, Sendable { case performed, confirmationRequired, unavailable }
