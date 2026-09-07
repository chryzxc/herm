import Foundation
import SwiftUI

enum PullRequestFilter: String, CaseIterable, Identifiable {
    case all = "All", reviewing = "Reviewing", authored = "Authored"
    var id: Self { self }
}

final class PullRequestChatLinkStore: ObservableObject {
    private let defaults = UserDefaults.standard
    private let key = "hermes.pull-request-chat-links"
    func sessionID(for pullRequestID: String) -> String? { (defaults.dictionary(forKey: key) as? [String: String])?[pullRequestID] }
    func save(sessionID: String, for pullRequestID: String) {
        var links = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        links[pullRequestID] = sessionID
        defaults.set(links, forKey: key)
    }
    func remove(pullRequestID: String) {
        var links = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        links.removeValue(forKey: pullRequestID)
        defaults.set(links, forKey: key)
    }
}

struct PullRequestFile: Identifiable, Equatable {
    let path: String
    let status: String
    let additions: Int
    let deletions: Int
    let patch: String?
    let webURL: URL?
    var id: String { path }
}

struct PullRequestComment: Identifiable, Equatable, Sendable {
    let id: String
    let body: String
    let author: String
    let authorAvatarURL: URL?
    let createdAt: Date?
    let webURL: URL?
}

struct PullRequestCommit: Identifiable, Equatable, Sendable {
    let id: String
    let message: String
    let author: String
    let authorAvatarURL: URL?
    let committedAt: Date?
    let webURL: URL?
}

enum PullRequestStatus: String, CaseIterable, Identifiable, Sendable {
    case draft = "Draft"
    case readyForReview = "Ready for review"
    case closed = "Closed"
    var id: Self { self }
}

enum PullRequestDiffMode: String, CaseIterable, Identifiable {
    case unified, split
    var id: Self { self }
    var label: String { self == .unified ? "Unified diff" : "Split diff" }
}

final class PullRequestReviewPreferenceStore: ObservableObject {
    private let defaults: UserDefaults
    private let prefix = "hermes.pull-request-review."
    @Published var showsFileTree: Bool { didSet { persist() } }
    @Published var diffMode: PullRequestDiffMode { didSet { persist() } }
    @Published var wordWrap: Bool { didSet { persist() } }
    @Published var richPreview: Bool { didSet { persist() } }
    @Published var wordDiffs: Bool { didSet { persist() } }
    @Published var expandedFileIDs: Set<String> { didSet { persist() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsFileTree = defaults.object(forKey: prefix + "file-tree") as? Bool ?? false
        diffMode = PullRequestDiffMode(rawValue: defaults.string(forKey: prefix + "diff-mode") ?? "unified") ?? .unified
        wordWrap = defaults.object(forKey: prefix + "word-wrap") as? Bool ?? false
        richPreview = defaults.object(forKey: prefix + "rich-preview") as? Bool ?? false
        wordDiffs = defaults.object(forKey: prefix + "word-diffs") as? Bool ?? false
        expandedFileIDs = Set(defaults.stringArray(forKey: prefix + "expanded-files") ?? [])
    }

    func toggleExpanded(_ fileID: String) {
        if expandedFileIDs.contains(fileID) { expandedFileIDs.remove(fileID) } else { expandedFileIDs.insert(fileID) }
    }

    func setAllExpanded(_ fileIDs: Set<String>) {
        expandedFileIDs = expandedFileIDs.isSuperset(of: fileIDs) ? [] : fileIDs
    }

    private func persist() {
        defaults.set(showsFileTree, forKey: prefix + "file-tree")
        defaults.set(diffMode.rawValue, forKey: prefix + "diff-mode")
        defaults.set(wordWrap, forKey: prefix + "word-wrap")
        defaults.set(richPreview, forKey: prefix + "rich-preview")
        defaults.set(wordDiffs, forKey: prefix + "word-diffs")
        defaults.set(Array(expandedFileIDs).sorted(), forKey: prefix + "expanded-files")
    }
}

struct PullRequestFileTreeNode: Identifiable, Equatable {
    let id: String
    let title: String
    let depth: Int
    let isDirectory: Bool
    let fileID: String?
}

enum PullRequestFileTreeBuilder {
    static func make(files: [PullRequestFile]) -> [PullRequestFileTreeNode] {
        var directories = Set<String>()
        var nodes: [(path: String, title: String, depth: Int, isDirectory: Bool, fileID: String?)] = []
        for file in files {
            let components = file.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            if components.count > 1 {
                for index in 1..<(components.count) {
                    directories.insert(components.prefix(index).joined(separator: "/"))
                }
            }
        }
        let allPaths = Set(files.map(\.path)).union(directories)
        for path in allPaths.sorted() {
            let parts = path.split(separator: "/").map(String.init)
            let directory = directories.contains(path)
            nodes.append((path, parts.last ?? path, max(0, parts.count - 1), directory, directory ? nil : path))
        }
        return nodes.sorted { lhs, rhs in
            if lhs.path == rhs.path { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }.map { PullRequestFileTreeNode(id: $0.path, title: $0.title, depth: $0.depth, isDirectory: $0.isDirectory, fileID: $0.fileID) }
    }
}

enum PullRequestDiffLineKind: Equatable {
    case context, addition, deletion, hunk, metadata
}

struct PullRequestDiffLine: Identifiable, Equatable {
    let index: Int
    let text: String
    let kind: PullRequestDiffLineKind
    var id: Int { index }

    init(index: Int, text: String) {
        self.index = index
        self.text = text
        if text.hasPrefix("@@") { kind = .hunk }
        else if text.hasPrefix("+++") || text.hasPrefix("---") { kind = .metadata }
        else if text.hasPrefix("+") { kind = .addition }
        else if text.hasPrefix("-") { kind = .deletion }
        else { kind = .context }
    }
}

struct PullRequestDiffSplitRow: Identifiable, Equatable {
    let id: Int
    let left: PullRequestDiffLine?
    let right: PullRequestDiffLine?
}

enum PullRequestDiffPresentation {
    static func lines(_ patch: String) -> [PullRequestDiffLine] {
        patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { PullRequestDiffLine(index: $0.offset, text: String($0.element)) }
    }

    static func splitRows(_ lines: [PullRequestDiffLine]) -> [PullRequestDiffSplitRow] {
        var rows: [PullRequestDiffSplitRow] = []
        var cursor = 0
        while cursor < lines.count {
            let line = lines[cursor]
            if line.kind == .deletion {
                var deletions: [PullRequestDiffLine] = []
                while cursor < lines.count, lines[cursor].kind == .deletion { deletions.append(lines[cursor]); cursor += 1 }
                var additions: [PullRequestDiffLine] = []
                while cursor < lines.count, lines[cursor].kind == .addition { additions.append(lines[cursor]); cursor += 1 }
                for index in 0..<max(deletions.count, additions.count) {
                    rows.append(PullRequestDiffSplitRow(id: rows.count, left: index < deletions.count ? deletions[index] : nil, right: index < additions.count ? additions[index] : nil))
                }
            } else if line.kind == .addition {
                rows.append(PullRequestDiffSplitRow(id: rows.count, left: nil, right: line))
                cursor += 1
            } else {
                rows.append(PullRequestDiffSplitRow(id: rows.count, left: line, right: line.kind == .context || line.kind == .metadata ? line : nil))
                cursor += 1
            }
        }
        return rows
    }
}

/// Keeps patch parsing out of SwiftUI's scrolling/layout pass. A patch is
/// immutable for the lifetime of a loaded pull request, so its presentation
/// rows are safe to reuse until the selected pull request changes.
@MainActor
final class PullRequestDiffPresentationCache: ObservableObject {
    private var rowsByPatch: [String: [PullRequestDiffSplitRow]] = [:]

    func rows(for patch: String) -> [PullRequestDiffSplitRow] {
        if let rows = rowsByPatch[patch] { return rows }
        let rows = PullRequestDiffPresentation.splitRows(PullRequestDiffPresentation.lines(patch))
        rowsByPatch[patch] = rows
        return rows
    }

    func removeAll() {
        rowsByPatch.removeAll(keepingCapacity: true)
    }
}

enum LucideIconName {
    case gitPullRequest, gitBranch, refreshCw, search, arrowRight, arrowUp, arrowDown, pencil, check, checkCircle, xmark, fileText, braces, image
    case sun, inbox, kanban, gauge, clock, activity, audioLines, bot, fileSearch, users, user, folder, messages, messageCircle, messageCirclePlus, settings, panelOpen, panelClosed, chevronDown, chevronUp, chevronRight, chevronLeft, arrowDownUp, fileDiff, plus, ellipsis, circle, triangleAlert, trash, terminal, paperclip, mic, stop, pause, calendar, link, externalLink, sliders, radio, cpu, brain, flame, eye, download, upload, expand, minimize, fullscreen, sparkles

    static func from(systemName: String) -> Self {
        switch systemName {
        case "sun.max": return .sun
        case "tray": return .inbox
        case "rectangle.3.group": return .kanban
        case "gauge.with.dots.needle.50percent", "gauge.with.dots.needle.bottom.50percent": return .gauge
        case "clock.arrow.circlepath": return .clock
        case "stopwatch": return .clock
        case "waveform.path.ecg": return .activity
        case "audio-lines": return .audioLines
        case "bot": return .bot
        case "doc.text.magnifyingglass": return .fileSearch
        case "person.2", "person.2.fill", "person.2.slash", "person.badge.key": return .users
        case "folder", "folder.fill", "folder.badge.plus", "folder.badge.gearshape": return .folder
        case "bubble.left.and.bubble.right": return .messages
        case "gearshape", "gearshape.2": return .settings
        case "chevron.down": return .chevronDown
        case "chevron.up": return .chevronUp
        case "chevron.right": return .chevronRight
        case "chevron.left": return .chevronLeft
        case "chevron.up.chevron.down": return .chevronDown
        case "plus", "text.badge.plus": return .plus
        case "magnifyingglass": return .search
        case "scope": return .search
        case "refresh-cw", "arrow.clockwise", "arrow.triangle.2.circlepath": return .refreshCw
        case "arrow.right", "arrow.up.right", "arrow.up.forward.app": return .arrowRight
        case "arrow.up": return .arrowUp
        case "arrow.down": return .arrowDown
        case "arrow.down.right.and.arrow.up.left": return .minimize
        case "arrow.up.left.and.arrow.down.right": return .expand
        case "arrow.triangle.branch": return .gitBranch
        case "pencil": return .pencil
        case "square.and.pencil": return .messageCirclePlus
        case "checkmark": return .check
        case "checkmark.circle", "checkmark.circle.fill", "checkmark.seal", "checkmark.shield": return .checkCircle
        case "doc", "doc.text", "doc.text.fill", "doc.badge.gearshape", "doc.on.doc", "list.bullet.indent", "number": return .fileText
        case "checklist": return .checkCircle
        case "rectangle": return .panelClosed
        case "rectangle.split.2x1": return .panelOpen
        case "ellipsis", "ellipsis.circle": return .ellipsis
        case "circle", "circle.dotted": return .circle
        case "trash": return .trash
        case "lock.slash", "exclamationmark.triangle", "exclamationmark.triangle.fill", "exclamationmark.circle", "exclamationmark.octagon", "exclamationmark.shield", "minus.circle": return .triangleAlert
        case "xmark", "xmark.circle.fill", "xmark.octagon": return .xmark
        case "waveform", "bolt.fill", "wand.and.stars", "sparkles": return .sparkles
        case "terminal", "terminal.fill", "command": return .terminal
        case "paperclip": return .paperclip
        case "mic.fill": return .mic
        case "stop.fill": return .stop
        case "pause.circle.fill": return .pause
        case "calendar.badge.clock": return .calendar
        case "link", "link.badge.plus", "key.horizontal": return .link
        case "line.3.horizontal.decrease.circle": return .sliders
        case "dot.radiowaves.left.and.right": return .radio
        case "cpu.fill": return .cpu
        case "brain", "brain.head.profile": return .brain
        case "flame.fill": return .flame
        case "eye", "eye.slash": return .eye
        case "square.and.arrow.down": return .download
        case "arrow.up.forward.square": return .arrowRight
        case "text.bubble": return .messageCircle
        case "message-circle-plus", "plus.bubble": return .messageCirclePlus
        case "person.fill": return .user
        default: return .fileText
        }
    }
}

/// Small vendored subset of Lucide's 24px outline icons. Keeping the paths
/// local makes the PR workspace use one icon family without a runtime package.
struct LucideIcon: View {
    let name: LucideIconName
    var size: CGFloat = 17
    var color: Color = Color.dockMetadataText
    var body: some View {
        LucideIconShape(name: name)
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Shared adapter for the existing semantic icon names used by the app. Names
/// are mapped into the local Lucide catalog, so production views never
/// instantiate SF Symbols directly.
struct LucideImage: View {
    let systemName: String
    var body: some View {
        LucideIcon(name: .from(systemName: systemName), size: 16)
    }
}

private struct PullRequestReviewToolbarIcon: View {
    let name: LucideIconName
    let accessibilityLabel: String
    var isSelected = false
    var tooltip: String? = nil
    @State private var isHovered = false

    var body: some View {
        LucideIcon(
            name: name,
            size: 14,
            color: isSelected || isHovered ? Color.dockPrimaryText : Color.dockSecondaryText
        )
        .frame(width: 28, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.dockSurface4 : (isHovered ? Color.dockSurface4.opacity(0.72) : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovered = $0 }
        .help(tooltip ?? accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Text-and-icon controls use the same Lucide catalog as standalone icons.
struct LucideLabel: View {
    let title: String
    let systemName: String
    var iconColor: Color = .dockMetadataText

    init(_ title: String, icon systemName: String, iconColor: Color = .dockMetadataText) {
        self.title = title
        self.systemName = systemName
        self.iconColor = iconColor
    }

    var body: some View {
        HStack(spacing: 6) {
            LucideIcon(name: .from(systemName: systemName), size: 16, color: iconColor)
            Text(title)
        }
    }
}

private struct LucideIconShape: Shape {
    let name: LucideIconName
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        var path = Path()
        switch name {
        case .gitPullRequest:
            // Official Lucide `git-pull-request` path:
            // two commit nodes, the source branch, and the requested branch.
            path.addEllipse(in: CGRect(x: 15 * s, y: 15 * s, width: 6 * s, height: 6 * s))
            path.addEllipse(in: CGRect(x: 3 * s, y: 3 * s, width: 6 * s, height: 6 * s))
            path.move(to: p(13, 6)); path.addLine(to: p(16, 6)); path.addArc(center: p(16, 8), radius: 2 * s, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false); path.addLine(to: p(18, 15))
            path.move(to: p(6, 9)); path.addLine(to: p(6, 21))
        case .gitBranch:
            path.addEllipse(in: CGRect(x: 3 * s, y: 3 * s, width: 6 * s, height: 6 * s)); path.addEllipse(in: CGRect(x: 15 * s, y: 15 * s, width: 6 * s, height: 6 * s)); path.move(to: p(6, 9)); path.addLine(to: p(6, 18)); path.addCurve(to: p(15, 18), control1: p(6, 13), control2: p(10, 18)); path.move(to: p(15, 9)); path.addLine(to: p(15, 15))
        case .refreshCw:
            // Official Lucide `refresh-cw`: two directional arcs rather than
            // the single rotate arrow previously used by the shared adapter.
            path.move(to: p(21, 12))
            path.addCurve(to: p(12, 3), control1: p(21, 7.03), control2: p(16.97, 3))
            path.addCurve(to: p(5.43, 5.82), control1: p(9.41, 3), control2: p(7.06, 4.08))
            path.addLine(to: p(3, 8))
            path.move(to: p(3, 3)); path.addLine(to: p(3, 8)); path.addLine(to: p(8, 8))
            path.move(to: p(3, 12))
            path.addCurve(to: p(12, 21), control1: p(3, 16.97), control2: p(7.03, 21))
            path.addCurve(to: p(18.57, 18.18), control1: p(14.59, 21), control2: p(16.94, 19.92))
            path.addLine(to: p(21, 16))
            path.move(to: p(16, 16)); path.addLine(to: p(21, 16)); path.addLine(to: p(21, 21))
        case .search:
            path.addEllipse(in: CGRect(x: 3 * s, y: 3 * s, width: 13 * s, height: 13 * s)); path.move(to: p(14, 14)); path.addLine(to: p(21, 21))
        case .arrowRight:
            path.move(to: p(4, 12)); path.addLine(to: p(20, 12)); path.move(to: p(14, 6)); path.addLine(to: p(20, 12)); path.addLine(to: p(14, 18))
        case .arrowUp:
            path.move(to: p(12, 20)); path.addLine(to: p(12, 4)); path.move(to: p(6, 10)); path.addLine(to: p(12, 4)); path.addLine(to: p(18, 10))
        case .arrowDown:
            path.move(to: p(12, 4)); path.addLine(to: p(12, 20)); path.move(to: p(6, 14)); path.addLine(to: p(12, 20)); path.addLine(to: p(18, 14))
        case .pencil:
            path.move(to: p(4, 20)); path.addLine(to: p(5, 16)); path.addLine(to: p(16, 5)); path.addLine(to: p(19, 8)); path.addLine(to: p(8, 19)); path.closeSubpath(); path.move(to: p(14, 7)); path.addLine(to: p(17, 10))
        case .checkCircle:
            path.addEllipse(in: CGRect(x: 3 * s, y: 3 * s, width: 18 * s, height: 18 * s)); path.move(to: p(8, 12)); path.addLine(to: p(11, 15)); path.addLine(to: p(16, 9))
        case .check:
            path.move(to: p(5, 12)); path.addLine(to: p(10, 17)); path.addLine(to: p(19, 7))
        case .xmark:
            path.move(to: p(6, 6)); path.addLine(to: p(18, 18)); path.move(to: p(18, 6)); path.addLine(to: p(6, 18))
        case .fileText:
            path.move(to: p(14, 2)); path.addLine(to: p(20, 8)); path.addLine(to: p(20, 22)); path.addLine(to: p(4, 22)); path.addLine(to: p(4, 2)); path.closeSubpath(); path.move(to: p(14, 2)); path.addLine(to: p(14, 8)); path.addLine(to: p(20, 8)); path.move(to: p(8, 13)); path.addLine(to: p(16, 13)); path.move(to: p(8, 17)); path.addLine(to: p(16, 17))
        case .braces:
            path.move(to: p(9, 3)); path.addCurve(to: p(6, 8), control1: p(6, 3), control2: p(6, 5)); path.addLine(to: p(6, 10)); path.addCurve(to: p(4, 12), control1: p(6, 11), control2: p(5, 12)); path.addCurve(to: p(6, 14), control1: p(5, 12), control2: p(6, 13)); path.addLine(to: p(6, 16)); path.addCurve(to: p(9, 21), control1: p(6, 19), control2: p(6, 21)); path.move(to: p(15, 3)); path.addCurve(to: p(18, 8), control1: p(18, 3), control2: p(18, 5)); path.addLine(to: p(18, 10)); path.addCurve(to: p(20, 12), control1: p(18, 11), control2: p(19, 12)); path.addCurve(to: p(18, 14), control1: p(19, 12), control2: p(18, 13)); path.addLine(to: p(18, 16)); path.addCurve(to: p(15, 21), control1: p(18, 19), control2: p(18, 21))
        case .image:
            path.addRoundedRect(in: CGRect(x: 3 * s, y: 4 * s, width: 18 * s, height: 16 * s), cornerSize: CGSize(width: 2 * s, height: 2 * s)); path.addEllipse(in: CGRect(x: 7 * s, y: 8 * s, width: 3 * s, height: 3 * s)); path.move(to: p(3, 17)); path.addLine(to: p(9, 12)); path.addLine(to: p(13, 16)); path.addLine(to: p(16, 13)); path.addLine(to: p(21, 17))
        case .sun:
            path.addEllipse(in: CGRect(x: 8 * s, y: 8 * s, width: 8 * s, height: 8 * s)); for angle in stride(from: 0.0, to: Double.pi * 2, by: Double.pi / 4) { path.move(to: p(12 + CGFloat(cos(angle)) * 8, 12 + CGFloat(sin(angle)) * 8)); path.addLine(to: p(12 + CGFloat(cos(angle)) * 10, 12 + CGFloat(sin(angle)) * 10)) }
        case .inbox:
            path.move(to: p(4, 5)); path.addLine(to: p(20, 5)); path.addLine(to: p(22, 17)); path.addLine(to: p(2, 17)); path.closeSubpath(); path.move(to: p(2, 17)); path.addCurve(to: p(7, 20), control1: p(3, 20), control2: p(5, 20)); path.addLine(to: p(17, 20)); path.addCurve(to: p(22, 17), control1: p(19, 20), control2: p(21, 20))
        case .kanban:
            path.addRect(CGRect(x: 3 * s, y: 4 * s, width: 5 * s, height: 7 * s)); path.addRect(CGRect(x: 3 * s, y: 14 * s, width: 5 * s, height: 6 * s)); path.addRect(CGRect(x: 11 * s, y: 4 * s, width: 10 * s, height: 16 * s))
        case .gauge:
            path.move(to: p(3, 15)); path.addCurve(to: p(21, 15), control1: p(5, 3), control2: p(19, 3)); path.move(to: p(5, 19)); path.addLine(to: p(19, 19)); path.move(to: p(12, 15)); path.addLine(to: p(16, 9)); path.addEllipse(in: CGRect(x: 10 * s, y: 13 * s, width: 4 * s, height: 4 * s))
        case .clock:
            path.addEllipse(in: CGRect(x: 3 * s, y: 3 * s, width: 18 * s, height: 18 * s)); path.move(to: p(12, 7)); path.addLine(to: p(12, 12)); path.addLine(to: p(16, 14))
        case .activity:
            path.move(to: p(3, 12)); path.addLine(to: p(7, 12)); path.addLine(to: p(10, 5)); path.addLine(to: p(14, 19)); path.addLine(to: p(17, 12)); path.addLine(to: p(21, 12))
        case .audioLines:
            path.move(to: p(4, 10)); path.addLine(to: p(4, 14)); path.move(to: p(8, 6)); path.addLine(to: p(8, 18)); path.move(to: p(12, 3)); path.addLine(to: p(12, 21)); path.move(to: p(16, 6)); path.addLine(to: p(16, 18)); path.move(to: p(20, 10)); path.addLine(to: p(20, 14))
        case .bot:
            path.addRoundedRect(in: CGRect(x: 5 * s, y: 7 * s, width: 14 * s, height: 12 * s), cornerSize: CGSize(width: 3 * s, height: 3 * s)); path.move(to: p(12, 7)); path.addLine(to: p(12, 3)); path.move(to: p(9, 3)); path.addLine(to: p(15, 3)); path.addEllipse(in: CGRect(x: 9 * s, y: 11 * s, width: 2 * s, height: 2 * s)); path.addEllipse(in: CGRect(x: 13 * s, y: 11 * s, width: 2 * s, height: 2 * s)); path.move(to: p(2, 11)); path.addLine(to: p(5, 11)); path.move(to: p(19, 11)); path.addLine(to: p(22, 11))
        case .fileSearch:
            path.move(to: p(6, 2)); path.addLine(to: p(16, 2)); path.addLine(to: p(20, 6)); path.addLine(to: p(20, 15)); path.move(to: p(6, 2)); path.addLine(to: p(6, 22)); path.addLine(to: p(13, 22)); path.addEllipse(in: CGRect(x: 12 * s, y: 12 * s, width: 7 * s, height: 7 * s)); path.move(to: p(18, 18)); path.addLine(to: p(21, 21))
        case .users:
            path.addEllipse(in: CGRect(x: 4 * s, y: 4 * s, width: 6 * s, height: 6 * s)); path.addEllipse(in: CGRect(x: 14 * s, y: 4 * s, width: 6 * s, height: 6 * s)); path.addArc(center: p(7, 18), radius: 5 * s, startAngle: .degrees(200), endAngle: .degrees(-20), clockwise: false); path.addArc(center: p(17, 18), radius: 5 * s, startAngle: .degrees(200), endAngle: .degrees(-20), clockwise: false)
        case .folder:
            path.move(to: p(3, 6)); path.addLine(to: p(10, 6)); path.addLine(to: p(12, 8)); path.addLine(to: p(21, 8)); path.addLine(to: p(21, 20)); path.addLine(to: p(3, 20)); path.closeSubpath()
        case .messages:
            path.move(to: p(7, 5)); path.addLine(to: p(16, 5)); path.addCurve(to: p(18, 7), control1: p(18, 5), control2: p(18, 6)); path.addLine(to: p(18, 13)); path.addCurve(to: p(16, 15), control1: p(18, 14), control2: p(17, 15)); path.addLine(to: p(9, 15)); path.addLine(to: p(5, 18)); path.addLine(to: p(6, 15)); path.addCurve(to: p(4, 13), control1: p(4, 15), control2: p(4, 14)); path.addLine(to: p(4, 7)); path.addCurve(to: p(7, 5), control1: p(4, 5), control2: p(5, 5)); path.move(to: p(11, 9)); path.addLine(to: p(19, 9)); path.addCurve(to: p(21, 11), control1: p(21, 9), control2: p(21, 10)); path.addLine(to: p(21, 17)); path.addCurve(to: p(19, 19), control1: p(21, 18), control2: p(20, 19)); path.addLine(to: p(14, 19)); path.addLine(to: p(11, 21)); path.addLine(to: p(12, 19)); path.addLine(to: p(11, 19))
        case .panelOpen:
            // Lucide `panel-right`: the right-hand pane is visible.
            path.addRoundedRect(in: CGRect(x: 3 * s, y: 3 * s, width: 18 * s, height: 18 * s), cornerSize: CGSize(width: 2 * s, height: 2 * s)); path.move(to: p(15, 3)); path.addLine(to: p(15, 21))
        case .panelClosed:
            // Lucide `panel-right-open`: indicate that the pane can expand.
            path.addRoundedRect(in: CGRect(x: 3 * s, y: 3 * s, width: 18 * s, height: 18 * s), cornerSize: CGSize(width: 2 * s, height: 2 * s)); path.move(to: p(15, 3)); path.addLine(to: p(15, 21)); path.move(to: p(11, 9)); path.addLine(to: p(8, 12)); path.addLine(to: p(11, 15))
        case .settings:
            let gearPoints = (0..<24).map { index -> CGPoint in let angle = Double(index) * Double.pi / 12; let radius: CGFloat = index.isMultiple(of: 3) ? 10 : (index % 3 == 1 ? 8.5 : 8); return p(12 + CGFloat(cos(angle)) * radius, 12 + CGFloat(sin(angle)) * radius) }
            path.move(to: gearPoints[0]); for point in gearPoints.dropFirst() { path.addLine(to: point) }; path.closeSubpath(); path.addEllipse(in: CGRect(x: 9 * s, y: 9 * s, width: 6 * s, height: 6 * s))
        case .chevronDown:
            path.move(to: p(6, 9)); path.addLine(to: p(12, 15)); path.addLine(to: p(18, 9))
        case .chevronUp:
            path.move(to: p(6, 15)); path.addLine(to: p(12, 9)); path.addLine(to: p(18, 15))
        case .chevronRight:
            path.move(to: p(9, 6)); path.addLine(to: p(15, 12)); path.addLine(to: p(9, 18))
        case .chevronLeft:
            path.move(to: p(15, 6)); path.addLine(to: p(9, 12)); path.addLine(to: p(15, 18))
        case .arrowDownUp:
            path.move(to: p(7, 3)); path.addLine(to: p(7, 21)); path.move(to: p(3, 7)); path.addLine(to: p(7, 3)); path.addLine(to: p(11, 7)); path.move(to: p(17, 21)); path.addLine(to: p(17, 3)); path.move(to: p(13, 17)); path.addLine(to: p(17, 21)); path.addLine(to: p(21, 17))
        case .fileDiff:
            path.move(to: p(14, 2)); path.addLine(to: p(20, 8)); path.addLine(to: p(20, 22)); path.addLine(to: p(4, 22)); path.addLine(to: p(4, 2)); path.closeSubpath(); path.move(to: p(14, 2)); path.addLine(to: p(14, 8)); path.addLine(to: p(20, 8)); path.move(to: p(8, 13)); path.addLine(to: p(12, 13)); path.move(to: p(10, 11)); path.addLine(to: p(10, 15)); path.move(to: p(15, 13)); path.addLine(to: p(17, 13))
        case .plus:
            path.move(to: p(12, 5)); path.addLine(to: p(12, 19)); path.move(to: p(5, 12)); path.addLine(to: p(19, 12))
        case .ellipsis:
            path.addEllipse(in: CGRect(x: 4 * s, y: 10 * s, width: 4 * s, height: 4 * s)); path.addEllipse(in: CGRect(x: 10 * s, y: 10 * s, width: 4 * s, height: 4 * s)); path.addEllipse(in: CGRect(x: 16 * s, y: 10 * s, width: 4 * s, height: 4 * s))
        case .circle:
            path.addEllipse(in: CGRect(x: 4 * s, y: 4 * s, width: 16 * s, height: 16 * s))
        case .triangleAlert:
            path.move(to: p(12, 3)); path.addLine(to: p(22, 20)); path.addLine(to: p(2, 20)); path.closeSubpath(); path.move(to: p(12, 9)); path.addLine(to: p(12, 14)); path.move(to: p(12, 17)); path.addLine(to: p(12, 17))
        case .trash:
            path.move(to: p(4, 7)); path.addLine(to: p(20, 7)); path.move(to: p(9, 7)); path.addLine(to: p(9, 4)); path.addCurve(to: p(11, 2), control1: p(9, 3), control2: p(10, 2)); path.addLine(to: p(13, 2)); path.addCurve(to: p(15, 4), control1: p(14, 2), control2: p(15, 3)); path.addLine(to: p(15, 7)); path.addRoundedRect(in: CGRect(x: 6 * s, y: 7 * s, width: 12 * s, height: 15 * s), cornerSize: CGSize(width: 2 * s, height: 2 * s)); path.move(to: p(10, 11)); path.addLine(to: p(10, 18)); path.move(to: p(14, 11)); path.addLine(to: p(14, 18))
        case .terminal:
            path.addRoundedRect(in: CGRect(x: 3 * s, y: 4 * s, width: 18 * s, height: 16 * s), cornerSize: CGSize(width: 2 * s, height: 2 * s)); path.move(to: p(7, 9)); path.addLine(to: p(10, 12)); path.addLine(to: p(7, 15)); path.move(to: p(13, 15)); path.addLine(to: p(17, 15))
        case .paperclip:
            path.move(to: p(21, 11)); path.addLine(to: p(12, 20)); path.addCurve(to: p(4, 12), control1: p(8, 24), control2: p(0, 16)); path.addLine(to: p(13, 3)); path.addCurve(to: p(19, 9), control1: p(16, 0), control2: p(22, 6)); path.addLine(to: p(10, 18)); path.addCurve(to: p(7, 15), control1: p(8, 20), control2: p(5, 17)); path.addLine(to: p(15, 8))
        case .mic:
            path.addRoundedRect(in: CGRect(x: 8 * s, y: 3 * s, width: 8 * s, height: 12 * s), cornerSize: CGSize(width: 4 * s, height: 4 * s)); path.move(to: p(5, 11)); path.addCurve(to: p(19, 11), control1: p(5, 20), control2: p(19, 20)); path.move(to: p(12, 20)); path.addLine(to: p(12, 23))
        case .stop:
            path.addRoundedRect(in: CGRect(x: 5 * s, y: 5 * s, width: 14 * s, height: 14 * s), cornerSize: CGSize(width: 2 * s, height: 2 * s))
        case .pause:
            path.addRoundedRect(in: CGRect(x: 6 * s, y: 4 * s, width: 4 * s, height: 16 * s), cornerSize: CGSize(width: 1 * s, height: 1 * s)); path.addRoundedRect(in: CGRect(x: 14 * s, y: 4 * s, width: 4 * s, height: 16 * s), cornerSize: CGSize(width: 1 * s, height: 1 * s))
        case .calendar:
            path.addRoundedRect(in: CGRect(x: 3 * s, y: 5 * s, width: 18 * s, height: 16 * s), cornerSize: CGSize(width: 2 * s, height: 2 * s)); path.move(to: p(3, 10)); path.addLine(to: p(21, 10)); path.move(to: p(8, 3)); path.addLine(to: p(8, 7)); path.move(to: p(16, 3)); path.addLine(to: p(16, 7))
        case .link:
            path.addRoundedRect(in: CGRect(x: 2 * s, y: 9 * s, width: 10 * s, height: 6 * s), cornerSize: CGSize(width: 3 * s, height: 3 * s)); path.addRoundedRect(in: CGRect(x: 12 * s, y: 9 * s, width: 10 * s, height: 6 * s), cornerSize: CGSize(width: 3 * s, height: 3 * s)); path.move(to: p(8, 12)); path.addLine(to: p(16, 12))
        case .externalLink:
            path.move(to: p(15, 3)); path.addLine(to: p(21, 3)); path.addLine(to: p(21, 9)); path.move(to: p(10, 14)); path.addLine(to: p(21, 3)); path.move(to: p(21, 14)); path.addLine(to: p(21, 19)); path.addCurve(to: p(19, 21), control1: p(21, 20), control2: p(20, 21)); path.addLine(to: p(5, 21)); path.addCurve(to: p(3, 19), control1: p(4, 21), control2: p(3, 20)); path.addLine(to: p(3, 5)); path.addCurve(to: p(5, 3), control1: p(3, 4), control2: p(4, 3)); path.addLine(to: p(10, 3))
        case .sliders:
            path.move(to: p(4, 7)); path.addLine(to: p(20, 7)); path.move(to: p(4, 12)); path.addLine(to: p(20, 12)); path.move(to: p(4, 17)); path.addLine(to: p(20, 17)); path.addEllipse(in: CGRect(x: 7 * s, y: 5 * s, width: 4 * s, height: 4 * s)); path.addEllipse(in: CGRect(x: 13 * s, y: 10 * s, width: 4 * s, height: 4 * s)); path.addEllipse(in: CGRect(x: 9 * s, y: 15 * s, width: 4 * s, height: 4 * s))
        case .radio:
            path.addEllipse(in: CGRect(x: 5 * s, y: 5 * s, width: 14 * s, height: 14 * s)); path.addEllipse(in: CGRect(x: 10 * s, y: 10 * s, width: 4 * s, height: 4 * s)); path.move(to: p(12, 2)); path.addLine(to: p(12, 5))
        case .cpu:
            path.addRoundedRect(in: CGRect(x: 6 * s, y: 6 * s, width: 12 * s, height: 12 * s), cornerSize: CGSize(width: 2 * s, height: 2 * s)); path.addRect(CGRect(x: 10 * s, y: 10 * s, width: 4 * s, height: 4 * s)); for value in [8.0, 12.0, 16.0] { path.move(to: p(value, 2)); path.addLine(to: p(value, 6)); path.move(to: p(value, 18)); path.addLine(to: p(value, 22)) }
        case .brain:
            path.addArc(center: p(9, 10), radius: 5 * s, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false); path.addArc(center: p(15, 10), radius: 5 * s, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false); path.move(to: p(12, 5)); path.addLine(to: p(12, 19)); path.addLine(to: p(8, 19)); path.move(to: p(12, 12)); path.addLine(to: p(17, 12))
        case .flame:
            path.move(to: p(12, 2)); path.addCurve(to: p(6, 13), control1: p(7, 6), control2: p(4, 8)); path.addCurve(to: p(12, 22), control1: p(4, 20), control2: p(20, 23)); path.addCurve(to: p(18, 12), control1: p(20, 18), control2: p(16, 16)); path.addCurve(to: p(12, 2), control1: p(15, 8), control2: p(13, 5))
        case .eye:
            path.addEllipse(in: CGRect(x: 2 * s, y: 6 * s, width: 20 * s, height: 12 * s)); path.addEllipse(in: CGRect(x: 9 * s, y: 9 * s, width: 6 * s, height: 6 * s))
        case .download:
            path.move(to: p(12, 3)); path.addLine(to: p(12, 16)); path.move(to: p(7, 11)); path.addLine(to: p(12, 16)); path.addLine(to: p(17, 11)); path.move(to: p(4, 20)); path.addLine(to: p(20, 20))
        case .upload:
            path.move(to: p(12, 21)); path.addLine(to: p(12, 8)); path.move(to: p(7, 13)); path.addLine(to: p(12, 8)); path.addLine(to: p(17, 13)); path.move(to: p(4, 4)); path.addLine(to: p(20, 4))
        case .expand:
            path.move(to: p(9, 3)); path.addLine(to: p(3, 3)); path.addLine(to: p(3, 9)); path.move(to: p(15, 3)); path.addLine(to: p(21, 3)); path.addLine(to: p(21, 9)); path.move(to: p(3, 15)); path.addLine(to: p(3, 21)); path.addLine(to: p(9, 21)); path.move(to: p(15, 21)); path.addLine(to: p(21, 21)); path.addLine(to: p(21, 15))
        case .minimize:
            path.move(to: p(3, 9)); path.addLine(to: p(9, 9)); path.addLine(to: p(9, 3)); path.move(to: p(15, 3)); path.addLine(to: p(15, 9)); path.addLine(to: p(21, 9)); path.move(to: p(3, 15)); path.addLine(to: p(9, 15)); path.addLine(to: p(9, 21)); path.move(to: p(15, 21)); path.addLine(to: p(15, 15)); path.addLine(to: p(21, 15))
        case .user:
            path.addEllipse(in: CGRect(x: 8 * s, y: 3 * s, width: 8 * s, height: 8 * s)); path.addArc(center: p(12, 21), radius: 8 * s, startAngle: .degrees(200), endAngle: .degrees(-20), clockwise: false)
        case .messageCircle:
            path.addRoundedRect(in: CGRect(x: 3 * s, y: 4 * s, width: 18 * s, height: 15 * s), cornerSize: CGSize(width: 3 * s, height: 3 * s)); path.move(to: p(8, 19)); path.addLine(to: p(8, 22)); path.addLine(to: p(12, 19))
        case .messageCirclePlus:
            path.addRoundedRect(in: CGRect(x: 3 * s, y: 4 * s, width: 18 * s, height: 15 * s), cornerSize: CGSize(width: 3 * s, height: 3 * s)); path.move(to: p(8, 19)); path.addLine(to: p(8, 22)); path.addLine(to: p(12, 19)); path.move(to: p(12, 9)); path.addLine(to: p(12, 15)); path.move(to: p(9, 12)); path.addLine(to: p(15, 12))
        case .fullscreen:
            path.move(to: p(9, 3)); path.addLine(to: p(3, 3)); path.addLine(to: p(3, 9)); path.move(to: p(15, 3)); path.addLine(to: p(21, 3)); path.addLine(to: p(21, 9)); path.move(to: p(3, 15)); path.addLine(to: p(3, 21)); path.addLine(to: p(9, 21)); path.move(to: p(15, 21)); path.addLine(to: p(21, 21)); path.addLine(to: p(21, 15))
        case .sparkles:
            path.addEllipse(in: CGRect(x: 10 * s, y: 3 * s, width: 4 * s, height: 4 * s)); path.move(to: p(12, 1)); path.addLine(to: p(12, 9)); path.move(to: p(8, 5)); path.addLine(to: p(16, 5)); path.addEllipse(in: CGRect(x: 3 * s, y: 14 * s, width: 3 * s, height: 3 * s)); path.move(to: p(4.5, 12)); path.addLine(to: p(4.5, 19)); path.move(to: p(1, 15.5)); path.addLine(to: p(8, 15.5))
        }
        return path
    }
}

/// Git pull-request glyph with Lucide's connected-points geometry.
struct PullRequestBranchIcon: View {
    enum Status { case success, failure, draft, neutral }
    let status: Status
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LucideIcon(name: .gitPullRequest, size: 17, color: iconColor)
            if status == .success || status == .failure {
                Circle().fill(status == .success ? Color.dockSuccess : Color.dockDestructive).frame(width: 6, height: 6).overlay(Circle().stroke(Color.dockSurface2, lineWidth: 1.1)).offset(x: 1, y: 1)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private var iconColor: Color {
        switch status {
        case .success: return Color.dockSuccess
        case .failure: return Color.dockDestructive
        case .draft: return Color.dockMetadataText
        case .neutral: return Color.dockSecondaryText
        }
    }
}

struct PullRequestRecord: Identifiable, Equatable {
    let repository: GitHubRepositoryReference
    let localPath: String
    let number: Int
    var title: String
    var body: String
    var author: String
    var authorAvatarURL: URL?
    var headBranch: String
    var baseBranch: String
    var updatedAt: Date?
    var isDraft: Bool
    var webURL: URL?
    var requestedReviewers: [String]
    var comments: Int
    var additions: Int?
    var deletions: Int?
    var changedFiles: Int?
    var checks: [GitHubCheckSummary]
    var reviews: [GitHubReviewSummary]
    var id: String { "github:\(repository.id)#\(number)" }
    /// PR identifiers are not quantities: never localize them with grouping
    /// separators (for example, render `4878`, never `4,878`).
    var displayNumber: String { String(number) }

    var readinessLabel: String {
        if isDraft { return "DRAFT" }
        if checks.contains(where: { $0.conclusion?.lowercased() == "failure" }) { return "CHECKS FAILED" }
        if checks.contains(where: { $0.status.lowercased() != "completed" }) { return "CHECKS RUNNING" }
        return checks.isEmpty ? "OPEN" : "READY"
    }
}

struct PullRequestCenterFailure: Error { let repository: String }

@MainActor
final class PullRequestCenterModel: ObservableObject {
    private let mutationExecutor: any PullRequestMutationExecuting
    @Published private(set) var records: [PullRequestRecord] = []
    @Published private(set) var filesByID: [String: [PullRequestFile]] = [:]
    @Published private(set) var commentsByID: [String: [PullRequestComment]] = [:]
    @Published private(set) var commitsByID: [String: [PullRequestCommit]] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var loadingDetailIDs = Set<String>()
    @Published private(set) var isPostingComment = false
    @Published private(set) var isUpdatingStatus = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var failedRepositories: [String] = []
    @Published private(set) var viewerLogin: String?
    @Published var filter: PullRequestFilter = .all
    @Published var query = ""
    @Published var selectedID: String?
    private var generation = UUID()

    init(mutationExecutor: any PullRequestMutationExecuting = PullRequestCenterAPI()) {
        self.mutationExecutor = mutationExecutor
    }

    var isLoadingDetail: Bool { !loadingDetailIDs.isEmpty }
    var selected: PullRequestRecord? { records.first { $0.id == selectedID } }
    var isInitialLoad: Bool { isRefreshing && records.isEmpty }

    @discardableResult
    func beginDetailLoad(for id: String) -> Bool {
        guard !id.isEmpty, !loadingDetailIDs.contains(id) else { return false }
        loadingDetailIDs.insert(id)
        return true
    }

    func finishDetailLoad(for id: String) {
        loadingDetailIDs.remove(id)
    }
    var visible: [PullRequestRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { item in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .authored: matchesFilter = viewerLogin.map { item.author.caseInsensitiveCompare($0) == .orderedSame } ?? false
            case .reviewing: matchesFilter = viewerLogin.map { login in item.requestedReviewers.contains { $0.caseInsensitiveCompare(login) == .orderedSame } } ?? false
            }
            guard matchesFilter else { return false }
            guard !needle.isEmpty else { return true }
            return [item.title, item.repository.id, item.author, item.headBranch, item.baseBranch, "#\(item.number)"].joined(separator: " ").lowercased().contains(needle)
        }
    }

    func refresh(projects: [ProjectSummary]) async {
        let paths = Array(Set(projects.filter(\.isRenderableProject).map(\.name))).filter { !$0.isEmpty }
        let token = UUID(); generation = token; isRefreshing = true; errorMessage = nil; failedRepositories = []
        let remotes = await withTaskGroup(of: (String, GitHubRepositoryReference?).self, returning: [(String, GitHubRepositoryReference)].self) { group in
            for path in paths { group.addTask { (path, await RepositoryService.githubRemote(path: path)) } }
            var unique: [String: (String, GitHubRepositoryReference)] = [:]
            for await (path, remote) in group where remote != nil { if let remote, unique[remote.id] == nil { unique[remote.id] = (path, remote) } }
            return Array(unique.values)
        }
        guard token == generation else { return }
        let api = PullRequestCenterAPI()
        let localPaths = Dictionary(uniqueKeysWithValues: remotes.map { ($0.1.id, $0.0) })
        let viewer = await api.viewer()
        viewerLogin = viewer

        // The PR center is account-scoped, rather than scoped to whichever
        // Hermes project happens to be selected. Search GitHub for authored
        // and requested-review PRs so repositories that are not attached
        // locally still appear in the workspace.
        if let viewer {
            let global = await api.searchPullRequests(viewerLogin: viewer, localPaths: localPaths)
            guard token == generation else { return }
            switch global {
            case .success(let rows):
                // GitHub search items omit head/base refs. Resolve those
                // details in bounded batches so the list does not show
                // "unknown" until a row is clicked.
                let enriched = await api.enrichIndex(rows)
                guard token == generation else { return }
                records = enriched.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                filesByID = [:]; commentsByID = [:]; commitsByID = [:]
                failedRepositories = []
                errorMessage = nil
                isRefreshing = false
                repairSelection()
                return
            case .failure:
                // Keep the attached-repository path as a useful fallback if
                // GitHub search is temporarily rate-limited or unavailable.
                errorMessage = "GitHub account search failed. Showing attached repositories."
            }
        } else if remotes.isEmpty {
            records = []
            selectedID = nil
            errorMessage = paths.isEmpty ? "No Hermes projects are attached and GitHub sign-in is unavailable." : "GitHub sign-in is required to load your pull requests."
            isRefreshing = false
            return
        }

        guard !remotes.isEmpty else {
            records = []
            selectedID = nil
            errorMessage = "No attached repositories were available and GitHub account search failed."
            isRefreshing = false
            return
        }
        let results = await withTaskGroup(of: Result<[PullRequestRecord], PullRequestCenterFailure>.self, returning: [Result<[PullRequestRecord], PullRequestCenterFailure>].self) { group in
            for (path, remote) in remotes {
                group.addTask { await api.index(repository: remote, localPath: path) }
            }
            var output: [Result<[PullRequestRecord], PullRequestCenterFailure>] = []
            for await result in group { output.append(result) }
            return output
        }
        guard token == generation else { return }
        var fresh: [PullRequestRecord] = []
        var failures: [String] = []
        for result in results {
            switch result { case .success(let rows): fresh += rows; case .failure(let failure): failures.append(failure.repository) }
        }
        if !fresh.isEmpty { records = fresh.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }; filesByID = [:]; commentsByID = [:]; commitsByID = [:] }
        failedRepositories = failures
        if fresh.isEmpty && !failures.isEmpty { errorMessage = "GitHub could not load pull requests. Check your GitHub sign-in or try again." }
        isRefreshing = false
        repairSelection()
    }

    /// Session-scoped refresh: loads only the pull requests of one local
    /// repository path, without the account-wide GitHub search that the
    /// pull-request workspace performs.
    func refreshScoped(repositoryPath: String) async {
        let token = UUID(); generation = token; isRefreshing = true; errorMessage = nil; failedRepositories = []
        let remote = await RepositoryService.githubRemote(path: repositoryPath)
        guard token == generation else { return }
        guard let remote else {
            records = []
            selectedID = nil
            filesByID = [:]; commentsByID = [:]; commitsByID = [:]
            errorMessage = "This session's repository has no GitHub remote."
            isRefreshing = false
            return
        }
        let api = PullRequestCenterAPI()
        let viewer = await api.viewer()
        guard token == generation else { return }
        viewerLogin = viewer
        let result = await api.index(repository: remote, localPath: repositoryPath)
        guard token == generation else { return }
        switch result {
        case .success(let rows):
            records = rows.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            filesByID = [:]; commentsByID = [:]; commitsByID = [:]
            failedRepositories = []
            errorMessage = nil
        case .failure:
            failedRepositories = [remote.id]
            if records.isEmpty { errorMessage = "GitHub could not load pull requests for \(remote.id). Check your sign-in and try again." }
        }
        isRefreshing = false
        repairSelection()
    }

    func repairSelection() { if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id } }

    func loadSelectedDetail() async {
        guard let selected,
              filesByID[selected.id] == nil
        else { return }
        guard beginDetailLoad(for: selected.id) else { return }
        defer { finishDetailLoad(for: selected.id) }
        let api = PullRequestCenterAPI()
        async let detail = api.detail(selected)
        async let files = api.files(selected)
        async let comments = api.comments(selected)
        async let commits = api.commits(selected)
        if let updated = await detail, let index = records.firstIndex(where: { $0.id == selected.id }) { records[index] = updated }
        filesByID[selected.id] = await files ?? []
        commentsByID[selected.id] = await comments ?? []
        commitsByID[selected.id] = await commits ?? []
    }

    func refreshSelectedDetail() async {
        guard let selected else { return }
        filesByID[selected.id] = nil
        commentsByID[selected.id] = nil
        commitsByID[selected.id] = nil
        await loadSelectedDetail()
    }

    func addComment(_ body: String, to record: PullRequestRecord) async -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 10_000, !isPostingComment else { return false }
        isPostingComment = true
        defer { isPostingComment = false }
        guard let comment = await mutationExecutor.postComment(trimmed, on: record) else {
            errorMessage = "GitHub could not add the comment. Check your sign-in and try again."
            return false
        }
        commentsByID[record.id, default: []].append(comment)
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index].comments += 1 }
        return true
    }

    func updateStatus(_ status: PullRequestStatus, for record: PullRequestRecord) async -> Bool {
        guard !isUpdatingStatus else { return false }
        if status == .draft {
            // GitHub's REST API exposes the Draft → Ready transition, but
            // does not provide a REST endpoint to return a ready PR to Draft.
            return record.isDraft
        }
        isUpdatingStatus = true
        defer { isUpdatingStatus = false }
        guard let updated = await mutationExecutor.updateStatus(status, for: record) else {
            errorMessage = "GitHub could not update this pull request status. Check your sign-in and try again."
            return false
        }
        if status == .closed {
            records.removeAll { $0.id == record.id }
            filesByID[record.id] = nil
            commentsByID[record.id] = nil
            commitsByID[record.id] = nil
            repairSelection()
        } else if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = updated
        }
        return true
    }
}

/// A mutation intent is inert until the detail surface explicitly confirms it.
/// No GitHub write should be reachable from a row/menu action directly.
enum PullRequestMutationRequest: Identifiable, Equatable {
    case comment(record: PullRequestRecord, body: String)
    case status(record: PullRequestRecord, status: PullRequestStatus)

    var id: String {
        switch self {
        case let .comment(record, body): return "comment:\(record.id):\(body)"
        case let .status(record, status): return "status:\(record.id):\(status.rawValue)"
        }
    }
}

@MainActor
final class PullRequestMutationCoordinator: ObservableObject {
    @Published private(set) var pending: PullRequestMutationRequest?

    func requestComment(_ body: String, for record: PullRequestRecord) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pending = .comment(record: record, body: trimmed)
    }

    func requestStatus(_ status: PullRequestStatus, for record: PullRequestRecord) {
        pending = .status(record: record, status: status)
    }

    func cancel() {
        pending = nil
    }

    func confirm(using center: PullRequestCenterModel) async -> Bool {
        guard let pending else { return false }
        defer { self.pending = nil }
        switch pending {
        case let .comment(record, body):
            return await center.addComment(body, to: record)
        case let .status(record, status):
            return await center.updateStatus(status, for: record)
        }
    }
}

struct PullRequestRowView: View {
    let pullRequest: PullRequestRecord
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 9) {
                PullRequestBranchIcon(status: iconStatus).padding(.top, -1)
                Text("#\(pullRequest.displayNumber)  \(pullRequest.title)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(2)
            }
            Text("\(pullRequest.repository.id) · \(pullRequest.headBranch)")
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
            HStack {
                Text(pullRequest.readinessLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(pullRequest.isDraft ? Color.dockMetadataText : Color.dockAccent)
                Spacer()
                if let adds = pullRequest.additions, let dels = pullRequest.deletions {
                    HStack(spacing: 8) {
                        Text("+\(adds)").foregroundStyle(Color.dockSuccess)
                        Text("−\(dels)").foregroundStyle(Color.dockDestructive)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isSelected ? Color.dockAccent.opacity(0.16) : Color.clear))
        .contentShape(Rectangle())
    }

    private var iconStatus: PullRequestBranchIcon.Status {
        guard !pullRequest.isDraft else { return .draft }
        if pullRequest.checks.contains(where: { $0.conclusion?.lowercased() == "failure" }) { return .failure }
        return .success
    }
}

private struct PullRequestShimmerBlock: View {
    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat
    let pulse: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.dockSurface4.opacity(pulse ? 0.55 : 0.28))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

struct PullRequestFilterTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .foregroundStyle(isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? Color.dockAccent : Color.dockCanvas))
        }
        .buttonStyle(.plain)
    }
}

struct PullRequestDiffLineView: View {
    let line: PullRequestDiffLine
    var counterpart: String? = nil
    var wordDiffsEnabled = false

    var body: some View {
        let tint: Color = line.kind == .addition ? .dockSuccess : (line.kind == .deletion ? .dockDestructive : (line.kind == .hunk ? .dockAccent : .dockSecondaryText))
        let fill: Color = line.kind == .addition ? Color.dockSuccess.opacity(0.13) : (line.kind == .deletion ? Color.dockDestructive.opacity(0.13) : (line.kind == .hunk ? Color.dockAccent.opacity(0.08) : Color.dockSurface2))
        let content = (line.kind == .addition || line.kind == .deletion) ? String(line.text.dropFirst()) : line.text
        let counterpartContent = counterpart.map { value in
            guard let first = value.first, first == "+" || first == "-" else { return value }
            return String(value.dropFirst())
        }
        HStack(spacing: 0) {
            if line.kind == .addition || line.kind == .deletion { Text(String(line.text.prefix(1))).foregroundStyle(tint).fontWeight(.bold) }
            diffWords(content, counterpart: counterpartContent, tint: tint)
        }
        .frame(maxWidth: .infinity, minHeight: 19, alignment: .leading)
        .padding(.horizontal, 10)
        .background(fill)
        .overlay(alignment: .leading) { if line.kind != .context { tint.frame(width: 2) } }
    }

    @ViewBuilder
    private func diffWords(_ content: String, counterpart: String?, tint: Color) -> some View {
        if wordDiffsEnabled, let counterpart, content.count < 500 {
            let otherWords = Set(counterpart.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init))
            let words = content.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            HStack(spacing: 0) {
                ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                    Text(word)
                        .foregroundStyle(Color.dockSecondaryText)
                        .background(otherWords.contains(word.trimmingCharacters(in: .whitespacesAndNewlines)) ? Color.clear : tint.opacity(0.28))
                    if word != words.last { Text(" ") }
                }
            }
        } else {
            Text(content).foregroundStyle(Color.dockSecondaryText)
        }
    }
}

struct PullRequestDetailView: View {
    @ObservedObject var center: PullRequestCenterModel
    let onOpenChat: (PullRequestRecord) -> Void

    @State private var detailTab = 0
    @StateObject private var reviewPreferences = PullRequestReviewPreferenceStore()
    @State private var selectedFileID: String?
    @State private var sourceDiffFileIDs: Set<String> = []
    @State private var descriptionExpanded = false
    @State private var checksExpanded = true
    @State private var activityExpanded = true
    @State private var commentDraft = ""
    @StateObject private var diffPresentationCache = PullRequestDiffPresentationCache()
    @StateObject private var mutationCoordinator = PullRequestMutationCoordinator()

    private var isLoadingSelectedDetail: Bool {
        guard let selected = center.selected else { return false }
        return center.isLoadingDetail && center.filesByID[selected.id] == nil
    }

    var body: some View {
        detailPane
            .task(id: center.selectedID) {
                guard center.selectedID != nil else { return }
                await center.loadSelectedDetail()
            }
            .onChange(of: center.selectedID) { _, _ in
                selectedFileID = nil
                sourceDiffFileIDs.removeAll()
                diffPresentationCache.removeAll()
                descriptionExpanded = false
                checksExpanded = true
                activityExpanded = true
                commentDraft = ""
                mutationCoordinator.cancel()
            }
            .confirmationDialog(
                "Confirm GitHub change?",
                isPresented: Binding(
                    get: { mutationCoordinator.pending != nil },
                    set: { if !$0 { mutationCoordinator.cancel() } }
                ),
                presenting: mutationCoordinator.pending
            ) { request in
                switch request {
                case .comment:
                    Button("Post comment") {
                        Task {
                            if await mutationCoordinator.confirm(using: center) { commentDraft = "" }
                        }
                    }
                case let .status(_, status):
                    Button(status == .closed ? "Close pull request" : "Mark ready for review", role: status == .closed ? .destructive : nil) {
                        Task { _ = await mutationCoordinator.confirm(using: center) }
                    }
                }
                Button("Cancel", role: .cancel) { mutationCoordinator.cancel() }
            } message: { request in
                mutationConfirmationMessage(request)
            }
    }

    private func mutationConfirmationMessage(_ request: PullRequestMutationRequest) -> Text {
        switch request {
        case let .comment(record, body):
            return Text("Post this comment to \(record.repository.id) pull request #\(record.number)?\n\n\(body)")
        case let .status(record, status):
            if status == .closed {
                return Text("This will close pull request #\(record.number) in \(record.repository.id).")
            }
            return Text("This will mark pull request #\(record.number) in \(record.repository.id) ready for review.")
        }
    }

    @ViewBuilder private var detailPane: some View {
        if center.isInitialLoad || isLoadingSelectedDetail {
            detailLoadingPane
        } else if let pr = center.selected { VStack(alignment: .leading, spacing: 0) {
        detailHeader(pr)
        if detailTab == 0 {
            ScrollView { summary(pr).padding(.horizontal, 24) }
        } else {
            code(pr).padding(.horizontal, 16)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else { VStack(spacing: 12) { LucideIcon(name: .gitPullRequest, size: 28); Text(center.isRefreshing ? "Loading pull requests…" : "Select a pull request").font(.system(size: 15, weight: .medium)) }.foregroundStyle(Color.dockMetadataText).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private var detailLoadingPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PullRequestShimmerBlock(width: 72, height: 22, cornerRadius: 7, pulse: false)
                PullRequestShimmerBlock(width: 48, height: 22, cornerRadius: 7, pulse: false)
                Spacer()
                PullRequestShimmerBlock(width: 114, height: 30, cornerRadius: 8, pulse: false)
            }
            .padding(.horizontal, 24)
            .frame(height: 56)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading pull request")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    PullRequestShimmerBlock(width: nil, height: 28, cornerRadius: 7, pulse: false)
                    PullRequestShimmerBlock(width: 390, height: 28, cornerRadius: 7, pulse: false)
                    HStack(spacing: 10) {
                        PullRequestShimmerBlock(width: 32, height: 32, cornerRadius: 16, pulse: false)
                        PullRequestShimmerBlock(width: 126, height: 12, cornerRadius: 4, pulse: false)
                    }
                    PullRequestShimmerBlock(width: nil, height: 1, cornerRadius: 0, pulse: false)
                    ForEach(0..<5, id: \.self) { index in
                        HStack(spacing: 14) {
                            PullRequestShimmerBlock(width: 88, height: 11, cornerRadius: 4, pulse: false)
                            PullRequestShimmerBlock(width: index.isMultiple(of: 2) ? 236 : 176, height: 11, cornerRadius: 4, pulse: false)
                        }
                    }
                    PullRequestShimmerBlock(width: nil, height: 1, cornerRadius: 0, pulse: false)
                    PullRequestShimmerBlock(width: 112, height: 15, cornerRadius: 5, pulse: false)
                    PullRequestShimmerBlock(width: nil, height: 82, cornerRadius: 10, pulse: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading pull request")
    }

    private func detailHeader(_ pr: PullRequestRecord) -> some View {
        let fileIDs = Set((center.filesByID[pr.id] ?? []).map(\.id))
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                detailTabButton("Summary", selected: detailTab == 0) { detailTab = 0 }
                detailTabButton("Code", selected: detailTab == 1) { detailTab = 1 }
                Spacer()
                HStack(spacing: 6) {
                    if let url = pr.webURL {
                        Link(destination: url) {
                            PullRequestReviewToolbarIcon(name: .externalLink, accessibilityLabel: "Open on GitHub")
                        }
                        .buttonStyle(.plain)
                        .help("Open on GitHub")
                        Divider().frame(height: 16)
                    }
                    Button("Open chat") { onOpenChat(pr) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.dockSurface4))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            if detailTab == 1 {
                HStack(spacing: 10) {
                    Text(pr.headBranch)
                        .lineLimit(1)
                    LucideIcon(name: .arrowRight, size: 14, color: Color.dockMetadataText)
                    Text(pr.baseBranch)
                        .lineLimit(1)
                    Spacer(minLength: 16)
                    codeToolbar(fileIDs: fileIDs)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.dockMetadataText)
                .padding(.horizontal, 16)
                .frame(height: 62)
                .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
            }
        }
        .background(Color.dockCanvas)
    }
    private func summary(_ pr: PullRequestRecord) -> some View { VStack(alignment: .leading, spacing: 0) {
        Text(pr.title)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(Color.dockPrimaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 26)

        HStack(spacing: 10) {
            authorAvatar(pr)
            Text(pr.author).font(.system(size: 13, weight: .medium))
            if let updatedAt = pr.updatedAt {
                Text("•")
                Text(pullRequestAge(updatedAt))
            }
        }
        .foregroundStyle(Color.dockMetadataText)
        .padding(.top, 13)
        .padding(.bottom, 30)

        VStack(alignment: .leading, spacing: 15) {
            summaryDetailRow(icon: .gitBranch, title: "Branch") {
                HStack(spacing: 9) {
                    Text(pr.headBranch).lineLimit(1).layoutPriority(1)
                    LucideIcon(name: .arrowRight, size: 15, color: Color.dockMetadataText)
                    Text(pr.baseBranch).lineLimit(1).layoutPriority(1)
                    if let additions = pr.additions { Text("+\(additions)").foregroundStyle(Color.dockSuccess).fixedSize(horizontal: true, vertical: false) }
                    if let deletions = pr.deletions { Text("−\(deletions)").foregroundStyle(Color.dockDestructive).fixedSize(horizontal: true, vertical: false) }
                }
            }
            summaryDetailRow(icon: .users, title: "Reviewers") {
                Text(pr.requestedReviewers.isEmpty ? "No reviewers requested" : pr.requestedReviewers.joined(separator: ", "))
            }
            summaryDetailRow(icon: .messages, title: "Comments") {
                Text(pr.comments == 0 ? "No comments" : "\(pr.comments) comment\(pr.comments == 1 ? "" : "s")")
            }
            summaryDetailRow(icon: .checkCircle, title: "Checks", color: checksColor(for: pr)) {
                Text(checksLabel(for: pr))
                    .foregroundStyle(checksColor(for: pr))
            }
            summaryDetailRow(icon: .gitPullRequest, title: "Status") {
                statusPicker(pr)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.dockSecondaryText)

        summarySectionHeader("Description", isExpanded: $descriptionExpanded).padding(.top, 34)
        if descriptionExpanded {
            if pr.body.isEmpty {
                Text("No description provided.").font(.system(size: 14)).foregroundStyle(Color.dockMetadataText).padding(.top, 14).padding(.bottom, 26)
            } else {
                MarkdownMessageView(markdown: pr.body).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14).padding(.bottom, 30)
            }
        }

        summarySectionHeader("Checks", isExpanded: $checksExpanded)
            .padding(.top, descriptionExpanded ? 8 : 26)
        if checksExpanded { checksSection(pr).padding(.top, 16).padding(.bottom, 30) }

        let activityCount = (center.commitsByID[pr.id] ?? []).count + (center.commentsByID[pr.id] ?? []).count + 1
        summarySectionHeader("Activity", count: activityCount, isExpanded: $activityExpanded)
        if activityExpanded {
            activitySection(pr).padding(.top, 16)
            commentComposer(pr).padding(.top, 18).padding(.bottom, 40)
        }
    }.frame(maxWidth: 720, alignment: .leading) }

    private func summarySectionHeader(_ title: String, count: Int? = nil, isExpanded: Binding<Bool>) -> some View {
        Button { isExpanded.wrappedValue.toggle() } label: {
            HStack(spacing: 9) {
                Text(title).font(.system(size: 14, weight: .medium))
                LucideIcon(name: isExpanded.wrappedValue ? .chevronDown : .chevronRight, size: 14, color: Color.dockMetadataText)
                if let count { Text("\(count)").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dockMetadataText) }
                Spacer()
            }
            .foregroundStyle(Color.dockSecondaryText)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
        .accessibilityLabel("\(isExpanded.wrappedValue ? "Collapse" : "Expand") \(title)")
    }

    @ViewBuilder
    private func checksSection(_ pr: PullRequestRecord) -> some View {
        if pr.checks.isEmpty {
            HStack(spacing: 12) {
            Text("No checks reported by GitHub.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dockMetadataText)
                Spacer()
                Button {
                    Task { await center.refreshSelectedDetail() }
                } label: {
                    LucideIcon(name: .refreshCw, size: 15, color: Color.dockSecondaryText)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(center.isLoadingDetail)
                .help("Refresh checks")
                .accessibilityLabel("Refresh checks")
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.dockSurface2))
        } else {
            VStack(spacing: 0) {
                ForEach(pr.checks) { check in
                    HStack(spacing: 13) {
                        LucideIcon(name: checkIcon(for: check), size: 14, color: checkColor(for: check))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(checkColor(for: check).opacity(0.12)))
                        if let url = check.detailsURL { Link(check.name, destination: url) } else { Text(check.name) }
                        Spacer()
                        Text(checkPresentation(for: check))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 42)
                    if check.id != pr.checks.last?.id { Divider().padding(.leading, 47) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.dockSurface2))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
        }
    }

    private func activitySection(_ pr: PullRequestRecord) -> some View {
        let commits = center.commitsByID[pr.id] ?? []
        let comments = center.commentsByID[pr.id] ?? []
        return VStack(spacing: 7) {
            ForEach(commits) { commit in
                activityRow(icon: .gitBranch, iconColor: Color.dockMetadataText, title: commit.message, trailing: String(commit.id.prefix(7)), avatarURL: commit.authorAvatarURL, age: commit.committedAt.map(pullRequestAge))
            }
            ForEach(comments) { comment in
                activityRow(icon: .messages, iconColor: Color.dockAccent, title: "\(comment.author) commented", detail: comment.body, avatarURL: comment.authorAvatarURL, age: comment.createdAt.map(pullRequestAge))
            }
            activityRow(icon: .gitPullRequest, iconColor: Color.dockSuccess, title: "\(pr.author) opened this pull request", age: pr.updatedAt.map(pullRequestAge))
        }
    }

    private func activityRow(icon: LucideIconName, iconColor: Color, title: String, detail: String? = nil, trailing: String? = nil, avatarURL: URL? = nil, age: String? = nil) -> some View {
        HStack(spacing: 10) {
            LucideIcon(name: icon, size: 14, color: iconColor)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.dockSurface4.opacity(0.55)))
            VStack(alignment: .leading, spacing: detail == nil ? 0 : 5) {
                Text(title).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText).lineLimit(2) }
            }
            Spacer(minLength: 12)
            if let trailing { Text(trailing).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.dockMetadataText) }
            if let avatarURL { AsyncImage(url: avatarURL) { phase in if let image = phase.image { image.resizable().scaledToFill() } else { avatarFallback } }.frame(width: 24, height: 24).clipShape(Circle()) }
            if let age { Text(age).foregroundStyle(Color.dockMetadataText) }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.dockSecondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.dockSurface2))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
    }

    private func commentComposer(_ pr: PullRequestRecord) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $commentDraft)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 104)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.dockSurface2))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
            if commentDraft.isEmpty {
                Text("Leave a comment")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dockMetadataText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
            HStack {
                avatarFallback
                Spacer()
                Button {
                    let draft = commentDraft
                    mutationCoordinator.requestComment(draft, for: pr)
                } label: {
                    if center.isPostingComment { ProgressView().controlSize(.small).frame(width: 34, height: 34) }
                    else { LucideIcon(name: .arrowUp, size: 17, color: commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.dockMetadataText : Color.dockPrimaryText).frame(width: 34, height: 34).background(Circle().fill(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.dockSurface4 : Color.dockAccent)) }
                }
                .buttonStyle(.plain)
                .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || center.isPostingComment)
                .help("Add comment")
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func checkIcon(for check: GitHubCheckSummary) -> LucideIconName { checkColor(for: check) == Color.dockSuccess ? .check : (checkColor(for: check) == Color.dockDestructive ? .xmark : .clock) }
    private func checkColor(for check: GitHubCheckSummary) -> Color {
        let conclusion = check.conclusion?.lowercased()
        if ["success", "neutral", "skipped"].contains(conclusion) { return Color.dockSuccess }
        if ["failure", "cancelled", "timed_out", "action_required"].contains(conclusion) { return Color.dockDestructive }
        return Color.dockWarning
    }
    private func checkPresentation(for check: GitHubCheckSummary) -> String {
        guard check.status.lowercased() == "completed" else { return "Running" }
        switch check.conclusion?.lowercased() {
        case "success": return "Passed"
        case "failure": return "Failed"
        case "cancelled": return "Cancelled"
        case "skipped", "neutral": return "Skipped"
        default: return "Completed"
        }
    }

    @ViewBuilder
    private func authorAvatar(_ pr: PullRequestRecord) -> some View {
        if let url = pr.authorAvatarURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { avatarFallback }
            }
            .frame(width: 26, height: 26)
            .clipShape(Circle())
        } else {
            avatarFallback
        }
    }
    private var avatarFallback: some View {
        LucideIcon(name: .user, size: 15, color: Color.dockMetadataText)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.dockSurface2))
    }
    private func summaryDetailRow<Content: View>(icon: LucideIconName, title: String, color: Color = Color.dockMetadataText, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 13) {
            LucideIcon(name: icon, size: 15, color: color).frame(width: 22)
            Text(title).frame(width: 120, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func statusPicker(_ pr: PullRequestRecord) -> some View {
        let current: PullRequestStatus = pr.isDraft ? .draft : .readyForReview
        return Menu {
            ForEach(PullRequestStatus.allCases) { status in
                Button {
                    mutationCoordinator.requestStatus(status, for: pr)
                } label: {
                    HStack {
                        Text(status.rawValue)
                        Spacer()
                        if status == current { LucideIcon(name: .check, size: 14, color: Color.dockSecondaryText) }
                    }
                }
                .disabled(status == .draft && !pr.isDraft)
            }
        } label: {
            HStack(spacing: 7) {
                if center.isUpdatingStatus { ProgressView().controlSize(.mini) }
                Text(current.rawValue)
                LucideIcon(name: .chevronDown, size: 15, color: Color.dockSecondaryText)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.dockSurface2))
        }
        .menuStyle(.borderlessButton)
        .disabled(center.isUpdatingStatus)
        .help("Change pull request status")
        .accessibilityLabel("Pull request status: \(current.rawValue)")
    }
    private func checksLabel(for pr: PullRequestRecord) -> String {
        if pr.checks.contains(where: { $0.conclusion?.lowercased() == "failure" }) { return "Failed" }
        if pr.checks.contains(where: { $0.status.lowercased() != "completed" }) { return "In progress" }
        return pr.checks.isEmpty ? "No checks" : "Successful"
    }
    private func checksColor(for pr: PullRequestRecord) -> Color {
        if pr.checks.contains(where: { $0.conclusion?.lowercased() == "failure" }) { return Color.dockDestructive }
        if pr.checks.contains(where: { $0.status.lowercased() != "completed" }) { return Color.dockWarning }
        return pr.checks.isEmpty ? Color.dockMetadataText : Color.dockSuccess
    }
    private func pullRequestAge(_ updatedAt: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(updatedAt))
        if seconds >= 86_400 { return "\(Int(seconds / 86_400))d" }
        if seconds >= 3_600 { return "\(Int(seconds / 3_600))h" }
        return "\(max(1, Int(seconds / 60)))m"
    }
    private func detailTabButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.dockEase(duration: 0.18)) { action() }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.dockPrimaryText : Color.dockMetadataText)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.dockSurface4 : Color.clear))
        }
        .buttonStyle(.plain)
    }
    private func code(_ pr: PullRequestRecord) -> some View {
        let files = center.filesByID[pr.id] ?? []
        return VStack(alignment: .leading, spacing: 10) {
            if files.isEmpty && center.isLoadingDetail {
                ProgressView("Loading changed files…").foregroundStyle(Color.dockMetadataText)
            } else if files.isEmpty {
                Text("No patch data is available. Open this pull request on GitHub to inspect its changes.")
                    .foregroundStyle(Color.dockMetadataText)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    if reviewPreferences.showsFileTree { fileTree(files) }
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(files) { file in
                                    fileSection(file)
                                        .id(file.id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: selectedFileID) { _, id in
                            if let id { withAnimation(.dockEase(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) } }
                        }
                    }
                }
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func codeToolbar(fileIDs: Set<String>) -> some View {
        HStack(spacing: 4) {
            Menu {
                Toggle("Enable word wrap", isOn: $reviewPreferences.wordWrap)
                Toggle("Enable rich preview", isOn: $reviewPreferences.richPreview)
                Toggle("Enable word diffs", isOn: $reviewPreferences.wordDiffs)
            } label: {
                PullRequestReviewToolbarIcon(name: .ellipsis, accessibilityLabel: "Review options", tooltip: "Review options")
            }
            .menuStyle(.borderlessButton)
            .help("Review options")

            Button {
                reviewPreferences.setAllExpanded(fileIDs)
            } label: {
                PullRequestReviewToolbarIcon(
                    name: .arrowDownUp,
                    accessibilityLabel: reviewPreferences.expandedFileIDs.isSuperset(of: fileIDs) ? "Collapse all diffs" : "Expand all diffs",
                    tooltip: reviewPreferences.expandedFileIDs.isSuperset(of: fileIDs) ? "Collapse all diffs" : "Expand all diffs"
                )
            }
            .buttonStyle(.plain)
            .help(reviewPreferences.expandedFileIDs.isSuperset(of: fileIDs) ? "Collapse all diffs" : "Expand all diffs")

            Button {
                reviewPreferences.diffMode = reviewPreferences.diffMode == .unified ? .split : .unified
            } label: {
                PullRequestReviewToolbarIcon(
                    name: .fileDiff,
                    accessibilityLabel: "Switch to \(reviewPreferences.diffMode == .unified ? "split" : "unified") diff",
                    isSelected: reviewPreferences.diffMode == .split,
                    tooltip: "Switch to \(reviewPreferences.diffMode == .unified ? "split" : "unified") diff"
                )
            }
            .buttonStyle(.plain)
            .help("Switch to \(reviewPreferences.diffMode == .unified ? "split" : "unified") diff")

            Button {
                reviewPreferences.showsFileTree.toggle()
            } label: {
                PullRequestReviewToolbarIcon(
                    name: .folder,
                    accessibilityLabel: reviewPreferences.showsFileTree ? "Hide file tree" : "Show file tree",
                    isSelected: reviewPreferences.showsFileTree,
                    tooltip: reviewPreferences.showsFileTree ? "Hide file tree" : "Show file tree"
                )
            }
            .buttonStyle(.plain)
            .help(reviewPreferences.showsFileTree ? "Hide file tree" : "Show file tree")
        }
        .frame(height: 34)
    }

    private func fileTree(_ files: [PullRequestFile]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("FILES")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                Text("\(files.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dockAccent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.dockAccent.opacity(0.12)))
                Spacer()
            }
            .foregroundStyle(Color.dockMetadataText)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Color.dockBorderLight.frame(height: 0.5)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(PullRequestFileTreeBuilder.make(files: files)) { node in
                        Button {
                            if let fileID = node.fileID {
                                selectedFileID = fileID
                                if !reviewPreferences.expandedFileIDs.contains(fileID) { reviewPreferences.toggleExpanded(fileID) }
                            }
                        } label: {
                            let appearance = fileTreeAppearance(for: node)
                            HStack(spacing: 7) {
                                LucideIcon(name: appearance.icon, size: 14, color: appearance.color)
                                    .frame(width: 16, height: 18)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(node.isDirectory ? Color.clear : appearance.color.opacity(0.10))
                                    )
                                Text(node.title).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 11, weight: node.isDirectory ? .medium : .regular, design: .monospaced))
                            .foregroundStyle(selectedFileID == node.fileID ? Color.dockPrimaryText : Color.dockSecondaryText)
                            .padding(.leading, CGFloat(node.depth * 13) + 8)
                            .padding(.trailing, 8)
                            .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
                            .background(selectedFileID == node.fileID ? Color.dockAccent.opacity(0.16) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(node.isDirectory)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: 214, alignment: .leading)
        .padding(.vertical, 10)
        .background(Color.dockSurface2.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
    }

    private func fileTreeAppearance(for node: PullRequestFileTreeNode) -> (icon: LucideIconName, color: Color) {
        guard !node.isDirectory, let path = node.fileID else { return (.folder, Color.dockSecondaryText) }
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return (.braces, Color.dockWarning)
        case "js", "jsx", "ts", "tsx", "vue", "svelte": return (.braces, Color.dockAccent)
        case "json", "yaml", "yml", "toml", "xml": return (.braces, Color.dockSuccess)
        case "md", "markdown", "mdx": return (.fileText, Color.dockAccent)
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico": return (.image, Color.dockWarning)
        case "sh", "zsh", "bash", "fish": return (.terminal, Color.dockSuccess)
        case "css", "scss", "sass", "html": return (.fileText, Color.dockDestructive)
        default:
            return (name.hasPrefix(".env") ? .settings : .fileText, name.hasPrefix(".env") ? Color.dockWarning : Color.dockMetadataText)
        }
    }

    private func fileSection(_ file: PullRequestFile) -> some View {
        let expanded = reviewPreferences.expandedFileIDs.contains(file.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                selectedFileID = file.id
                reviewPreferences.toggleExpanded(file.id)
            } label: {
                HStack(spacing: 8) {
                    LucideIcon(name: expanded ? .chevronDown : .chevronRight, size: 13, color: Color.dockMetadataText)
                    LucideIcon(name: .fileText, size: 15, color: Color.dockSecondaryText)
                    Text(file.path).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                    Text(file.status.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                    Spacer()
                    HStack(spacing: 8) {
                        Text("+\(file.additions)").foregroundStyle(Color.dockSuccess)
                        Text("−\(file.deletions)").foregroundStyle(Color.dockDestructive)
                    }.font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(Color.dockPrimaryText)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { fileContent(file) }
        }
        .background(Color.dockCanvas)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
    }

    @ViewBuilder
    private func fileContent(_ file: PullRequestFile) -> some View {
        if reviewPreferences.richPreview, !sourceDiffFileIDs.contains(file.id), let patch = file.patch, isMarkdown(file.path) {
            VStack(alignment: .leading, spacing: 6) {
                Text("RICH PREVIEW").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Color.dockMetadataText)
                MarkdownMessageView(markdown: previewMarkdown(from: patch)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.dockSurface2)
                Button("Show source diff") { sourceDiffFileIDs.insert(file.id) }.buttonStyle(.borderless).font(.system(size: 10, weight: .semibold))
            }.padding(8)
        } else if reviewPreferences.richPreview, !sourceDiffFileIDs.contains(file.id), isImage(file.path), let url = file.webURL {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: imagePreviewURL(for: url)) { phase in
                    if let image = phase.image { image.resizable().scaledToFit().frame(maxHeight: 420) }
                    else { Text("Image preview unavailable. Open on GitHub to view this file.").foregroundStyle(Color.dockMetadataText) }
                }
                Button("Show source diff") { sourceDiffFileIDs.insert(file.id) }.buttonStyle(.borderless).font(.system(size: 10, weight: .semibold))
            }.padding(8)
        } else if let patch = file.patch {
            diffPatch(patch)
        } else {
            HStack { Text("Binary or truncated patch").font(.system(size: 11)).foregroundStyle(Color.dockMetadataText); Spacer(); if let url = file.webURL { Link("OPEN ON GITHUB", destination: url).font(.system(size: 10, weight: .bold)) } }.padding(12)
        }
    }

    private func isMarkdown(_ path: String) -> Bool { ["md", "markdown", "mdown"].contains((path as NSString).pathExtension.lowercased()) }
    private func isImage(_ path: String) -> Bool { ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains((path as NSString).pathExtension.lowercased()) }
    private func imagePreviewURL(for url: URL) -> URL {
        guard url.host?.lowercased() == "github.com" else { return url }
        let components = url.path.split(separator: "/").map(String.init)
        guard components.count > 4, components[2] == "blob" else { return url }
        let rawPath = Array(components[0...1]) + Array(components.dropFirst(3))
        return URL(string: "https://raw.githubusercontent.com/\(rawPath.joined(separator: "/"))") ?? url
    }
    private func previewMarkdown(from patch: String) -> String { PullRequestDiffPresentation.lines(patch).filter { $0.kind != .deletion && $0.kind != .hunk && $0.kind != .metadata }.map { $0.kind == .addition ? String($0.text.dropFirst()) : $0.text }.joined(separator: "\n") }

    @ViewBuilder
    private func diffPatch(_ patch: String) -> some View {
        let rows = diffPresentationCache.rows(for: patch)
        Group {
            if reviewPreferences.diffMode == .split {
                // Split reviews must always start with both sides visible. Each
                // pane shares the available viewport instead of sizing itself to
                // the longest line in the patch.
                diffRows(rows)
            } else if reviewPreferences.wordWrap {
                diffRows(rows)
            } else {
                ScrollView(.horizontal, showsIndicators: true) { diffRows(rows).fixedSize(horizontal: true, vertical: false) }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private func diffRows(_ rows: [PullRequestDiffSplitRow]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                if reviewPreferences.diffMode == .split {
                    HStack(spacing: 0) {
                        splitDiffColumn(row.left, counterpart: row.right?.text)
                        Color.dockBorderLight.frame(width: 0.5)
                        splitDiffColumn(row.right, counterpart: row.left?.text)
                    }
                } else if let left = row.left, let right = row.right, left.kind == .deletion, right.kind == .addition {
                    diffLineView(left, counterpart: right.text)
                    diffLineView(right, counterpart: left.text)
                } else {
                    diffLineView(row.left ?? row.right, counterpart: nil)
                }
            }
        }
    }

    private func splitDiffColumn(_ line: PullRequestDiffLine?, counterpart: String?) -> some View {
        diffLineView(line, counterpart: counterpart)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)
    }

    @ViewBuilder
    private func diffLineView(_ line: PullRequestDiffLine?, counterpart: String?) -> some View {
        if let line {
            PullRequestDiffLineView(
                line: line,
                counterpart: counterpart,
                wordDiffsEnabled: reviewPreferences.wordDiffs && (line.kind == .addition || line.kind == .deletion)
            )
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: 19)
        }
    }
}

struct PullRequestWorkspace: View {
    @ObservedObject var center: PullRequestCenterModel
    let projects: [ProjectSummary]
    let onOpenChat: (PullRequestRecord) -> Void
    @State private var loadingPulse = false

    var body: some View {
        VStack(spacing: 0) {
            DockPageHeader(
                icon: "git.pull.request",
                title: "Pull requests",
                subtitle: "Review open changes across your repositories",
                onRefresh: { Task { await center.refresh(projects: projects) } },
                isRefreshing: center.isRefreshing
            )

            HSplitView {
                listPane.frame(minWidth: 300, idealWidth: 390, maxWidth: 460, maxHeight: .infinity)
                PullRequestDetailView(center: center, onOpenChat: onOpenChat)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dockCanvas)
        .task { if center.records.isEmpty { await center.refresh(projects: projects) } }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                loadingPulse = true
            }
        }
        .onChange(of: center.filter) { _, _ in center.repairSelection() }
        .onChange(of: center.query) { _, _ in center.repairSelection() }
    }

    private var listPane: some View { VStack(spacing: 0) {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(PullRequestFilter.allCases) { filter in
                    PullRequestFilterTabButton(title: filter.rawValue, isSelected: center.filter == filter) {
                        center.filter = filter
                    }
                }
            }
            Divider().frame(height: 22)
            HStack(spacing: 8) {
                LucideIcon(name: .search, size: 16)
                TextField("Search pull requests", text: $center.query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Color.dockCanvas.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Color.dockSurface2.opacity(0.45))
        if let error = center.errorMessage { Text(error).font(.system(size: 11)).foregroundStyle(Color.dockWarning).padding(.horizontal, 18).padding(.bottom, 8) }
        ScrollView {
            LazyVStack(spacing: 2) {
                if center.isInitialLoad {
                    ForEach(0..<6, id: \.self) { index in listLoadingRow(index: index) }
                } else {
                    ForEach(center.visible) { pr in
                        Button { center.selectedID = pr.id } label: { PullRequestRowView(pullRequest: pr, isSelected: center.selectedID == pr.id) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }.background(Color.dockSurface2.opacity(0.55)) }

    private func listLoadingRow(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                PullRequestShimmerBlock(width: 18, height: 18, cornerRadius: 5, pulse: loadingPulse)
                PullRequestShimmerBlock(width: index.isMultiple(of: 2) ? 184 : 228, height: 12, cornerRadius: 4, pulse: loadingPulse)
            }
            PullRequestShimmerBlock(width: index.isMultiple(of: 3) ? 122 : 160, height: 9, cornerRadius: 3, pulse: loadingPulse)
            PullRequestShimmerBlock(width: 48, height: 8, cornerRadius: 3, pulse: loadingPulse)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.dockSurface2))
        .accessibilityHidden(true)
    }
}
