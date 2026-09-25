import Foundation

/// What kind of work a running bot is doing, and therefore which room it uses.
/// Kanban lanes still decide *whether* a bot works; this only picks the room.
enum OfficeWorkKind: String, CaseIterable, Sendable {
    case coding, research, testing, security, infrastructure, design, build, writing, orchestration

    var title: String {
        switch self {
        case .coding: "Coding"
        case .research: "Research"
        case .testing: "Testing"
        case .security: "Security check"
        case .infrastructure: "Infrastructure"
        case .design: "Design"
        case .build: "Build"
        case .writing: "Writing"
        case .orchestration: "Coordinating"
        }
    }

    var location: OfficePreviewLocation {
        switch self {
        case .coding: .desk
        case .research, .writing: .library
        case .testing: .qaLab
        case .security: .securityOps
        case .infrastructure: .serverRoom
        case .design: .designStudio
        case .build: .assemblyBay
        case .orchestration: .missionWall
        }
    }

    var symbol: String {
        switch self {
        case .coding: "desktopcomputer"
        case .research: "books.vertical.fill"
        case .testing: "testtube.2"
        case .security: "lock.shield.fill"
        case .infrastructure: "server.rack"
        case .design: "paintbrush.fill"
        case .build: "hammer.fill"
        case .writing: "pencil.and.list.clipboard"
        case .orchestration: "point.3.connected.trianglepath.dotted"
        }
    }

    /// Existing desk poses reused while the bot works in the room.
    var phase: OfficePreviewPhase {
        switch self {
        case .testing: .testing
        case .research, .writing: .reading
        default: .implementing
        }
    }

    /// Whole-word vocabulary. Earlier kinds win when one signal names several,
    /// so "write tests" is testing and "write migration plan" is infrastructure.
    fileprivate static let vocabulary: [(OfficeWorkKind, Set<String>)] = [
        (.security, ["security", "pentest", "pentesting", "penetration", "audit", "vuln", "vulns", "vulnerability",
                     "vulnerabilities", "cve", "threat", "exploit", "secrets", "owasp", "hardening", "sast", "dast"]),
        (.testing, ["test", "tests", "testing", "qa", "verify", "verification", "validate", "validation", "e2e",
                    "regression", "smoke", "unittest", "pytest", "xctest"]),
        (.infrastructure, ["deploy", "deployment", "deploying", "infra", "infrastructure", "docker", "kubernetes", "k8s",
                           "ci", "migrate", "migration", "migrations", "database", "db", "monitoring", "devops",
                           "terraform", "helm", "server", "servers", "provision", "rollout"]),
        (.research, ["research", "researching", "investigate", "investigation", "explore", "exploration", "browse",
                     "browser", "web", "search", "read", "reading", "inspect", "inspecting", "analyze", "analyse", "analysis", "study",
                     "survey", "summarize", "summarise", "compare", "benchmark"]),
        (.design, ["design", "ui", "ux", "mockup", "mockups", "figma", "icon", "icons", "image", "images",
                   "illustration", "logo", "wireframe", "wireframes", "prototype", "vision", "branding"]),
        (.build, ["build", "builds", "package", "packaging", "release", "bundle", "compile", "notarize", "archive"]),
        (.writing, ["docs", "documentation", "document", "readme", "changelog", "write", "writeup", "copy",
                    "copywriting", "blog", "article", "draft", "notes", "announcement"]),
        (.orchestration, ["plan", "planning", "delegate", "delegation", "coordinate", "orchestrate", "breakdown",
                          "decompose", "roadmap"]),
        (.coding, ["implement", "implementation", "code", "coding", "refactor", "fix", "bugfix", "patch", "develop",
                   "feature", "edit", "terminal"])
    ]

    static func matching(_ text: String) -> OfficeWorkKind? {
        let words = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard !words.isEmpty else { return nil }
        return vocabulary.first { !$0.1.isDisjoint(with: words) }?.0
    }

    /// Hermes tool names, checked before the general vocabulary.
    static func matching(tool name: String) -> OfficeWorkKind? {
        let tool = name.lowercased().replacingOccurrences(of: "-", with: "_")
            .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        switch tool {
        case "web_search", "web_extract", "web_fetch", "web_crawl", "session_search": return .research
        case _ where tool.hasPrefix("browser_"): return .research
        case "terminal", "shell", "exec", "exec_command", "patch", "apply_patch", "edit_file", "write_file",
             "read_file", "search_files", "execute_code", "process": return .coding
        case "delegate_task", "todo", "mixture_of_agents": return .orchestration
        case "vision_analyze", "image_generate", "view_image": return .design
        default: return matching(name)
        }
    }
}

/// The room choice plus the real signal behind it, shown in the inspector.
struct OfficeWorkClassification: Equatable, Sendable {
    enum Source: Int, Sendable {
        case step, skill, workflow, event, tool, title, fallback

        /// Explicit signals move a bot at once; noisier ones must settle first.
        var isExplicit: Bool { self == .step || self == .skill || self == .workflow }
    }

    let kind: OfficeWorkKind
    let source: Source
    let signal: String?

    static let fallback = OfficeWorkClassification(kind: .coding, source: .fallback, signal: nil)

    var evidence: String {
        switch source {
        case .step: "from step \(signal ?? "")"
        case .skill: "from skill \(signal ?? "")"
        case .workflow: "from workflow \(signal ?? "")"
        case .event: "from latest event"
        case .tool: "from tool \(signal ?? "")"
        case .title: "Inferred from title"
        case .fallback: "Default"
        }
    }
}

enum OfficeWorkClassifier {
    /// Strongest signal first; the first one that names a kind wins.
    static func classify(_ task: OfficePreviewTaskData) -> OfficeWorkClassification {
        if let step = nonEmpty(task.currentStepKey), let kind = OfficeWorkKind.matching(step) {
            return .init(kind: kind, source: .step, signal: step)
        }
        for skill in task.skills {
            if let kind = OfficeWorkKind.matching(skill) { return .init(kind: kind, source: .skill, signal: skill) }
        }
        if let workflow = nonEmpty(task.workflowTemplateID), let kind = OfficeWorkKind.matching(workflow) {
            return .init(kind: kind, source: .workflow, signal: workflow)
        }
        for event in [task.latestEventNote, task.latestEventKind].compactMap(nonEmpty) {
            if let kind = OfficeWorkKind.matching(event) { return .init(kind: kind, source: .event, signal: event) }
        }
        if let kind = OfficeWorkKind.matching(task.title) { return .init(kind: kind, source: .title, signal: task.title) }
        return .fallback
    }

    /// Main sessions have no Kanban step; their newest recognizable tool decides.
    static func classify(_ session: OfficeMainSession) -> OfficeWorkClassification {
        for activity in session.activities.sorted(by: { $0.timestamp > $1.timestamp }) {
            if let kind = OfficeWorkKind.matching(tool: activity.name) {
                return .init(kind: kind, source: .tool, signal: activity.name)
            }
        }
        return .fallback
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// Noisy signals (events, titles) can change on every heartbeat. A room change
/// from them waits until the same kind has held for `settle` seconds, unless
/// an explicit signal or a lane change moved the bot.
struct OfficeWorkStabilizer {
    static let settle: TimeInterval = 20

    private struct Entry {
        var settled: OfficeWorkClassification
        var lane: OfficePreviewLane
        var candidate: OfficeWorkClassification?
        var candidateSince: Date?
    }
    private var entries: [String: Entry] = [:]

    mutating func stabilize(key: String, lane: OfficePreviewLane, proposed: OfficeWorkClassification, now: Date) -> OfficeWorkClassification {
        guard var entry = entries[key], entry.lane == lane, !proposed.source.isExplicit, entry.settled.kind != proposed.kind else {
            entries[key] = Entry(settled: proposed, lane: lane)
            return proposed
        }
        if entry.candidate?.kind != proposed.kind { entry.candidateSince = now }
        entry.candidate = proposed
        if now.timeIntervalSince(entry.candidateSince ?? now) >= Self.settle {
            entry = Entry(settled: proposed, lane: lane)
        }
        entries[key] = entry
        return entry.settled
    }

    mutating func retain(keys: Set<String>) {
        entries = entries.filter { keys.contains($0.key) }
    }
}
