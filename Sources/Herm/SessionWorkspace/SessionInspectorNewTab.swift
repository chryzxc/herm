import Foundation

extension SessionInspector {
    enum Section: String, CaseIterable, Identifiable {
        case timeline = "Timeline"
        case terminal = "Terminal"
        case files = "Files"
        case artifacts = "Artifacts"
        case changes = "Source Control"
        case browser = "Browser"
        case iosSimulator = "iOS Simulator"
        case androidEmulator = "Android Emulator"
        case talk = "Talk"
        case pullRequests = "Pull Requests"
        case issues = "Issues"
        case diff = "Diff"
        case github = "GitHub"

        /// Opened on demand from the tab picker or a tab request.
        var isOnDemand: Bool { self == .iosSimulator || self == .androidEmulator || isWorkspace }
        /// Session surfaces the host renders (Talk, PRs, Issues).
        var isWorkspace: Bool { self == .talk || self == .pullRequests || self == .issues }

        static func open(
            visible: [Self], closed: String, browserOpen: Bool, simulators: [String]
        ) -> [Self] {
            let closed = Set(closed.split(separator: "|").map(String.init))
            return visible.filter {
                if $0.isOnDemand { return simulators.contains($0.rawValue) }
                return $0 == .browser ? browserOpen : !closed.contains($0.rawValue)
            }
        }

        /// A tab Hermes asked to show: the `herm_inspector` receipt's tab, or a `pane.reveal` pane.
        init?(agentTab: String) {
            switch agentTab {
            case "timeline": self = .timeline
            case "artifacts": self = .artifacts
            case "files": self = .files
            case "changes", "review": self = .changes
            case "diff": self = .diff
            case "terminal": self = .terminal
            case "browser": self = .browser
            case "github": self = .github
            default: return nil
            }
        }

        static func receipt(_ result: String) -> Self? {
            struct Receipt: Decodable {
                let schema: String
                let tab: String
            }
            guard result.utf8.count < 4_096,
                let value = try? JSONDecoder().decode(Receipt.self, from: Data(result.utf8)),
                value.schema == "herm.inspector.v1"
            else { return nil }
            return Self(agentTab: value.tab)
        }

        var id: Self { self }
        var navigationTitle: String {
            switch self {
            case .files: "Explorer"
            case .pullRequests: "Pull requests"
            default: rawValue
            }
        }
        var icon: Ph {
            switch self {
            case .timeline: .chartBarHorizontal
            case .artifacts: .files
            case .files: .folder
            case .changes: .gitBranch
            case .diff: .gitDiff
            case .terminal: .terminal
            case .browser: .globe
            case .github: .gitPullRequest
            case .iosSimulator, .androidEmulator: .deviceMobile
            case .talk: .waveform
            case .pullRequests: .gitPullRequest
            case .issues: .circleDashed
            }
        }
    }
}

/// Shared entries for the inspector's plus menu and empty grid. Panel-only
/// actions stay separate from persisted inspector sections.
enum SessionInspectorNewTab: Hashable, Identifiable {
    typealias Section = SessionInspector.Section

    case reopenClosed
    case conversation
    case section(Section)

    var id: Self { self }

    var title: String {
        switch self {
        case .reopenClosed: "Reopen closed tab"
        case .conversation: "Conversation"
        case .section(let section): section.navigationTitle
        }
    }

    var icon: Ph {
        switch self {
        case .reopenClosed: .arrowCounterClockwise
        case .conversation: .columnsPlusRight
        case .section(let section): section.icon
        }
    }

    var cardDetail: String? { Self.cards.first { $0.entry == self }?.detail }

    /// The grid lists the most-used choices first.
    private static let cards: [(entry: Self, detail: String)] = [
        (.section(.talk), "Talk with this session by voice"),
        (.conversation, "Open a session, Bot chat or group chat in split view"),
        (.section(.terminal), "Run commands in your workspace"),
        (.section(.browser), "Open a page or search the web"),
        (.section(.files), "Browse project files"),
        (.section(.changes), "Review repository changes"),
        (.section(.pullRequests), "Browse this repository’s pull requests"),
        (.section(.issues), "Browse this repository’s issues"),
        (.section(.diff), "Review the attached diff"),
        (.section(.github), "Follow the linked pull request or issue"),
        (.section(.artifacts), "Explore this session’s outputs"),
        (.section(.timeline), "Inspect session activity"),
        (.section(.iosSimulator), "Run the app in an iOS Simulator"),
        (.section(.androidEmulator), "Run the app in an Android Emulator"),
    ]

    var opensAdditionalInstance: Bool { self == .section(.terminal) || self == .section(.browser) }

    static func menu(visible: [Section], open: [Section], canReopen: Bool) -> [Self] {
        let entries = visible.map(Self.section)
        let open = Set(open.map(Self.section))
        let anchor: [Self] = canReopen ? [.reopenClosed, .conversation] : [.conversation]
        return anchor + entries.filter(\.opensAdditionalInstance)
            + entries.filter { !$0.opensAdditionalInstance && !open.contains($0) }
    }

    static func grid(visible: [Section], open: [Section]) -> [Self] {
        let open = Set(open)
        let closed = Set(visible.filter { !open.contains($0) }.map(Self.section))
        return cards.map(\.entry).filter { $0 == .conversation || closed.contains($0) }
    }
}
