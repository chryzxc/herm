import Foundation

/// Lane layout for the Source Control commit graph. Commits must be in
/// topological order (children before parents), as `git log --topo-order` emits.
struct RepositoryCommitGraphRow: Equatable {
    /// A line drawn from lane `from` to lane `to` across half a row.
    struct Segment: Equatable {
        let from: Int
        let to: Int
        let color: Int
    }

    let lane: Int
    let color: Int
    /// Row top to the commit node.
    let top: [Segment]
    /// Commit node to row bottom.
    let bottom: [Segment]
    var width: Int { ([lane] + (top + bottom).flatMap { [$0.from, $0.to] }).max()! + 1 }
}

enum RepositoryCommitGraph {
    static func layout(_ commits: [RepositoryCommit]) -> [RepositoryCommitGraphRow] {
        // Each lane waits for the commit hash it will draw down to next.
        var lanes: [(hash: String, color: Int)] = []
        var nextColor = 0
        return commits.map { commit in
            let incoming = lanes.indices.filter { lanes[$0].hash == commit.id }
            let lane: Int
            if let first = incoming.first {
                lane = first
            } else {
                // A branch tip nothing above points at starts a fresh lane.
                lanes.append((commit.id, nextColor))
                nextColor += 1
                lane = lanes.count - 1
            }
            let color = lanes[lane].color
            let top = lanes.indices.compactMap { index -> RepositoryCommitGraphRow.Segment? in
                guard incoming.contains(index) || lanes[index].hash != commit.id else { return nil }
                return .init(from: index, to: lanes[index].hash == commit.id ? lane : index, color: lanes[index].color)
            }

            // Lanes ending here close; the first parent continues this commit's lane.
            var next: [(hash: String, color: Int, origin: Int)] = []
            for (index, entry) in lanes.enumerated() {
                if index == lane {
                    if let parent = commit.parents.first { next.append((parent, color, lane)) }
                } else if entry.hash != commit.id {
                    next.append((entry.hash, entry.color, index))
                }
            }
            var joins: [RepositoryCommitGraphRow.Segment] = []
            for parent in commit.parents.dropFirst() {
                if let existing = next.firstIndex(where: { $0.hash == parent }) {
                    joins.append(.init(from: lane, to: existing, color: next[existing].color))
                } else {
                    next.append((parent, nextColor, lane))
                    nextColor += 1
                }
            }
            let bottom =
                next.enumerated().map { RepositoryCommitGraphRow.Segment(from: $1.origin, to: $0, color: $1.color) }
                + joins
            lanes = next.map { ($0.hash, $0.color) }
            return RepositoryCommitGraphRow(lane: lane, color: color, top: top, bottom: bottom)
        }
    }
}

struct RepositoryCommitReference: Equatable, Identifiable {
    enum Kind: Equatable { case branch, remote, tag }
    let name: String
    let kind: Kind
    var isHead = false
    /// A local branch whose same-named remote branch points at the same commit.
    var isSynced = false
    var id: String { "\(kind):\(name)" }

    /// Parses `%D` output from `git log --decorate=full`.
    static func parse(_ decoration: String) -> [RepositoryCommitReference] {
        var references: [RepositoryCommitReference] = []
        for token in decoration.components(separatedBy: ", ") {
            var name = token.trimmingCharacters(in: .whitespacesAndNewlines)
            var isHead = false
            if name.hasPrefix("HEAD -> ") {
                name.removeFirst("HEAD -> ".count)
                isHead = true
            }
            if name == "HEAD" {
                references.append(.init(name: "HEAD", kind: .branch, isHead: true))
            } else if name.hasPrefix("tag: refs/tags/") {
                references.append(.init(name: String(name.dropFirst("tag: refs/tags/".count)), kind: .tag))
            } else if name.hasPrefix("refs/heads/") {
                references.append(
                    .init(name: String(name.dropFirst("refs/heads/".count)), kind: .branch, isHead: isHead))
            } else if name.hasPrefix("refs/remotes/"), !name.hasSuffix("/HEAD") {
                references.append(.init(name: String(name.dropFirst("refs/remotes/".count)), kind: .remote))
            }
        }
        var syncedRemotes = Set<String>()
        for index in references.indices where references[index].kind == .branch {
            let suffix = "/" + references[index].name
            if let remote = references.first(where: {
                $0.kind == .remote && $0.name.hasSuffix(suffix) && !syncedRemotes.contains($0.name)
            }) {
                references[index].isSynced = true
                syncedRemotes.insert(remote.name)
            }
        }
        return references.filter { $0.kind != .remote || !syncedRemotes.contains($0.name) }.sorted {
            ($0.isHead ? 0 : 1, $0.kind.order) < ($1.isHead ? 0 : 1, $1.kind.order)
        }
    }
}

extension RepositoryCommitReference.Kind {
    fileprivate var order: Int {
        switch self {
        case .branch: 0
        case .remote: 1
        case .tag: 2
        }
    }
}
