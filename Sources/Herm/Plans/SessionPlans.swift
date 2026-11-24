import Darwin
import Foundation

/// A plan this session owns: a Hermes `/plan` file it named, or a Markdown file someone
/// linked to it. Herm only reads the file. Agents rarely tick a plan's checkboxes, so
/// progress falls back to the session's task list where its items name plan steps.
struct SessionPlan: Equatable, Identifiable, Sendable {
    enum Progress: Equatable, Sendable {
        /// The file's own checkboxes.
        case file
        /// The session's Hermes task list, matched to steps by title.
        case taskList
    }

    let path: String
    let title: String
    let modifiedAt: Date?
    /// Nil until the file or the task list marks progress.
    let done: Int?
    let total: Int?
    let blocked: Int
    let nextUp: String?
    var source: Progress? = nil
    var isLinked = false
    /// A linked file that is gone or unreadable; its numbers are never kept.
    var isMissing = false

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
}

enum SessionPlans {
    /// Plans whose file name the session's chat mentions, newest first. A plan in the
    /// folder that this session never named belongs to another session and is left out.
    static func mentioned(_ plans: [PlanArtifactSummary], in texts: [String]) -> [PlanArtifactSummary] {
        let normalized = texts.map { $0.precomposedStringWithCanonicalMapping as NSString }
        return plans.filter { mentions(($0.relativePath as NSString).lastPathComponent, in: normalized) }
    }

    private static func mentions(_ filename: String, in normalized: [NSString]) -> Bool {
        let name = filename.precomposedStringWithCanonicalMapping
        return normalized.contains {
            !Task.isCancelled && $0.range(of: name, options: .literal).location != NSNotFound
        }
    }

    static func plan(
        path: String, title: String, modifiedAt: Date?, text: String, tasks: [TodoPlan.Item] = []
    ) -> SessionPlan {
        plan(
            path: path, title: title, modifiedAt: modifiedAt, map: SpecMapParser.parse(text, fallbackTitle: title),
            tasks: tasks)
    }

    private static func plan(
        path: String, title: String, modifiedAt: Date?, map: SpecMap, tasks: [TodoPlan.Item]
    ) -> SessionPlan {
        let title = map.title.isEmpty ? title : map.title
        if let progress = map.progress {
            return SessionPlan(
                path: path, title: title, modifiedAt: modifiedAt, done: progress.done, total: progress.total,
                blocked: progress.blocked, nextUp: map.nextUp?.title, source: .file)
        }
        if let progress = map.taskListProgress(tasks.map { ($0.content, $0.status) }) {
            return SessionPlan(
                path: path, title: title, modifiedAt: modifiedAt, done: progress.done, total: progress.total,
                blocked: 0, nextUp: progress.current, source: .taskList)
        }
        return SessionPlan(
            path: path, title: title, modifiedAt: modifiedAt, done: nil, total: nil, blocked: 0, nextUp: nil)
    }

    /// Reads the workspace's plans folder and the linked files; run off the main actor.
    static func load(
        workspace: String?, texts: [String], linked: [String], tasks: [TodoPlan.Item]
    ) -> [SessionPlan] {
        var loader = Loader()
        return loader.load(workspace: workspace, newTexts: texts, linked: linked, tasks: tasks)
    }

    /// One disposable cache per visible rail, carried across its file polls.
    struct Loader: Sendable {
        private struct Source: Hashable, Sendable {
            let path: String
            let isLinked: Bool
        }

        private var texts: [String] = []
        private var mentions: [String: Bool] = [:]
        private var maps: [Source: (FileRevision, SpecMap)] = [:]

        mutating func load(
            workspace: String?, newTexts: [String]?, linked: [String], tasks: [TodoPlan.Item]
        ) -> [SessionPlan] {
            if let newTexts {
                texts = newTexts.map(\.precomposedStringWithCanonicalMapping)
                mentions.removeAll()
            }
            var plans: [SessionPlan] = []
            if let workspace {
                let service = PlanArtifactService(projectRoot: URL(fileURLWithPath: workspace))
                let files = service.planFileCandidates()
                let names = Set(files.map(\.lastPathComponent))
                let unchecked = names.subtracting(mentions.keys)
                if !unchecked.isEmpty {
                    let normalized = texts.map { $0 as NSString }
                    for name in unchecked {
                        guard !Task.isCancelled else { return [] }
                        mentions[name] = SessionPlans.mentions(name, in: normalized)
                    }
                }
                mentions = mentions.filter { names.contains($0.key) }
                for file in files where mentions[file.lastPathComponent] == true {
                    guard !Task.isCancelled else { return [] }
                    guard let validated = try? service.sourceURL(relativePath: service.relativePath(for: file))
                    else { continue }
                    let source = Source(path: file.path, isLinked: false)
                    guard
                        let entry = read(
                            source, maxBytes: service.maxArtifactBytes,
                            contents: {
                                try service.railText(at: validated)
                            })
                    else { continue }
                    plans.append(
                        plan(
                            path: file.path, title: entry.1.title, modifiedAt: entry.0.modifiedAt,
                            map: entry.1, tasks: tasks))
                }
                plans.sort {
                    if $0.modifiedAt != $1.modifiedAt {
                        return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
                    }
                    return $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }
            }
            var paths = Set(plans.map(\.path))
            for path in linked where paths.insert(path).inserted {
                guard !Task.isCancelled else { return [] }
                let file = URL(fileURLWithPath: path)
                let title = file.deletingPathExtension().lastPathComponent
                if let (revision, map) = read(
                    Source(path: path, isLinked: true), maxBytes: 1_000_000,
                    contents: {
                        (try String(contentsOf: file, encoding: .utf8), title)
                    })
                {
                    var value = plan(path: path, title: title, modifiedAt: revision.modifiedAt, map: map, tasks: tasks)
                    value.isLinked = true
                    plans.append(value)
                } else {
                    plans.append(
                        SessionPlan(
                            path: path, title: title, modifiedAt: nil, done: nil, total: nil, blocked: 0,
                            nextUp: nil, isLinked: true, isMissing: true))
                }
            }
            let visibleSources = Set(plans.map { Source(path: $0.path, isLinked: $0.isLinked) })
            maps = maps.filter { visibleSources.contains($0.key) }
            return plans
        }

        private mutating func read(
            _ source: Source, maxBytes: Int, contents: () throws -> (text: String, title: String)
        ) -> (FileRevision, SpecMap)? {
            let file = URL(fileURLWithPath: source.path)
            guard let revision = FileRevision(file), revision.bytes <= maxBytes,
                FileManager.default.isReadableFile(atPath: file.path)
            else {
                maps[source] = nil
                return nil
            }
            if let cached = maps[source], cached.0 == revision { return cached }
            guard let value = try? contents() else {
                maps[source] = nil
                return nil
            }
            let entry = (revision, SpecMapParser.parse(value.text, fallbackTitle: value.title))
            maps[source] = entry
            return entry
        }
    }

    private struct FileRevision: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let bytes: Int64
        let modifiedAt: Date
        let changeSeconds: Int
        let changeNanoseconds: Int

        init?(_ file: URL) {
            var info = stat()
            guard
                file.withUnsafeFileSystemRepresentation({ path in
                    guard let path else { return false }
                    return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                })
            else { return nil }
            device = info.st_dev
            inode = info.st_ino
            bytes = info.st_size
            modifiedAt = Date(
                timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                    + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            changeSeconds = info.st_ctimespec.tv_sec
            changeNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    /// Asks Hermes to name its task list after the plan's steps, which agents keep up to
    /// date anyway; the plan file is left alone. The chip is never sent automatically.
    static func trackProgressContext(path: String, title: String) -> ChatContext {
        ChatContext(
            id: "plan-track:\(path)", title: "Track progress · \(title)",
            body: """
                Follow the plan at \(path). Keep your task list with one task per step of the \
                plan, named exactly as the step is in the plan, and update each task as you work. \
                You don't need to edit the plan file.
                """)
    }
}

/// Markdown files linked to a session's rail as plans, a local preference keyed by session.
enum LinkedPlans {
    private static let key = "herm.linkedPlans.v1"

    static func paths(sessionID: String) -> [String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]])?[sessionID] ?? []
    }

    static func set(_ path: String, linked: Bool, sessionID: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        var paths = all[sessionID] ?? []
        paths.removeAll { $0 == path }
        if linked { paths.append(path) }
        all[sessionID] = paths.isEmpty ? nil : paths
        UserDefaults.standard.set(all, forKey: key)
    }
}

extension DockModel {
    /// The session's latest task list, even from an earlier turn: a step it closed then
    /// still counts as done in the plan.
    var planTasks: [TodoPlan.Item] {
        guard let plan = todoPlan, currentSessionIDs.contains(plan.sessionID) else { return [] }
        return plan.items
    }
}

extension DockModel {
    func isPlanLinked(_ path: String) -> Bool {
        navigationSessionID.map { LinkedPlans.paths(sessionID: $0).contains(path) } ?? false
    }

    /// Links or unlinks a file as one of this session's plans; returns whether it is linked.
    func setPlan(_ path: String, linked: Bool) -> Bool {
        guard let id = navigationSessionID else { return false }
        LinkedPlans.set(path, linked: linked, sessionID: id)
        return linked
    }
}
