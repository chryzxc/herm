import Foundation

/// Recovery and distribution capabilities exposed by a structured Hermes status
/// response. These identifiers are display/action keys, never CLI guesses.
enum RecoveryFeature: String, CaseIterable, Identifiable, Sendable {
    case backup
    case `import`
    case importAgent = "import_agent"
    case migration
    case sync
    case openClawMigration = "openclaw_migration"
    case update

    var id: String { rawValue }
    var title: String {
        switch self {
        case .backup: "Backup"
        case .import: "Import"
        case .importAgent: "Import agent"
        case .migration: "Migration"
        case .sync: "Sync"
        case .openClawMigration: "OpenClaw migration"
        case .update: "Update"
        }
    }
    var isConsequential: Bool { self != .update }
}

enum RecoveryFeatureState: String, Equatable, Sendable {
    case ready
    case requiresConfirmation
    case unavailable
    case unsupported
}

struct RecoveryFeatureStatus: Identifiable, Equatable, Sendable {
    let id: RecoveryFeature
    let state: RecoveryFeatureState
    let detail: String

    var isActionable: Bool { false }
}

struct RecoverySnapshot: Equatable, Sendable {
    let items: [RecoveryFeatureStatus]

    func item(_ feature: RecoveryFeature) -> RecoveryFeatureStatus? {
        items.first { $0.id == feature }
    }
}

enum RecoveryMutationResult: Equatable, Sendable {
    case confirmationRequired
    case unavailable
}
