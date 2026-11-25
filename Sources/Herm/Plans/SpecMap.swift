import Foundation

/// Status written in the document itself. The map never infers progress from
/// anything else (session activity, timestamps, or wording beyond "blocked").
enum SpecMapStatus: String, Equatable, Sendable {
    case todo, inProgress, done, blocked
}

struct SpecMapNode: Identifiable, Equatable, Sendable {
    /// Lane index plus source line: stable across reloads while the line holds.
    let id: String
    var title: String
    /// What follows a bold lead or a long title's first clause, so the title stays a name.
    var summary: String?
    /// The opening of the node's own notes (first sentence, or a table's size) for nodes
    /// without a summary; hidden once the node is expanded and the notes show in full.
    var preview: String?
    /// `P1.2`, `T3`, `Task 3` or `Step 3` when the item starts with one.
    var label: String?
    let line: Int
    var status: SpecMapStatus?
    var subtasksDone = 0
    var subtasksTotal = 0
    /// The node's own source text up to the next node or heading.
    var detail = ""
    /// Dependency references the document states but that match no node.
    var unresolved: [String] = []
    /// The enclosing task or section for nested items; `nil` for a phase's own steps.
    var parentID: String?
    var depth = 0
}

struct SpecMapEdge: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable { case sequence, dependency }
    let source: String
    let target: String
    let kind: Kind
}

struct SpecMapLane: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// The phase's own steps, in document order.
    var nodes: [SpecMapNode]
    /// Nested items keyed by their parent's id, in document order.
    var children: [String: [SpecMapNode]] = [:]

    var doneCount: Int { nodes.count { $0.status == .done } }
    /// Steps with a stated status; steps without one never count toward progress.
    var statedCount: Int { nodes.count { $0.status != nil } }

    func children(of id: String) -> [SpecMapNode] { children[id] ?? [] }

    /// A node's source lines without those its nested items hold. Removed by position, not
    /// text: each nested item's lines follow its title line in order, so a line the node
    /// shares with a child (a fence, `---`, `TBD`) stays with the node.
    func ownLines(of node: SpecMapNode) -> [String] {
        func subtree(_ id: String) -> [SpecMapNode] { children(of: id).flatMap { [$0] + subtree($0.id) } }
        func trimmed(_ line: some StringProtocol) -> String { line.trimmingCharacters(in: .whitespaces) }
        let lines = node.detail.split(separator: "\n").map(String.init)
        var removed = Set<Int>()
        var cursor = 1
        for child in subtree(node.id).sorted(by: { $0.line < $1.line }) {
            let childLines = child.detail.split(separator: "\n").map(trimmed)
            guard let first = childLines.first, cursor < lines.count,
                let start = lines[cursor...].firstIndex(where: { trimmed($0) == first })
            else { continue }
            cursor = start
            var index = start
            for line in childLines {
                while index < lines.count, trimmed(lines[index]) != line { index += 1 }
                guard index < lines.count else { break }
                removed.insert(index)
                index += 1
            }
        }
        return lines.indices.filter { !removed.contains($0) }.map { lines[$0] }
    }

    /// A node's own notes: its source text after the title line, without the lines its
    /// nested items already show as their own nodes.
    func notes(of node: SpecMapNode) -> String {
        let own = Array(ownLines(of: node).dropFirst())
        // A table whose rows became nested nodes leaves its header behind; drop that too.
        var kept: [String] = []
        for (index, line) in own.enumerated() {
            let row = { (i: Int) in own.indices.contains(i) ? own[i].trimmingCharacters(in: .whitespaces) : "" }
            let isRule = row(index).hasPrefix("|") && row(index).contains("---")
            let isHeader = row(index).hasPrefix("|") && row(index + 1).hasPrefix("|") && row(index + 1).contains("---")
            if isHeader, !row(index + 2).hasPrefix("|") { continue }
            if isRule, !row(index + 1).hasPrefix("|") { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .newlines)
            .dedented
    }

    /// Steps and every nested item, depth first.
    var allNodes: [SpecMapNode] {
        func walk(_ nodes: [SpecMapNode]) -> [SpecMapNode] { nodes.flatMap { [$0] + walk(children(of: $0.id)) } }
        return walk(nodes)
    }
}

/// A plan's structure, derived from its Markdown on every load and never stored.
struct SpecMap: Equatable, Sendable {
    let title: String
    let lanes: [SpecMapLane]
    let edges: [SpecMapEdge]
    /// Every node in reading order, built once so views never walk the lanes per row.
    let ordered: [SpecMapNode]
    private let byID: [String: SpecMapNode]
    private let laneByNode: [String: String]
    /// Dependency sources per target id.
    private let sourcesByTarget: [String: [String]]
    /// The first open step whose dependencies are all done and that has no open nested
    /// items, in document order; nil when the document states no status.
    private(set) var nextUp: SpecMapNode?

    init(title: String, lanes: [SpecMapLane], edges: [SpecMapEdge]) {
        self.title = title
        self.lanes = lanes
        self.edges = edges
        var ordered: [SpecMapNode] = []
        var laneByNode: [String: String] = [:]
        for lane in lanes {
            for node in lane.allNodes {
                ordered.append(node)
                laneByNode[node.id] = lane.id
            }
        }
        self.ordered = ordered
        self.laneByNode = laneByNode
        byID = Dictionary(ordered.map { ($0.id, $0) }) { first, _ in first }
        sourcesByTarget = Dictionary(grouping: edges.filter { $0.kind == .dependency }, by: \.target)
            .mapValues { $0.map(\.source) }
        nextUp = firstOpenStep()
    }

    static func == (lhs: SpecMap, rhs: SpecMap) -> Bool {
        lhs.title == rhs.title && lhs.lanes == rhs.lanes && lhs.edges == rhs.edges
            && lhs.droppedSections == rhs.droppedSections
    }

    static let minimumNodes = 2

    /// Headings at the phase level whose content produced no nodes; a map that drops
    /// sections misrepresents the document, so a looser reading is tried.
    var droppedSections = 0

    var nodeCount: Int { ordered.count }
    var hasStatus: Bool { ordered.contains { $0.status != nil } }
    /// Fewer nodes than this reads better as the document; the toggle stays hidden.
    var isUseful: Bool { nodeCount >= Self.minimumNodes }

    func node(_ id: String) -> SpecMapNode? { byID[id] }
    func lane(of id: String) -> SpecMapLane? { laneByNode[id].flatMap { id in lanes.first { $0.id == id } } }
    func sources(of id: String) -> [SpecMapNode] { (sourcesByTarget[id] ?? []).compactMap { byID[$0] } }
}

enum SpecMapParser {
    private static let detailLimit = 4_000

    private struct Heading {
        let level: Int
        let title: String
    }

    private struct ListItem {
        let indent: Int
        let isNumbered: Bool
        let box: Character?
        let text: String
    }

    private enum NodeKind { case item, section }

    /// How strictly a document must follow plan conventions to yield nodes.
    private enum Mode {
        /// Checklist and numbered items, phases from the repeated heading level.
        case strict
        /// Plain bullets count as steps too, for plans written as ordinary lists.
        case loose
        /// Also treats the repeated headings themselves as steps, for heading-and-prose specs.
        case outline
    }

    /// Tries the strictest reading first and loosens only while the map would be too thin to show.
    /// A checklist plan is taken as written; a reading without stated status must cover every section.
    static func parse(_ text: String, fallbackTitle: String) -> SpecMap {
        parseWithTitleSource(text, fallbackTitle: fallbackTitle).map
    }

    static func parseWithTitleSource(_ text: String, fallbackTitle: String) -> (map: SpecMap, usesFallbackTitle: Bool) {
        let strict = parse(text, fallbackTitle: fallbackTitle, mode: .strict)
        if strict.map.isUseful && (strict.map.hasStatus || strict.map.droppedSections == 0) { return strict }
        let loose = parse(text, fallbackTitle: fallbackTitle, mode: .loose)
        if loose.map.isUseful && (loose.map.hasStatus || loose.map.droppedSections == 0) { return loose }
        let outline = parse(text, fallbackTitle: fallbackTitle, mode: .outline)
        if outline.map.isUseful && (outline.map.hasStatus || outline.map.droppedSections == 0) { return outline }
        return [strict, loose, outline].first { $0.map.isUseful } ?? strict
    }

    private static func parse(_ text: String, fallbackTitle: String, mode: Mode)
        -> (map: SpecMap, usesFallbackTitle: Bool)
    {
        // Character-wise, so a CRLF break is one separator, not two with an empty line between.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var inFence = false
        // Fenced lines are kept as notes (code, diagrams) but never parsed as structure.
        let visible: [(number: Int, text: String, fenced: Bool)] = lines.enumerated().map { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return (index + 1, line, true)
            }
            return (index + 1, line, inFence)
        }

        let headings = visible.filter { !$0.fenced }.compactMap { heading($0.text) }
        let counts = Dictionary(grouping: headings, by: \.level).mapValues(\.count)
        let repeated = counts.filter { $0.value >= 2 }.keys.min()
        // An outline promotes the repeated headings one level, from phases to steps.
        let laneLevel = mode == .outline ? repeated.map { $0 - 1 } : repeated
        let headingTitle = headings.first(where: { $0.level == 1 })?.title ?? headings.first?.title
        let title = headingTitle ?? fallbackTitle

        // Nodes are kept flat per lane while parsing (parent ids link the tree), then grouped.
        var drafts: [(id: String, title: String, nodes: [SpecMapNode])] = []
        var kinds: [String: NodeKind] = [:]
        var sequence: [SpecMapEdge] = []
        /// The open chain of nodes nested lines attach to: the step first, then deeper items.
        /// `indent` is the list indent that opened each level (headings use negative levels).
        var stack: [(indent: Int, index: Int)] = []
        var lastNumbered: String?
        var skippedTitle = false
        /// The list item a directly following, non-blank line continues (a hard-wrapped item).
        var continuing: (index: Int, raw: String)?

        // An outline whose top heading is the lane level opens its lane there instead.
        if laneLevel == nil || (mode == .outline && !headings.contains { $0.level == laneLevel }) {
            drafts.append(("lane-0", title, []))
        }

        func appendDetail(_ line: String, to index: Int) {
            guard let lane = drafts.indices.last else { return }
            var node = drafts[lane].nodes[index]
            guard node.detail.count < detailLimit else { return }
            node.detail += (node.detail.isEmpty ? "" : "\n") + line
            if node.detail.count > detailLimit { node.detail = String(node.detail.prefix(detailLimit)) }
            drafts[lane].nodes[index] = node
        }

        /// The step always collects its text; a nested item also collects lines indented under it.
        func appendDetail(_ line: String, indent: Int) {
            guard let step = stack.first else { return }
            appendDetail(line, to: step.index)
            if stack.count > 1, let deepest = stack.last, indent > deepest.indent {
                appendDetail(line, to: deepest.index)
            }
        }

        func addNode(
            _ raw: String, line: Int, status: SpecMapStatus?, kind: NodeKind, source: String, parent: Int? = nil
        ) -> Int? {
            guard let laneIndex = drafts.indices.last else { return nil }
            let (label, title, summary) = name(raw)
            var node = SpecMapNode(
                id: "\(laneIndex):\(line)", title: title, summary: summary, label: label, line: line, status: status)
            node.detail = source.trimmingCharacters(in: .whitespaces)
            if let parent {
                node.parentID = drafts[laneIndex].nodes[parent].id
                node.depth = drafts[laneIndex].nodes[parent].depth + 1
            }
            drafts[laneIndex].nodes.append(node)
            kinds[node.id] = kind
            return drafts[laneIndex].nodes.count - 1
        }

        for (position, (number, line, fenced)) in visible.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            let proseIndent = line.prefix { $0 == " " || $0 == "\t" }.count
            if fenced {
                continuing = nil
                appendDetail(line, indent: proseIndent == 0 ? -1 : proseIndent)
                continue
            }
            if let item = continuing, let lane = drafts.indices.last, !trimmedLine.isEmpty,
                heading(line) == nil, listItem(line) == nil, !trimmedLine.hasPrefix("|")
            {
                let raw = item.raw + " " + trimmedLine
                let (label, title, summary) = name(raw)
                drafts[lane].nodes[item.index] = {
                    var node = $0
                    (node.title, node.summary) = (title, summary)
                    if node.label == nil { node.label = label }
                    return node
                }(drafts[lane].nodes[item.index])
                continuing = (item.index, raw)
                continue
            }
            continuing = nil
            if let heading = heading(line) {
                lastNumbered = nil
                if let laneLevel {
                    if heading.level == laneLevel {
                        drafts.append(("lane-\(drafts.count)", heading.title, []))
                        stack = []
                    } else if heading.level == laneLevel + 1, !drafts.isEmpty {
                        stack =
                            addNode(heading.title, line: number, status: nil, kind: .section, source: line)
                            .map { [(-2, $0)] } ?? []
                    } else if heading.level == laneLevel + 2, let section = stack.first {
                        stack =
                            addNode(
                                heading.title, line: number, status: nil, kind: .section, source: line,
                                parent: section.index
                            ).map { [section, (-2, $0)] } ?? [section]
                    } else if heading.level < laneLevel {
                        stack = []
                    } else {
                        appendDetail(line, indent: Int.max)
                    }
                } else if !skippedTitle {
                    skippedTitle = true
                } else {
                    stack =
                        addNode(heading.title, line: number, status: nil, kind: .section, source: line)
                        .map { [(-2, $0)] } ?? []
                }
                continue
            }
            guard let lane = drafts.indices.last else { continue }

            if let item = listItem(line) {
                let underSection = stack.first.map { kinds[drafts[lane].nodes[$0.index].id] == .section } ?? false
                let isTask = item.box != nil || item.isNumbered || mode != .strict
                if item.indent < 2, !underSection, isTask {
                    let index = addNode(
                        item.text, line: number, status: item.box.map { status($0, text: item.text) },
                        kind: .item, source: line)
                    stack = index.map { [(item.indent, $0)] } ?? []
                    continuing = index.map { ($0, item.text) }
                    if item.isNumbered, let index {
                        let id = drafts[lane].nodes[index].id
                        if let lastNumbered {
                            sequence.append(SpecMapEdge(source: lastNumbered, target: id, kind: .sequence))
                        }
                        lastNumbered = id
                    } else {
                        lastNumbered = nil
                    }
                    continue
                }
                guard isTask, !stack.isEmpty else {
                    appendDetail(line, indent: item.indent)
                    continue
                }
                while stack.count > 1, let last = stack.last, last.indent >= item.indent { stack.removeLast() }
                let childStatus = item.box.map { status($0, text: item.text) }
                // Every enclosing level counts the checkbox toward its progress.
                for level in stack {
                    appendDetail(line, to: level.index)
                    guard let childStatus else { continue }
                    var node = drafts[lane].nodes[level.index]
                    node.subtasksTotal += 1
                    if childStatus == .done { node.subtasksDone += 1 }
                    if kinds[node.id] == .section { node.status = sectionStatus(node, child: childStatus) }
                    drafts[lane].nodes[level.index] = node
                }
                if let index = addNode(
                    item.text, line: number, status: childStatus, kind: .item, source: line,
                    parent: stack.last?.index)
                {
                    stack.append((item.indent, index))
                    continuing = (index, item.text)
                }
                continue
            }

            // Without stated status a table's rows are the section's items (files, options, owners).
            if mode != .strict, trimmedLine.hasPrefix("|"), !stack.isEmpty {
                let next = visible.dropFirst(position + 1).first { !$0.fenced }?.text ?? ""
                if isTableRule(trimmedLine) || isTableRule(next.trimmingCharacters(in: .whitespaces)) {
                    appendDetail(line, indent: proseIndent == 0 ? -1 : proseIndent)
                    continue
                }
                while stack.count > 1, let last = stack.last, last.indent >= proseIndent { stack.removeLast() }
                for level in stack { appendDetail(line, to: level.index) }
                let cells = tableCells(trimmedLine)
                if let first = cells.first, !first.isEmpty {
                    let rest = cells.dropFirst().filter { !$0.isEmpty }.joined(separator: " · ")
                    _ = addNode(
                        rest.isEmpty ? first : "**\(first)** — \(rest)", line: number, status: nil, kind: .item,
                        source: line, parent: stack.last?.index)
                }
                lastNumbered = nil
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, line.first?.isWhitespace == false { lastNumbered = nil }
            if !trimmed.isEmpty {
                let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                appendDetail(line, indent: indent == 0 ? -1 : indent)
            }
        }

        let dropped = drafts.count { draft in !draft.nodes.contains { $0.parentID == nil } }
        var lanes = drafts.compactMap { draft -> SpecMapLane? in
            let steps = draft.nodes.filter { $0.parentID == nil }
            guard !steps.isEmpty else { return nil }
            let nested = Dictionary(grouping: draft.nodes.filter { $0.parentID != nil }) { $0.parentID ?? "" }
            return SpecMapLane(id: draft.id, title: draft.title, nodes: steps, children: nested)
        }
        for lane in lanes.indices {
            let snapshot = lanes[lane]
            func fill(_ node: inout SpecMapNode) {
                if node.summary == nil { node.preview = preview(snapshot.notes(of: node)) }
            }
            for index in lanes[lane].nodes.indices { fill(&lanes[lane].nodes[index]) }
            for key in snapshot.children.keys {
                for index in snapshot.children(of: key).indices { fill(&lanes[lane].children[key, default: []][index]) }
            }
        }
        let dependencies = resolveDependencies(&lanes)
        let ids = Set(lanes.flatMap { $0.allNodes.map(\.id) })
        var seen = Set<SpecMapEdge>()
        let edges = (sequence + dependencies).filter {
            ids.contains($0.source) && ids.contains($0.target) && seen.insert($0).inserted
        }
        var map = SpecMap(title: title, lanes: lanes, edges: edges)
        map.droppedSections = dropped
        return (map, headingTitle == nil)
    }

    // MARK: Lines

    private static func isTableRule(_ line: String) -> Bool {
        line.hasPrefix("|") && line.firstMatch(of: /^\|?\s*:?-{3,}/) != nil
    }

    private static func tableCells(_ line: String) -> [String] {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "| ")).split(
            separator: "|", omittingEmptySubsequences: false
        )
        .map { plain(String($0)) }
    }

    /// Joins hard-wrapped prose lines so Markdown renders paragraphs, not one line each.
    /// Lists, tables, headings, quotes, fences and blank lines keep their own lines.
    static func unwrapped(_ notes: String) -> String {
        var result: [String] = []
        var inFence = false
        var joinable = false
        for line in notes.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                result.append(line)
                joinable = false
                continue
            }
            let isBlock =
                inFence || trimmed.isEmpty || trimmed.hasPrefix("|") || trimmed.hasPrefix("#")
                || trimmed.hasPrefix(">") || trimmed.firstMatch(of: /^([-*+]|\d+[.)])\s/) != nil
            if !isBlock, joinable, let last = result.popLast() {
                result.append(last + " " + trimmed)
            } else {
                result.append(line)
            }
            // Prose and list items take continuation lines; tables and headings do not.
            joinable = !inFence && !trimmed.isEmpty && !trimmed.hasPrefix("|") && !trimmed.hasPrefix("#")
        }
        return result.joined(separator: "\n")
    }

    /// The first sentence of a node's notes, or a table's size: enough to know what is inside.
    static func preview(_ notes: String) -> String? {
        var inFence = false
        let lines = notes.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines where !line.isEmpty {
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if line.hasPrefix("|") {
                let rows = lines.count { $0.hasPrefix("|") } - 2
                return rows > 0 ? "Table · \(rows) row\(rows == 1 ? "" : "s")" : nil
            }
            let text = plain(line.replacing(/^(?:[-*+>]|\d+[.)])\s+/, with: ""))
            guard !text.isEmpty else { continue }
            let sentence = text.firstRange(of: /[.!?](?=\s)/).map { String(text[..<$0.upperBound]) } ?? text
            return sentence.count > 160 ? String(sentence.prefix(159)) + "…" : sentence
        }
        return nil
    }

    /// Lines outside fenced blocks, so code never reads as a stated dependency.
    static func unfenced(_ lines: [String]) -> [String] {
        var inFence = false
        return lines.filter { line in
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                return false
            }
            return !inFence
        }
    }

    private static func heading(_ line: String) -> Heading? {
        guard let match = line.firstMatch(of: /^(#{1,6})\s+(.+?)\s*#*\s*$/) else { return nil }
        return Heading(level: match.1.count, title: plain(String(match.2)))
    }

    private static func listItem(_ line: String) -> ListItem? {
        guard let match = line.firstMatch(of: /^([ \t]*)([-*+]|\d+[.)])\s+(?:\[([ xX~\/-])\]\s*)?(.*)$/) else {
            return nil
        }
        let indent = match.1.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let marker = match.2
        var box = match.3?.first
        var text = String(match.4)
        if box == nil, let (mark, rest) = statusMark(text) {
            box = mark
            text = rest
        }
        return ListItem(indent: indent, isNumbered: marker.first?.isNumber == true, box: box, text: text)
    }

    /// Status written without a checkbox: a leading emoji, or the whole item struck through.
    private static func statusMark(_ text: String) -> (Character, String)? {
        let marks: [(Character, [String])] = [
            ("x", ["✅", "✔️", "✔", "☑️", "☑"]), ("~", ["🚧", "⏳", "🔄"]),
            ("!", ["⛔", "❌", "🚫"]), (" ", ["☐", "⬜", "🔲"]),
        ]
        for (mark, prefixes) in marks {
            if let prefix = prefixes.first(where: text.hasPrefix) {
                return (mark, text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
            }
        }
        if text.count > 4, text.hasPrefix("~~"), text.hasSuffix("~~") {
            return ("x", String(text.dropFirst(2).dropLast(2)))
        }
        return nil
    }

    private static func status(_ box: Character, text: String) -> SpecMapStatus {
        switch box {
        case "x", "X": return .done
        case "~", "-", "/": return .inProgress
        case "!": return .blocked
        default: return text.firstMatch(of: /(?i)\bblocked\b/) != nil ? .blocked : .todo
        }
    }

    /// A section's status summarizes its checkboxes; it has none without them.
    private static func sectionStatus(_ node: SpecMapNode, child: SpecMapStatus) -> SpecMapStatus {
        if node.status == .blocked || child == .blocked { return .blocked }
        if node.subtasksDone == node.subtasksTotal { return .done }
        if node.subtasksDone > 0 || child == .inProgress || node.status == .inProgress { return .inProgress }
        return .todo
    }

    // MARK: Text

    /// Inline Markdown removed, so titles match what the rendered document shows.
    static func plain(_ text: String) -> String {
        var result = text.replacing(/\[([^\]]*)\]\([^)]*\)/) { String($0.1) }
        for token in ["**", "__", "~~", "`"] { result = result.replacingOccurrences(of: token, with: "") }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static let longTitle = 72

    /// Label, title and summary for an item: a bold lead names it; otherwise a long title
    /// breaks at its first clause. Nothing is generated, so the words are always the document's.
    static func name(_ raw: String) -> (label: String?, title: String, summary: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // A bold lead ends in punctuation (inside or after the emphasis) or ends the item;
        // a bold term inside a sentence ("**Delegated to** is …") stays part of the title.
        if let match = trimmed.firstMatch(of: /^(?:\*\*|__)(.+?)(?:\*\*|__)(.*)$/) {
            let lead = String(match.1)
            var rest = String(match.2).trimmingCharacters(in: .whitespaces)
            let punctuated = lead.last.map { ":.—–".contains($0) } ?? false
            let separated = rest.first.map { ":.—–-".contains($0) } ?? true
            if punctuated || separated {
                if !punctuated { rest = String(rest.drop { ":.—–- ".contains($0) }) }
                let (label, title) = split(plain(lead))
                let cleanRest = plain(rest)
                return (
                    label, title.trimmingCharacters(in: CharacterSet(charactersIn: " :.—–-")),
                    cleanRest.isEmpty ? nil : cleanRest
                )
            }
        }
        let (label, title) = split(plain(trimmed))
        let whole = title.hasSuffix("...") ? title : title.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard title.count > longTitle else { return (label, whole, nil) }
        for separator in [" — ", " – ", ": ", ". ", "; ", " - "] {
            guard let range = title.range(of: separator) else { continue }
            let head = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let tail = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
            // A first sentence may run to two lines; any longer and it is the whole thought.
            if head.count >= 8, head.count <= longTitle * 3 / 2, !tail.isEmpty { return (label, head, tail) }
        }
        return (label, whole, nil)
    }

    private static func split(_ text: String) -> (label: String?, title: String) {
        let label: String?
        let rest: Substring
        if let match = text.firstMatch(of: /^(?:(?:Task|Step)\s+)?(P\d+(?:\.\d+)+|T\d+(?:\.\d+)*)\b/) {
            label = String(match.1)
            rest = text[match.range.upperBound...]
        } else if let match = text.firstMatch(of: /^(Task|Step)\s+(\d+(?:\.\d+)*)\b/) {
            label = "\(match.1) \(match.2)"
            rest = text[match.range.upperBound...]
        } else {
            return (nil, text)
        }
        let title = rest.trimmingCharacters(in: CharacterSet(charactersIn: " :.)-–—"))
        return (label, title.isEmpty ? label ?? text : title)
    }

    // MARK: Dependencies

    private static func resolveDependencies(_ lanes: inout [SpecMapLane]) -> [SpecMapEdge] {
        var byKey: [String: String] = [:]
        for node in lanes.flatMap(\.allNodes) {
            for key in [node.label, node.title].compactMap({ $0?.lowercased() }) where byKey[key] == nil {
                byKey[key] = node.id
            }
        }
        var edges: [SpecMapEdge] = []
        func resolve(_ node: inout SpecMapNode, in lane: SpecMapLane) {
            var unresolved: [String] = []
            // A step's detail includes its nested items' lines; only its own lines count,
            // so a child's "depends on" is not attributed to its parent too.
            let own = unfenced(lane.ownLines(of: node).map { $0.trimmingCharacters(in: .whitespaces) })
                .joined(separator: "\n")
            for match in own.matches(
                of: /(?i)\b(depends on|blocked by|requires|after)\s+((?:[^.;\n]|\.(?=\d))+)/)
            {
                // "after" and "requires" are ordinary prose far more often than references
                // ("requires a migration"), so they only count when they resolve to a step.
                let strict = ["depends on", "blocked by"].contains(match.1.lowercased())
                for raw in match.2.split(separator: /,|\band\b|\)/) {
                    let reference = plain(String(raw)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'#("))
                    guard !reference.isEmpty else { continue }
                    if let target = byKey[reference.lowercased()], target != node.id {
                        edges.append(SpecMapEdge(source: target, target: node.id, kind: .dependency))
                    } else if strict, !unresolved.contains(reference) {
                        unresolved.append(reference)
                    }
                }
            }
            node.unresolved = unresolved
        }
        for lane in lanes.indices {
            let snapshot = lanes[lane]
            for index in lanes[lane].nodes.indices { resolve(&lanes[lane].nodes[index], in: snapshot) }
            for key in snapshot.children.keys {
                for index in snapshot.children(of: key).indices {
                    resolve(&lanes[lane].children[key, default: []][index], in: snapshot)
                }
            }
        }
        return edges
    }
}

extension String {
    /// Common leading indentation removed, so nested notes render as Markdown, not code.
    var dedented: String {
        let lines = split(separator: "\n", omittingEmptySubsequences: false)
        let indent =
            lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        guard indent > 0 else { return self }
        return lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " || $0 == "\t" }.count))) }
            .joined(separator: "\n")
    }
}

/// What a section heading says about itself; only its own words count.
enum SpecMapSectionTone: Equatable {
    case muted, attention, decision

    init?(title: String) {
        let words = title.lowercased()
        func has(_ terms: [String]) -> Bool { terms.contains { words.contains($0) } }
        if has(["non-goal", "non goal", "out of scope", "not in scope", "deferred", "won't", "later"]) {
            self = .muted
        } else if has(["open question", "question", "risk", "unknown", "concern", "caveat"]) {
            self = .attention
        } else if has(["decision", "recommend", "chosen", "verdict"]) {
            self = .decision
        } else {
            return nil
        }
    }
}

/// Live work Hermes reports for the session, matched to a node by its words.
enum SpecMapLiveStatus: Equatable {
    case working, done
}

extension SpecMap {
    private static func normalized(_ text: String) -> String {
        SpecMapParser.plain(text).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var orderedNodes: [SpecMapNode] { ordered }

    fileprivate func firstOpenStep() -> SpecMapNode? {
        guard hasStatus else { return nil }
        let done = Set(orderedNodes.filter { $0.status == .done }.map(\.id))
        return orderedNodes.sorted { $0.line < $1.line }.first { node in
            (node.status == .todo || node.status == .inProgress)
                && !lanes.contains { $0.children(of: node.id).contains { $0.status != nil && $0.status != .done } }
                && edges.allSatisfy { $0.kind != .dependency || $0.target != node.id || done.contains($0.source) }
        }
    }

    /// Top-level steps with a stated status; nil when the document states none.
    var progress: (done: Int, total: Int, blocked: Int)? {
        let steps = lanes.flatMap(\.nodes).filter { $0.status != nil }
        guard !steps.isEmpty else { return nil }
        return (steps.count { $0.status == .done }, steps.count, steps.count { $0.status == .blocked })
    }

    /// Titles of nodes that are new or whose text changed since `old`; titles, because
    /// ids follow source lines and shift whenever text is inserted above.
    /// Compares each title's texts as a group, so steps sharing a title ("Tests" in two
    /// phases) are not each measured against the first one's text.
    func changedTitles(since old: SpecMap) -> Set<String> {
        func texts(_ map: SpecMap) -> [String: [String]] {
            Dictionary(grouping: map.ordered, by: \.title).mapValues { $0.map(\.detail).sorted() }
        }
        let before = texts(old)
        return Set(texts(self).filter { before[$0.key] != $0.value }.keys)
    }

    /// The id `id` (from `old`) has here. Ids follow source lines, so when text moves the
    /// same id can name another step; the step is then found by its title instead. Ids
    /// `old` does not know as nodes (phase ids) come back unchanged.
    func matching(_ id: String, from old: SpecMap) -> String? {
        guard let was = old.node(id) else { return id }
        if node(id)?.title == was.title { return id }
        return ordered.first { $0.title == was.title }?.id
    }

    /// The map as a plain Markdown outline, statuses kept as checkboxes.
    var outline: String {
        var lines = ["# \(title)"]
        func box(_ status: SpecMapStatus?) -> String {
            switch status {
            case .done: "[x] "
            case .inProgress: "[~] "
            case .todo, .blocked: "[ ] "
            case nil: ""
            }
        }
        func walk(_ nodes: [SpecMapNode], in lane: SpecMapLane, depth: Int) {
            for node in nodes {
                let label = node.label.map { "\($0) " } ?? ""
                let summary = (node.summary ?? node.preview).map { " — \($0)" } ?? ""
                lines.append(
                    String(repeating: "  ", count: depth) + "- \(box(node.status))\(label)\(node.title)\(summary)")
                walk(lane.children(of: node.id), in: lane, depth: depth + 1)
            }
        }
        for lane in lanes {
            if lanes.count > 1 || lane.title != title { lines += ["", "## \(lane.title)"] }
            walk(lane.nodes, in: lane, depth: 0)
        }
        return lines.joined(separator: "\n")
    }

    /// The deepest node whose own text contains a quote taken from the rendered document.
    func node(quoting quote: String) -> SpecMapNode? {
        let needle = Self.normalized(quote)
        guard needle.count >= 3 else { return nil }
        return orderedNodes.filter { Self.normalized("\($0.title) \($0.summary ?? "") \($0.detail)").contains(needle) }
            .max { $0.depth < $1.depth }
    }

    /// The node whose title last appears at or before `offset` in the rendered document.
    /// Titles are found in order, so a repeated phrase resolves to the right section.
    func node(atRenderedOffset offset: Int, in rendered: String) -> SpecMapNode? {
        let text = rendered as NSString
        var cursor = 0
        var found: SpecMapNode?
        for node in orderedNodes {
            let range = text.range(
                of: node.title, options: .caseInsensitive,
                range: NSRange(location: cursor, length: text.length - cursor))
            guard range.location != NSNotFound else { continue }
            if range.location > offset { break }
            found = node
            cursor = NSMaxRange(range)
        }
        return found
    }

    /// Session task-list items matched to nodes by title; only unambiguous matches count.
    func liveStatuses(_ items: [(content: String, status: String)]) -> [String: SpecMapLiveStatus] {
        var result: [String: SpecMapLiveStatus] = [:]
        for item in items {
            let status: SpecMapLiveStatus
            switch item.status {
            case "in_progress": status = .working
            case "completed": status = .done
            default: continue
            }
            if let node = node(namedBy: item.content), node.status != .done || status == .working {
                result[node.id] = status
            }
        }
        return result
    }

    /// The one node a task-list item names (titles of six or more characters, either one
    /// containing the other); nil when it names none or several.
    func node(namedBy content: String) -> SpecMapNode? {
        let task = Self.normalized(content)
        let matches = orderedNodes.filter { node in
            let title = Self.normalized(node.title)
            return title.count >= 6 && (task.contains(title) || (task.count >= 6 && title.contains(task)))
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Progress for a plan whose file states none: the steps the session's task list names,
    /// how many it closed, and the step it is on (else the first pending one). Nil when the
    /// list names no step, so an unrelated task list never reads as plan progress.
    func taskListProgress(_ items: [(content: String, status: String)]) -> (done: Int, total: Int, current: String?)? {
        var statuses: [String: String] = [:]
        var working: String?
        var pending: String?
        for item in items {
            guard let node = node(namedBy: item.content) else { continue }
            statuses[node.id] = item.status
            if item.status == "in_progress", working == nil { working = node.title }
            if item.status == "pending", pending == nil { pending = node.title }
        }
        guard !statuses.isEmpty else { return nil }
        let done = statuses.values.count { $0 == "completed" || $0 == "cancelled" }
        return (done, statuses.count, working ?? pending)
    }
}

extension SpecMapParser {
    /// Repository-relative file paths a node's text mentions, in order, without URLs.
    static func filePaths(in text: String) -> [String] {
        var paths: [String] = []
        for match in text.matches(of: /(?:[\w.-]+\/)+[\w-]+\.[A-Za-z]{1,8}\b/) {
            let before = text[..<match.range.lowerBound]
            guard !before.hasSuffix("/"), !before.hasSuffix(":") else { continue }
            let path = String(match.output)
            if !paths.contains(path) { paths.append(path) }
        }
        return Array(paths.prefix(8))
    }
}
