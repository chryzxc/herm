import Foundation

enum VerificationRecipeKind: String, Equatable {
    case test
    case build
    case lint
    case custom
}

struct VerificationRecipe: Identifiable, Equatable {
    let id: String
    let title: String
    let command: String
    let kind: VerificationRecipeKind
    let workingDirectory: String
    let source: String
}

struct VerificationRun: Identifiable, Equatable {
    let id: UUID
    let recipeID: String
    let repositoryID: String
    let repositoryFingerprint: String
    let command: String
    let startedAt: Date
    let finishedAt: Date?
    let exitCode: Int?
    let outputSummary: String?

    var isComplete: Bool { finishedAt != nil }

    var duration: TimeInterval? {
        let end = finishedAt ?? .now
        return max(0, end.timeIntervalSince(startedAt))
    }

    var durationLabel: String? {
        guard let duration else { return nil }
        if duration < 1 { return "<1s" }
        return String(format: "%.1fs", duration)
    }

    func isCurrent(repositoryFingerprint: String, repositoryID: String) -> Bool {
        self.repositoryFingerprint == repositoryFingerprint && self.repositoryID == repositoryID
    }
}

enum VerificationRecipeBuilder {
    /// Hermes supplies project facts; the Dock exposes only commands whose
    /// leading executable/action is known to be a verification operation.
    static func make(facts: ProjectFactsSummary?, repository: RepositorySnapshot) -> [VerificationRecipe] {
        guard repository.isGitRepository || !repository.path.isEmpty else { return [] }
        let root = facts?.root.flatMap(Self.normalizedPath) ?? repository.path
        let commands = facts?.verifyCommands ?? []
        var seen = Set<String>()
        return commands.compactMap { raw in
            guard let command = normalizedCommand(raw), seen.insert(command).inserted else { return nil }
            let kind = kind(for: command)
            return VerificationRecipe(
                id: "\(kind.rawValue):\(command)",
                title: title(for: kind, command: command),
                command: command,
                kind: kind,
                workingDirectory: root,
                source: "Hermes project facts"
            )
        }
    }

    static func normalizedCommand(_ raw: String) -> String? {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, command.count <= 240,
            command.rangeOfCharacter(from: .controlCharacters) == nil,
            !command.contains("\n"), !command.contains("\r"),
            command.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|<>$`")) == nil
        else { return nil }
        let prefixes = [
            "swift test", "swift build", "npm test", "npm run", "pnpm test", "pnpm run",
            "yarn test", "yarn run", "cargo test", "go test", "pytest", "python -m pytest",
            "make test", "xcodebuild test", "xcodebuild build",
        ]
        guard prefixes.contains(where: { command == $0 || command.hasPrefix($0 + " ") }) else { return nil }
        if command.hasPrefix("npm run ") || command.hasPrefix("pnpm run ") || command.hasPrefix("yarn run ") {
            let script = command.split(whereSeparator: { $0.isWhitespace }).dropFirst(2).first.map(String.init)
            guard ["test", "lint", "format", "build", "check", "typecheck"].contains(script) else { return nil }
        }
        if command.hasPrefix("make ") { guard command == "make test" else { return nil } }
        return command
    }

    private static func normalizedPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private static func kind(for command: String) -> VerificationRecipeKind {
        if command.contains("test") { return .test }
        if command.contains("lint") || command.contains("format") { return .lint }
        if command.contains("build") { return .build }
        return .custom
    }

    private static func title(for kind: VerificationRecipeKind, command: String) -> String {
        switch kind {
        case .test: "Run tests"
        case .build: "Build project"
        case .lint: "Check formatting/lint"
        case .custom: "Run verification"
        }
    }
}
