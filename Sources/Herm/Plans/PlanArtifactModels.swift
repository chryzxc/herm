import Foundation

/// The truthful state of a plan artifact read. The Dock never substitutes
/// generated content for a missing, invalid, or unreadable plan.
enum PlanArtifactDataState: Equatable {
    case available
    case unavailable(String)
}

struct PlanArtifactSummary: Identifiable, Equatable {
    let relativePath: String
    let title: String
    let modifiedAt: Date?
    let byteCount: Int
    let sha256: String?
    let state: PlanArtifactDataState

    var id: String { relativePath }
}

struct PlanArtifactDocument: Equatable {
    let summary: PlanArtifactSummary
    let contents: String

    var relativePath: String { summary.relativePath }
    var sha256: String? { summary.sha256 }
}

struct PlanReviewComment: Identifiable, Equatable {
    let id: UUID
    let planPath: String
    let planSHA256: String
    let anchor: String?
    let body: String
    let createdAt: Date

    var isStale: Bool { false }

    func isStale(comparedWith sha256: String?) -> Bool {
        guard let sha256 else { return true }
        return sha256 != planSHA256
    }
}

struct PlanRevisionDraft: Equatable {
    let relativePath: String
    let parentPlan: String
    let parentSHA256: String
    let contents: String
}

enum PlanArtifactError: LocalizedError, Equatable {
    case invalidPath
    case outsidePlansDirectory
    case missingPlansDirectory
    case missingArtifact
    case unsupportedFile
    case fileTooLarge
    case invalidUTF8
    case invalidComment
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath: "The artifact path is invalid."
        case .outsidePlansDirectory: "The artifact path is outside the plans directory."
        case .missingPlansDirectory: "The project has no .hermes/plans directory."
        case .missingArtifact: "The plan artifact no longer exists."
        case .unsupportedFile: "Only UTF-8 Markdown plan files are supported."
        case .fileTooLarge: "The plan artifact exceeds the display size limit."
        case .invalidUTF8: "The plan artifact is not valid UTF-8."
        case .invalidComment: "The comment is empty or contains unsupported control characters."
        case .writeFailed(let reason): "The artifact could not be saved: \(reason)"
        }
    }
}
