import AppKit
import Combine
import SwiftUI

/// Plain-language descriptions of Hermes tool calls ("Browsing booking.com"),
/// shared by the voice HUD, its pills and the notch.
enum ToolStep {
    static func describe(_ call: ActiveToolCall) -> (icon: Ph, title: String, detail: String?) {
        describe(name: call.name, args: call.args ?? [:], isComplete: call.isComplete)
    }

    static func describe(name: String, args a: [String: String], isComplete: Bool = false) -> (
        icon: Ph, title: String, detail: String?
    ) {
        describe(name: name, isComplete: isComplete, argument: { a[$0] })
    }

    /// An activity label formats only the fields it displays, even if Hermes sends a large tool input.
    static func describe(name: String, rawArgs: Any?) -> (icon: Ph, title: String, detail: String?) {
        var parsed: [String: Any]?
        return describe(name: name, isComplete: false) { key in
            if parsed == nil { parsed = DockModel.parseArgsDict(rawArgs) ?? [:] }
            return parsed?[key].map(DockModel.toolArgumentText)
        }
    }

    private static func describe(name: String, isComplete: Bool, argument: (String) -> String?)
        -> (icon: Ph, title: String, detail: String?)
    {
        var file: String? { argument("path").map { ($0 as NSString).lastPathComponent } }
        func quoted(_ text: String?) -> String? { text.map { "“\($0.prefix(80))”" } }
        let lower = name.lowercased()
        switch lower {
        case "browser_exec", "browser_cdp":
            return (.globe, isComplete ? "Used the browser" : "Working in the browser", nil)
        case "browser_navigate":
            let url = argument("url")
            return (.globe, "Browsing \(host(url) ?? "the web")", url)
        case "browser_click": return (.cursorClick, "Clicking on the page", nil)
        // Typed text may be a password, so it is never shown here.
        case "browser_type": return (.keyboard, "Filling in a field", nil)
        case "browser_scroll": return (.arrowsDownUp, "Scrolling \(argument("direction") ?? "the page")", nil)
        case "browser_back": return (.arrowLeft, "Going back", nil)
        case "browser_press": return (.keyboard, "Pressing \(argument("key") ?? "a key")", nil)
        case "browser_snapshot": return (.eye, "Reading the page", nil)
        case "browser_vision": return (.eye, "Looking at the page", argument("question"))
        case "browser_get_images": return (.image, "Collecting images", nil)
        case "browser_console": return (.code, "Checking the console", nil)
        case "web_search": return (.magnifyingGlass, "Searching the web", quoted(argument("query")))
        case "web_extract":
            let link = argument("urls").flatMap(VoicePillQueue.target(in:))
            return (.fileText, "Reading \(host(link) ?? "a page")", nil)
        case "terminal":
            return (.terminalWindow, "Running a command", argument("command").map { String($0.prefix(90)) })
        case "write_file": return (.pencilSimple, "Writing \(file ?? "a file")", nil)
        case "patch": return (.pencilSimple, "Editing \(file ?? "a file")", nil)
        case "read_file": return (.fileText, "Reading \(file ?? "a file")", nil)
        case "search_files": return (.magnifyingGlass, "Searching files", quoted(argument("pattern")))
        case "memory":
            let forgets = argument("action")?.lowercased().contains("remove") == true
            let title = forgets ? (isComplete ? "Forgot" : "Forgetting") : (isComplete ? "Remembered" : "Remembering")
            return (
                .bookmarkSimple, title,
                (argument("content") ?? argument("new_text") ?? argument("old_text")).map { String($0.prefix(100)) }
            )
        case "skill_view":
            return (.bookOpen, "Using skill \(argument("name") ?? "")".trimmingCharacters(in: .whitespaces), nil)
        case "image_generate":
            return (
                .image, isComplete ? "Image ready" : "Generating an image",
                argument("prompt").map { String($0.prefix(90)) }
            )
        case "vision_analyze": return (.eye, "Looking at an image", argument("question"))
        case "delegate_task": return (.robot, "Delegating", nil)
        case "todo", "todo_list", "todo_write": return (.listChecks, "Updating the plan", nil)
        case "cronjob", "cronjob_manage": return (.calendarCheck, "Scheduling", argument("action"))
        case "clarify": return (.chatCircleText, "Asking you", nil)
        case "execute_code": return (.code, "Running code", nil)
        case "text_to_speech": return (.waveform, "Speaking", nil)
        default:
            if lower.contains("send") || lower.hasSuffix("_dm") {
                let to =
                    argument("to") ?? argument("target") ?? argument("recipient") ?? argument("chat_id") ?? argument(
                        "channel") ?? argument("user")
                let text = argument("message") ?? argument("text") ?? argument("content")
                let detail = [to, text.map { "“\($0.prefix(70))”" }].compactMap { $0 }.joined(separator: " · ")
                return (
                    .paperPlaneTilt, isComplete ? "Message sent" : "Sending a message", detail.isEmpty ? nil : detail
                )
            }
            return (.wrench, name.replacingOccurrences(of: "_", with: " ").capitalized, nil)
        }
    }

    static func host(_ link: String?) -> String? {
        guard let host = link.flatMap({ URL(string: $0)?.host() }) else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Reads fields out of a stored tool result. Results are JSON truncated at
/// 4000 characters, so this matches fields instead of parsing the document.
enum ToolText {
    static func field(_ key: String, in text: String?) -> String? { fields(key, in: text).first }

    static func fields(_ key: String, in text: String?) -> [String] {
        guard let text, let regex = try? NSRegularExpression(pattern: #"""# + key + #""\s*:\s*"((?:[^"\\]|\\.)*)""#)
        else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { unescape(String(text[$0])) }
        }
    }

    static func number(_ key: String, in text: String?) -> Int? {
        guard let text, let regex = try? NSRegularExpression(pattern: #"""# + key + #""\s*:\s*(-?\d+)"#),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }

    private static func unescape(_ raw: String) -> String {
        (try? JSONDecoder().decode(String.self, from: Data("\"\(raw)\"".utf8))) ?? raw
    }
}

/// What the browser is doing: the page, its screenshot, the sites visited
/// this turn and the last few actions ("Clicked “Sign in” button").
struct BrowserSession: Equatable {
    var url: String?
    var title: String?
    var screenshot: String?
    var hosts: [String] = []
    var trail: [String] = []
    var isBusy = false
    var updatedAt: Date

    init?(calls: [ActiveToolCall]) {
        let steps = calls.filter { $0.name.lowercased().hasPrefix("browser_") }
        guard let last = steps.last else { return nil }
        updatedAt = last.completedAt ?? last.startedAt
        isBusy = !last.isComplete
        var elements: [String: String] = [:]
        for step in steps {
            let args = step.args ?? [:]
            let element = args["ref"].map { ref in
                elements[ref.trimmingCharacters(in: CharacterSet(charactersIn: "@"))] ?? "an element"
            }
            switch step.name.lowercased() {
            case "browser_navigate":
                url = ToolText.field("url", in: step.result) ?? args["url"] ?? url
                title = ToolText.field("title", in: step.result)
                screenshot = nil
                if let host = ToolStep.host(url), hosts.last != host { hosts.append(host) }
                trail.append("Opened \(ToolStep.host(url) ?? "a page")")
            case "browser_back":
                url = ToolText.field("url", in: step.result) ?? url
                title = nil
                trail.append("Went back")
            case "browser_click":
                trail.append("Clicked \(element ?? "the page")")
            case "browser_type":
                let field = element ?? "a field"
                let text = field.lowercased().contains("password") ? "••••" : "“\((args["text"] ?? "").prefix(40))”"
                trail.append("Typed \(text) into \(field)")
            case "browser_scroll":
                trail.append("Scrolled \(args["direction"] ?? "")".trimmingCharacters(in: .whitespaces))
            case "browser_press":
                trail.append("Pressed \(args["key"] ?? "a key")")
            case "browser_vision":
                screenshot = ToolText.field("screenshot_path", in: step.result) ?? screenshot
                trail.append("Looked at the page")
            case "browser_snapshot":
                trail.append("Read the page")
            default:
                // Scripted steps (browser_exec/cdp) may still report where the page is.
                url = ToolText.field("url", in: step.result) ?? url
                title = ToolText.field("title", in: step.result) ?? title
                trail.append(ToolStep.describe(step).title)
            }
            // Refs name elements of the latest snapshot; later steps use them.
            for (ref, label) in Self.elements(in: step.result) { elements[ref] = label }
        }
        if title == nil, let url { title = ToolStep.host(url) }
        trail = Array(trail.suffix(4))
        hosts = Array(hosts.suffix(5))
    }

    /// `- link "More" [ref=e2]` lines of a page snapshot, as ref → “More” link.
    static func elements(in text: String?) -> [(ref: String, label: String)] {
        guard let text, let regex = try? NSRegularExpression(pattern: #"(\w+) \\?"([^"\\]*)\\?" \[ref=(e\d+)\]"#) else {
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let kind = Range(match.range(at: 1), in: text), let name = Range(match.range(at: 2), in: text),
                let ref = Range(match.range(at: 3), in: text)
            else { return nil }
            let role = String(text[kind])
            let label =
                "“\(text[name].prefix(40))”"
                + (["link", "button", "textbox", "checkbox", "combobox"].contains(role) ? " \(role)" : "")
            return (String(text[ref]), label)
        }
    }
}

struct SearchFan: Equatable {
    struct Hit: Equatable {
        let title: String
        let url: String
    }

    let query: String
    let hits: [Hit]
    let isBusy: Bool
    let updatedAt: Date

    init?(calls: [ActiveToolCall]) {
        guard let call = calls.last(where: { $0.name.lowercased() == "web_search" }) else { return nil }
        query = call.args?["query"] ?? "the web"
        let urls = ToolText.fields("url", in: call.result)
        hits = zip(ToolText.fields("title", in: call.result), urls).prefix(4).map { Hit(title: $0, url: $1) }
        isBusy = !call.isComplete
        updatedAt = call.completedAt ?? call.startedAt
    }
}

struct TerminalTicker: Equatable {
    let command: String
    /// The output's last few non-empty lines.
    let tail: [String]
    var lastLine: String? { tail.last }
    let exitCode: Int?
    let duration: TimeInterval?
    let tests: TestSummary?
    let isBusy: Bool
    let updatedAt: Date

    init?(calls: [ActiveToolCall]) {
        guard let call = calls.last(where: { $0.name.lowercased() == "terminal" }) else { return nil }
        command = call.args?["command"] ?? call.input
        let output = ToolText.field("output", in: call.result) ?? call.result ?? ""
        tail = output.split(whereSeparator: \.isNewline)
            .map { String($0.trimmingCharacters(in: .whitespaces).prefix(160)) }
            .filter { !$0.isEmpty }.suffix(8)
        exitCode = ToolText.number("exit_code", in: call.result)
        duration = call.completedAt.map { $0.timeIntervalSince(call.startedAt) }
        tests = TestSummary(output)
        isBusy = !call.isComplete
        updatedAt = call.completedAt ?? call.startedAt
    }
}

/// Pass/fail counts from pytest, jest, XCTest or Swift Testing output.
struct TestSummary: Equatable {
    let passed: Int
    let failed: Int

    init(passed: Int, failed: Int) {
        self.passed = passed
        self.failed = failed
    }

    init?(_ output: String) {
        func count(_ pattern: String) -> [Int]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).last
            else { return nil }
            return (1..<match.numberOfRanges).map {
                Range(match.range(at: $0), in: output).flatMap { Int(output[$0]) } ?? 0
            }
        }
        if let xc = count(#"Executed (\d+) tests?, with (\d+) failures?"#) {
            self.init(passed: xc[0] - xc[1], failed: xc[1])
        } else if let swift = count(#"Test run with (\d+) tests?.*? failed .*?with (\d+) issues?"#) {
            self.init(passed: max(0, swift[0] - swift[1]), failed: swift[1])
        } else if let swift = count(#"Test run with (\d+) tests?.*? passed"#) {
            self.init(passed: swift[0], failed: 0)
        } else {
            // pytest "3 failed, 40 passed" and jest "Tests: 3 failed, 40 passed".
            let failed = count(#"(\d+) failed"#)?[0]
            let passed = count(#"(\d+) passed"#)?[0]
            guard failed != nil || passed != nil else { return nil }
            self.init(passed: passed ?? 0, failed: failed ?? 0)
        }
    }
}

struct GeneratedMedia: Equatable {
    let source: String
    let prompt: String?
    let updatedAt: Date

    init?(calls: [ActiveToolCall]) {
        guard let call = calls.last(where: { $0.name.lowercased() == "image_generate" && $0.isComplete }),
            let source = ToolText.field("image", in: call.result) ?? ToolText.field("url", in: call.result)
                ?? ToolText.field("path", in: call.result) ?? call.result.flatMap(VoicePillQueue.target(in:))
        else { return nil }
        self.source = source
        prompt = call.args?["prompt"]
        updatedAt = call.completedAt ?? call.startedAt
    }

    var fileURL: URL? {
        source.hasPrefix("http")
            ? nil
            : URL(
                fileURLWithPath: (source.replacingOccurrences(of: "file://", with: "") as NSString).expandingTildeInPath
            )
    }
}

/// A file search: the pattern and folder the moment it starts, then the
/// real hits Hermes returned, one per file.
struct FileSearchScan: Equatable {
    struct Hit: Equatable {
        let path: String
        let line: Int?
        let text: String?
    }

    let pattern: String
    let scope: String
    let byName: Bool
    let hits: [Hit]
    let total: Int?
    let isBusy: Bool
    let updatedAt: Date

    static let hitLimit = 8

    init?(calls: [ActiveToolCall]) {
        guard let call = calls.last(where: { $0.name.lowercased() == "search_files" }) else { return nil }
        let args = call.args ?? [:]
        pattern = args["pattern"] ?? ""
        scope = args["path"] ?? "."
        byName = ["files", "find"].contains(args["target"]?.lowercased() ?? "")
        hits = call.isComplete ? Self.hits(in: call.result) : []
        total = ToolText.number("total_count", in: call.result)
        isBusy = !call.isComplete
        updatedAt = call.completedAt ?? call.startedAt
    }

    /// `search_files` returns `matches` (or a path-grouped `matches_text`
    /// past a few hits) for content searches and `files` for name searches.
    static func hits(in result: String?) -> [Hit] {
        guard let result else { return [] }
        var hits: [Hit] = []
        func add(_ hit: Hit) {
            if hits.count < hitLimit, !hits.contains(where: { $0.path == hit.path }) { hits.append(hit) }
        }
        if let dense = ToolText.field("matches_text", in: result) {
            var path: String?
            for row in dense.split(separator: "\n") {
                guard row.hasPrefix("  ") else {
                    path = String(row)
                    continue
                }
                let parts = row.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
                if let path {
                    add(
                        Hit(
                            path: path, line: parts.first.flatMap { Int($0) },
                            text: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil))
                }
            }
            return hits
        }
        let json = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any]
        if let matches = json?["matches"] as? [[String: Any]] {
            for match in matches {
                guard let path = match["path"] as? String else { continue }
                let text = (match["content"] as? String)?.trimmingCharacters(in: .whitespaces)
                add(Hit(path: path, line: (match["line"] as? NSNumber)?.intValue, text: text))
            }
        } else if let files = json?["files"] as? [String] {
            for file in files { add(Hit(path: file, line: nil, text: nil)) }
        } else {
            // Persistence may truncate the JSON; its paths still read.
            for path in ToolText.fields("path", in: result) { add(Hit(path: path, line: nil, text: nil)) }
        }
        return hits
    }
}

/// A file being read, written or edited, with a few of its real lines.
struct FileGlimpse: Equatable {
    enum Action: Equatable { case read, write, edit }

    struct Line: Equatable {
        let number: Int?
        let text: String
        /// `+` or `-` on an edit.
        let mark: Character?
    }

    let path: String?
    let action: Action
    let lines: [Line]
    let isBusy: Bool
    let updatedAt: Date

    static let lineLimit = 12

    init?(calls: [ActiveToolCall]) {
        let names = ["read_file": Action.read, "write_file": .write, "patch": .edit]
        guard let call = calls.last(where: { names[$0.name.lowercased()] != nil }),
            let action = names[call.name.lowercased()]
        else { return nil }
        self.action = action
        path = call.args?["path"] ?? ToolText.field("path", in: call.result)
        isBusy = !call.isComplete
        updatedAt = call.completedAt ?? call.startedAt
        switch action {
        case .read: lines = call.isComplete ? Self.numbered(ToolText.field("content", in: call.result)) : []
        case .write: lines = Self.plain(call.args?["content"])
        case .edit: lines = Self.diff(call.diffPreview)
        }
    }

    /// `read_file` content is `<n>|<text>` rows.
    static func numbered(_ content: String?) -> [Line] {
        guard let content else { return [] }
        return content.split(separator: "\n").lazy.compactMap { row -> Line? in
            let parts = row.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let number = Int(parts[0].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            let text = String(parts[1])
            return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Line(number: number, text: text, mark: nil)
        }.prefix(lineLimit).map { $0 }
    }

    static func plain(_ content: String?) -> [Line] {
        guard let content else { return [] }
        return content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(lineLimit).map { Line(number: $0.offset + 1, text: String($0.element), mark: nil) }
    }

    /// Changed lines of a unified diff, without its headers.
    static func diff(_ preview: String?) -> [Line] {
        guard let preview else { return [] }
        return preview.split(separator: "\n").lazy
            .filter { ($0.hasPrefix("+") && !$0.hasPrefix("+++")) || ($0.hasPrefix("-") && !$0.hasPrefix("---")) }
            .prefix(lineLimit).map { Line(number: nil, text: String($0.dropFirst()), mark: $0.first) }
    }
}

/// The large cards beside the orb, newest first.
struct VoiceHUDState: Equatable {
    enum Card: Equatable, Identifiable {
        case browser(BrowserSession)
        case search(SearchFan)
        case terminal(TerminalTicker)
        case media(GeneratedMedia)
        case fileSearch(FileSearchScan)
        case file(FileGlimpse)

        var id: String {
            switch self {
            case .browser: "browser"
            case .search: "search"
            case .terminal: "terminal"
            case .media: "media"
            case .fileSearch: "fileSearch"
            case .file: "file"
            }
        }

        var updatedAt: Date {
            switch self {
            case .browser(let card): card.updatedAt
            case .search(let card): card.updatedAt
            case .terminal(let card): card.updatedAt
            case .media(let card): card.updatedAt
            case .fileSearch(let card): card.updatedAt
            case .file(let card): card.updatedAt
            }
        }

        var isBusy: Bool {
            switch self {
            case .browser(let card): card.isBusy
            case .search(let card): card.isBusy
            case .terminal(let card): card.isBusy
            case .fileSearch(let card): card.isBusy
            case .file(let card): card.isBusy
            case .media: false
            }
        }
    }

    var cards: [Card] = []

    init(calls: [ActiveToolCall] = []) {
        let all: [Card?] = [
            BrowserSession(calls: calls).map(Card.browser),
            SearchFan(calls: calls).map(Card.search),
            TerminalTicker(calls: calls).map(Card.terminal),
            GeneratedMedia(calls: calls).map(Card.media),
            FileSearchScan(calls: calls).map(Card.fileSearch),
            FileGlimpse(calls: calls).map(Card.file),
        ]
        cards = all.compactMap { $0 }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Tools these cards show, so the small activity cards don't repeat them.
    static func covers(_ toolName: String) -> Bool {
        let name = toolName.lowercased()
        return name.hasPrefix("browser_")
            || ["web_search", "terminal", "image_generate", "search_files", "read_file", "write_file", "patch"]
                .contains(name)
    }
}

// MARK: - Views

extension EnvironmentValues {
    /// Inside the agent screen, which draws the surface and the scan for its view.
    @Entry fileprivate var hudInScreen = false
}

extension View {
    /// A HUD panel; `scanning` sweeps light across it while its tool runs.
    fileprivate func hudCard(tint: Color = .dockAccent, scanning: Bool = false) -> some View {
        modifier(HUDCardChrome(tint: tint, scanning: scanning))
    }
}

private struct HUDCardChrome: ViewModifier {
    let tint: Color
    let scanning: Bool
    @Environment(\.hudInScreen) private var inScreen

    func body(content: Content) -> some View {
        if inScreen {
            content
        } else {
            content.padding(12).dockHUDSurface(tint: tint).modifier(HUDScan(active: scanning, tint: tint))
        }
    }
}

/// A band of light sweeping across a busy panel, like a scanner. Ambient
/// only: Hermes reports a tool's start and result, nothing in between.
private struct HUDScan: ViewModifier {
    let active: Bool
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if active, !reduceMotion {
                TimelineView(.dockMotion(paused: false)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    GeometryReader { geometry in
                        let band = geometry.size.width * 0.45
                        LinearGradient(
                            colors: [.clear, tint.opacity(0.2), .clear], startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: band)
                        .offset(x: (geometry.size.width + band) * phase - band)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius + 4, style: .continuous))
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }
}

private struct HUDHeader: View {
    let icon: Ph
    let title: String
    var detail: String?
    var isBusy = false
    var opens = false
    var tint: Color = .dockAccent
    @Environment(\.hudInScreen) private var inScreen

    var body: some View {
        if !inScreen { row }
    }

    private var row: some View {
        HStack(spacing: 8) {
            DockIcon(icon, size: 14, weight: .fill)
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isBusy { ThinkingDots() }
            if opens { DockIcon(.arrowUpRight, size: 10).foregroundStyle(tint) }
        }
    }
}

/// The agent's screen: the newest tool's own view (terminal, editor, file
/// results, browser, web results, image) over a log of the turn's steps. It
/// slides in beside the voice stage the way a generative panel does.
struct VoiceAgentScreen: View {
    let model: DockModel
    /// Redraws on voice changes only; the body still reads the model.
    @ObservedObject private var stage: VoiceStageState
    /// The notch and island are too short for the step log.
    var showsLog = true

    init(model: DockModel, showsLog: Bool = true) {
        self.model = model
        _stage = ObservedObject(wrappedValue: model.voiceStage)
        self.showsLog = showsLog
    }
    @State private var state = VoiceHUDState()
    @State private var steps: [ActiveToolCall] = []
    @State private var working = true
    @State private var shownAt: Date?
    @State private var pending: Task<Void, Never>?
    /// The shortest time a view stays before the next one replaces it, so bursts don't flash.
    nonisolated static let minimumDwell: TimeInterval = 1.5
    private let shape = RoundedRectangle(cornerRadius: DockLayout.paneRadius + 8, style: .continuous)

    /// Whether the turn has any tool step to show.
    nonisolated static func hasSteps(_ calls: [ActiveToolCall]) -> Bool { calls.contains { !$0.name.hasPrefix("__") } }

    /// Whether a step this turn has its own view (page, terminal, files, edit, results, image),
    /// not just a title; only that is worth keeping on screen once the turn ends.
    nonisolated static func hasVisual(_ calls: [ActiveToolCall]) -> Bool {
        calls.contains { VoiceHUDState.covers($0.name) } && !VoiceHUDState(calls: calls).cards.isEmpty
    }

    /// The step the screen is about and its view. While working, a tool without its own view
    /// (memory, tool lookup) shows as its step; once done, the screen keeps the last real view.
    nonisolated static func scene(_ calls: [ActiveToolCall], working: Bool) -> (
        step: ActiveToolCall?, card: VoiceHUDState.Card?
    ) {
        scene(steps: calls.filter { !$0.name.hasPrefix("__") }, state: VoiceHUDState(calls: calls), working: working)
    }

    nonisolated static func scene(steps: [ActiveToolCall], state: VoiceHUDState, working: Bool) -> (
        step: ActiveToolCall?, card: VoiceHUDState.Card?
    ) {
        let card = state.cards.first
        if let latest = steps.last, VoiceHUDState.covers(latest.name) { return (latest, card) }
        if !working, card != nil, let viewed = steps.last(where: { VoiceHUDState.covers($0.name) }) {
            return (viewed, card)
        }
        return (steps.last, nil)
    }

    /// How long to wait before replacing the view shown at `shownAt`; updates to the same view apply at once.
    nonisolated static func wait(shownAt: Date?, now: Date, replacesView: Bool) -> TimeInterval {
        guard replacesView, let shownAt else { return 0 }
        return max(0, minimumDwell - now.timeIntervalSince(shownAt))
    }

    var body: some View {
        let scene = Self.scene(steps: steps, state: state, working: working)
        let latest = scene.step
        let card = scene.card
        let viewID: String? = card?.id ?? latest?.id
        let isBusy: Bool = card.map(\.isBusy) ?? latest.map { !$0.isComplete } ?? false
        VStack(alignment: .leading, spacing: 0) {
            current(card: card, latest: latest)
                .id(viewID)
                // Each new view comes into focus out of a blur.
                .transition(.blurReplace)
                .dockPadding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsLog, steps.count > 1 {
                Divider()
                VoiceStepLog(steps: steps, title: model.toolStepTitle).dockPadding(18)
            }
        }
        .modifier(HUDScan(active: isBusy, tint: .dockAccent))
        .environment(\.hudInScreen, true)
        .multilineTextAlignment(.leading)
        .clipShape(shape)
        .dockFloatingSurface(shape, stroke: Color.dockBorderLight)
        .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: viewID)
        .onChange(of: model.voiceTurnToolCalls, initial: true) { _, _ in show() }
        .onChange(of: model.status == .working) { _, _ in show() }
        .onDisappear { pending?.cancel() }
    }

    /// Applies the newest calls, holding a new view until the current one has had its minimum time.
    private func show() {
        pending?.cancel()
        let calls = model.voiceTurnToolCalls
        let isWorking = model.status == .working
        let nextState = VoiceHUDState(calls: calls)
        let nextSteps = calls.filter { !$0.name.hasPrefix("__") }
        let shown = Self.scene(steps: steps, state: state, working: working)
        let next = Self.scene(steps: nextSteps, state: nextState, working: isWorking)
        let replaces = (next.card?.id ?? next.step?.id) != (shown.card?.id ?? shown.step?.id)
        let wait = Self.wait(shownAt: shownAt, now: .now, replacesView: replaces)
        guard wait > 0 else {
            if replaces { shownAt = .now }
            steps = nextSteps
            state = nextState
            working = isWorking
            return
        }
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            shownAt = nil
            show()
        }
    }

    @ViewBuilder private func current(card: VoiceHUDState.Card?, latest: ActiveToolCall?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let latest { header(latest) }
            cardBody(card)
        }
    }

    /// The step in plain words (Apple Intelligence's when on), not the tool's terms.
    private func header(_ latest: ActiveToolCall) -> some View {
        HStack(spacing: 10) {
            DockIcon(ToolStep.describe(latest).icon, size: 16, weight: .fill)
                .foregroundStyle(Color.dockAccent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.dockAccent.opacity(0.14)))
            Text(model.toolStepTitle(latest))
                .dockFont(.navigation, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(2)
                .contentTransition(.opacity)
            Spacer(minLength: 4)
            if !latest.isComplete { ThinkingDots() }
            DockIconButton(
                icon: .x, label: "Close preview", style: DockThemePalette(theme: DockThemeRuntime.current),
                action: model.dismissVoicePreview)
        }
        .animation(.dockEase(duration: 0.25), value: model.toolStepTitle(latest))
    }

    @ViewBuilder private func cardBody(_ card: VoiceHUDState.Card?) -> some View {
        switch card {
        case .browser(let browser): BrowserCard(browser: browser)
        case .search(let search): SearchCard(search: search)
        case .terminal(let terminal): TerminalCard(terminal: terminal)
        case .media(let media): MediaCard(media: media)
        case .fileSearch(let search): FileSearchCard(search: search)
        case .file(let file): FileGlimpseCard(file: file)
        case nil: EmptyView()
        }
    }
}

/// The turn's most recent steps, oldest first, the running one highlighted.
private struct VoiceStepLog: View {
    let steps: [ActiveToolCall]
    let title: (ActiveToolCall) -> String
    static let limit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Steps · \(steps.count)")
                .dockFont(.compactStatus, weight: .semibold)
                .foregroundStyle(Color.dockMetadataText)
            ForEach(steps.suffix(Self.limit)) { call in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        if call.isComplete {
                            DockIcon(.check, size: 11).foregroundStyle(Color.dockSuccess)
                        } else {
                            ThinkingDots()
                        }
                    }
                    .frame(width: 18)
                    Text(title(call))
                        .dockFont(.metadata, weight: call.isComplete ? .regular : .semibold)
                        .foregroundStyle(call.isComplete ? Color.dockSecondaryText : Color.dockPrimaryText)
                        .layoutPriority(1)
                }
                .lineLimit(1)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: steps.suffix(Self.limit).map(\.id))
    }
}

private struct BrowserCard: View {
    let browser: BrowserSession
    @State private var image: CGImage?
    @Environment(\.hudInScreen) private var inScreen

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !inScreen {
                Button {
                    browser.url.map(ArtifactOpener.open)
                } label: {
                    HUDHeader(
                        icon: .globe, title: browser.title ?? "Browser", detail: ToolStep.host(browser.url),
                        isBusy: browser.isBusy, opens: browser.url != nil)
                }
                .buttonStyle(.dockHover)
                .help(browser.url ?? "")
            } else if let title = browser.title {
                Text(title).dockFont(.body, weight: .medium).foregroundStyle(Color.dockSecondaryText).lineLimit(1)
            }
            if let image {
                page(Image(decorative: image, scale: 2))
            }
            if browser.hosts.count > 1 {
                HStack(spacing: 4) {
                    ForEach(Array(browser.hosts.enumerated()), id: \.offset) { index, host in
                        let isCurrent = index == browser.hosts.count - 1
                        Text(host)
                            .dockFont(.compactStatus, weight: isCurrent ? .semibold : .regular)
                            .lineLimit(1)
                            .dockPadding(.horizontal, 6)
                            .dockPadding(.vertical, 3)
                            .background(Capsule().fill(Color.dockAccent.opacity(isCurrent ? 0.18 : 0.07)))
                            .foregroundStyle(isCurrent ? Color.dockAccent : Color.dockSecondaryText)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(browser.trail.enumerated()), id: \.offset) { index, step in
                    let isLast = index == browser.trail.count - 1
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isLast ? Color.dockAccent : Color.dockMetadataText.opacity(0.5))
                            .frame(width: 5, height: 5)
                        Text(step)
                            .dockFont(.metadata, weight: isLast ? .medium : .regular)
                            .foregroundStyle(isLast ? Color.dockPrimaryText : Color.dockSecondaryText)
                            .lineLimit(1)
                    }
                }
            }
        }
        .hudCard(scanning: browser.isBusy)
        .task(id: browser.screenshot) {
            image = nil
            guard let path = browser.screenshot else { return }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let thumbnail = await AttachmentThumbnailLoader.shared.image(at: url)
            guard !Task.isCancelled else { return }
            image = thumbnail
        }
    }
}

extension BrowserCard {
    fileprivate func page(_ image: Image) -> some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(height: inScreen ? 240 : 130)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SearchCard: View {
    let search: SearchFan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HUDHeader(icon: .magnifyingGlass, title: "Searching", detail: "“\(search.query)”", isBusy: search.isBusy)
            ForEach(Array(search.hits.enumerated()), id: \.offset) { index, hit in
                Button {
                    ArtifactOpener.open(hit.url)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hit.title)
                            .dockFont(.rowTitle)
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(1)
                        Text(ToolStep.host(hit.url) ?? hit.url)
                            .dockFont(.compactStatus, weight: .regular)
                            .foregroundStyle(Color.dockAccent)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dockPadding(.horizontal, 8)
                    .dockPadding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.dockAccent.opacity(0.06)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .help(hit.url)
                // Results fan in one after another.
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double(index) * 0.08), value: search.hits)
            }
        }
        .hudCard(scanning: search.isBusy)
    }
}

private struct TerminalCard: View {
    let terminal: TerminalTicker
    @Environment(\.hudInScreen) private var inScreen

    private var tint: Color {
        guard !terminal.isBusy else { return .dockAccent }
        if let tests = terminal.tests { return tests.failed > 0 ? .dockDestructive : .dockSuccess }
        return (terminal.exitCode ?? 0) == 0 ? .dockSuccess : .dockDestructive
    }

    private var status: String? {
        guard !terminal.isBusy else { return nil }
        var parts: [String] = []
        if let code = terminal.exitCode { parts.append(code == 0 ? "Done" : "Exit \(code)") }
        if let duration = terminal.duration { parts.append(String(format: "%.1fs", duration)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HUDHeader(
                icon: .terminalWindow, title: terminal.isBusy ? "Running" : "Command finished",
                detail: status, isBusy: terminal.isBusy, tint: tint)
            if !inScreen {
                Text("$ " + terminal.command)
                    .dockFont(.metadata, weight: .regular, design: .monospaced)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(2)
            }
            if inScreen, !terminal.tail.isEmpty {
                // The output as the terminal printed it.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(terminal.tail.enumerated()), id: \.offset) { _, line in
                        Text(line).dockFont(.code).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                    }
                }
                .dockPadding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dockWell()
            } else if let line = terminal.lastLine {
                Text(line)
                    .dockFont(.code)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
            }
            if let tests = terminal.tests {
                HStack(spacing: 8) {
                    Label("\(tests.passed) passed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.dockSuccess)
                    if tests.failed > 0 {
                        Label("\(tests.failed) failed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(Color.dockDestructive)
                    }
                }
                .dockFont(.metadata, weight: .semibold)
            }
        }
        .hudCard(tint: tint, scanning: terminal.isBusy)
    }
}

private struct MediaCard: View {
    let media: GeneratedMedia
    @Environment(\.hudInScreen) private var inScreen

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !inScreen {
                Button {
                    ArtifactOpener.open(media.source)
                } label: {
                    HUDHeader(icon: .image, title: "Image ready", detail: media.prompt, opens: true, tint: .dockSuccess)
                }
                .buttonStyle(.dockHover)
            }
            Group {
                if let url = media.fileURL {
                    AttachmentThumbnailView(url: url)
                } else if let url = URL(string: media.source), media.source.hasPrefix("http") {
                    AsyncImage(url: url) {
                        $0.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        DockLoadingIndicator()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: inScreen ? 320 : 180)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            // Drag the image straight into another app.
            .onDrag {
                media.fileURL.map { NSItemProvider(object: $0 as NSURL) }
                    ?? NSItemProvider(object: media.source as NSString)
            }
        }
        .hudCard(tint: .dockSuccess)
    }
}

/// Where a path sits, for a quiet second line: the last two folders.
private func hudFolder(_ path: String) -> String? {
    let folder = (path as NSString).deletingLastPathComponent
    let parts = folder.split(separator: "/").suffix(2)
    return parts.isEmpty ? nil : parts.joined(separator: "/")
}

/// A path opens only when it exists on this Mac; remote gateways' paths don't.
private func hudLocalFile(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
}

private struct FileSearchCard: View {
    let search: FileSearchScan
    @Environment(\.hudInScreen) private var inScreen

    private var title: String {
        if search.isBusy { return search.byName ? "Looking for files" : "Searching files" }
        let count = search.total ?? search.hits.count
        return count == 0 ? "No matches" : "\(count) match\(count == 1 ? "" : "es")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HUDHeader(
                icon: .magnifyingGlass, title: title,
                detail: "“\(search.pattern.prefix(60))” in \(hudFolder(search.scope + "/x") ?? search.scope)",
                isBusy: search.isBusy)
            ForEach(Array(search.hits.enumerated()), id: \.offset) { index, hit in
                let row = HStack(alignment: .firstTextBaseline, spacing: 8) {
                    DockIcon(.fileText, size: 12).foregroundStyle(Color.dockAccent)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text((hit.path as NSString).lastPathComponent)
                                .dockFont(.rowTitle)
                                .foregroundStyle(Color.dockPrimaryText)
                            if let line = hit.line, !inScreen {
                                Text(":\(line)").dockFont(.compactStatus, weight: .regular)
                                    .foregroundStyle(Color.dockMetadataText)
                            }
                        }
                        .lineLimit(1)
                        // The screen names files and folders, not matched code.
                        if let text = hit.text, !text.isEmpty, !inScreen {
                            Text(text)
                                .dockFont(.code)
                                .foregroundStyle(Color.dockSecondaryText)
                                .lineLimit(1)
                        } else if let folder = hudFolder(hit.path) {
                            Text(folder).dockFont(.compactStatus, weight: .regular)
                                .foregroundStyle(Color.dockMetadataText).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Group {
                    if hudLocalFile(hit.path) {
                        Button {
                            ArtifactOpener.open(hit.path)
                        } label: {
                            row.contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .help(hit.path)
                    } else {
                        row
                    }
                }
                // Hits land one after another, as if found in turn.
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double(index) * 0.08), value: search.hits)
            }
        }
        .hudCard(scanning: search.isBusy)
    }
}

private struct FileGlimpseCard: View {
    let file: FileGlimpse
    @Environment(\.hudInScreen) private var inScreen

    private var name: String { file.path.map { ($0 as NSString).lastPathComponent } ?? "a file" }

    private var title: String {
        switch (file.action, file.isBusy) {
        case (.read, true): "Reading \(name)"
        case (.read, false): "Read \(name)"
        case (.write, true): "Writing \(name)"
        case (.write, false): "Wrote \(name)"
        case (.edit, true): "Editing \(name)"
        case (.edit, false): "Edited \(name)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let opens = file.path.map(hudLocalFile) ?? false
            if !inScreen {
                Button {
                    file.path.map(ArtifactOpener.open)
                } label: {
                    HUDHeader(
                        icon: file.action == .read ? .fileText : .pencilSimple, title: title,
                        detail: file.path.flatMap(hudFolder), isBusy: file.isBusy, opens: opens,
                        tint: file.action == .read || file.isBusy ? .dockAccent : .dockSuccess)
                }
                .buttonStyle(.dockHover)
                .disabled(!opens)
                .help(file.path ?? "")
            }
            if !file.lines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if !inScreen {
                                Text(line.mark.map(String.init) ?? line.number.map(String.init) ?? "")
                                    .foregroundStyle(
                                        line.mark == "+"
                                            ? Color.dockSuccess
                                            : line.mark == "-" ? Color.dockDestructive : .dockMetadataText
                                    )
                                    .frame(minWidth: 18, alignment: .trailing)
                            }
                            Text(line.text)
                                .foregroundStyle(
                                    inScreen && line.mark == "+"
                                        ? Color.dockSuccess
                                        : inScreen && line.mark == "-"
                                            ? Color.dockDestructive
                                            : line.mark == nil ? Color.dockSecondaryText : Color.dockPrimaryText
                                )
                                .lineLimit(1)
                        }
                        .dockFont(.code)
                    }
                }
                .dockPadding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dockWell()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .hudCard(tint: file.action == .read || file.isBusy ? .dockAccent : .dockSuccess, scanning: file.isBusy)
        .animation(.dockEase(duration: 0.25), value: file.lines)
    }
}

/// Elapsed time with steps and the plan's progress, above the orb.
struct VoiceStatusStrip: View {
    @ObservedObject var model: DockModel
    @State private var activityRevision = 0

    var body: some View {
        let _ = activityRevision
        HStack(spacing: 8) {
            if model.status == .working, let start = turnStart {
                TimelineView(.dockMotion(rate: 1)) { context in
                    let elapsed = Int(context.date.timeIntervalSince(start))
                    let steps = model.voiceTurnToolCalls.filter { !$0.name.hasPrefix("__") }.count
                    chip(
                        icon: .timer,
                        text: String(format: "%d:%02d", elapsed / 60, elapsed % 60)
                            + (steps > 0 ? " · \(steps) step\(steps == 1 ? "" : "s")" : ""),
                        tint: elapsed >= 120 ? .dockWarning : .dockAccent)
                }
            }
            if let plan = model.currentTodoPlan, plan.done < plan.items.count,
                model.status == .working
            {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().stroke(Color.dockAccent.opacity(0.2), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: CGFloat(plan.done) / CGFloat(max(1, plan.items.count)))
                            .stroke(Color.dockAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.spring(response: 0.5), value: plan.done)
                    }
                    .frame(width: 14, height: 14)
                    Text("\(plan.done)/\(plan.items.count)" + (plan.current.map { " · \($0.content)" } ?? ""))
                        .lineLimit(1)
                }
                .modifier(ChipStyle(tint: .dockAccent))
                .frame(maxWidth: 320)
                .help(
                    plan.items.map { "\($0.status == "completed" ? "✓" : "○") \($0.content)" }.joined(separator: "\n"))
            }
        }
        .onReceive(model.activityPresentation.$revision.dropFirst().receive(on: RunLoop.main)) { _ in
            activityRevision &+= 1
        }
    }

    private var turnStart: Date? {
        model.voiceTelemetry.requestSubmittedAt ?? model.activeToolCalls.first?.startedAt
    }

    private func chip(icon: Ph, text: String, tint: Color = .dockAccent) -> some View {
        HStack(spacing: 5) {
            DockIcon(icon, size: 11, weight: .fill)
            Text(text).lineLimit(1).monospacedDigit()
        }
        .modifier(ChipStyle(tint: tint))
    }

}

private struct ChipStyle: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .dockFont(.metadata, weight: .medium)
            .foregroundStyle(tint)
            .dockPadding(.horizontal, 9)
            .dockPadding(.vertical, 5)
            .background(Capsule().fill(Color.dockSurface6.opacity(0.9)).stroke(tint.opacity(0.3), lineWidth: 0.6))
    }
}

/// Running subagents as small orbs that pulse while they work.
struct VoiceSubagentOrbs: View {
    let agents: [HermesSubagent]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animates = DockMotion.isEnabled(reduceMotion: reduceMotion)
        HStack(spacing: 14) {
            ForEach(agents.prefix(6), id: \.id) { agent in
                let running = agent.isRunning
                let tint: Color =
                    agent.status.lowercased().contains("fail") || agent.status == "error"
                    ? .dockDestructive
                    : running ? .dockAccent : .dockSuccess
                VStack(spacing: 4) {
                    // Shared clock: a cyclic phaseAnimator per orb ran at the display rate.
                    TimelineView(.dockMotion(rate: 15, paused: !(running && animates))) { context in
                        let pulse = running && animates ? DockMotionSchedule.breath(context.date, period: 1.4) : 0
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [tint, tint.opacity(0.2)], center: .center, startRadius: 1, endRadius: 11)
                            )
                            .frame(width: 18, height: 18)
                            .shadow(color: tint.opacity(0.6), radius: running ? 8 : 3)
                            .scaleEffect(0.9 + 0.25 * pulse)
                    }
                    Text(agent.name ?? "Agent")
                        .dockFont(.metadata, weight: .medium)
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: 70)
                    if let role = Self.roleLabel(agent) {
                        Text(role)
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockMetadataText)
                            .lineLimit(1)
                            .frame(maxWidth: 70)
                    }
                }
                .help(agent.latestActivity ?? agent.goal)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4), value: agents.map(\.id))
    }

    /// The Hermes role under the name, unless it only repeats the name.
    static func roleLabel(_ agent: HermesSubagent) -> String? {
        guard let role = agent.role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty,
            role.caseInsensitiveCompare(agent.name ?? "") != .orderedSame
        else { return nil }
        return role
    }
}

/// Fills around the orb as the pause after your last word nears the end of the turn.
struct VoiceListeningRing: View {
    let progress: Double

    var body: some View {
        Circle()
            .trim(from: 0, to: progress)
            .stroke(Color.dockAccent.opacity(0.75), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .opacity(progress > 0.05 ? 1 : 0)
            .animation(.linear(duration: 0.12), value: progress)
            .allowsHitTesting(false)
    }
}

/// A brief glow around the edges when the wake phrase is heard.
struct VoiceWakeFlash: View {
    let count: Int
    @State private var glowing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Color.dockAccent, lineWidth: 6)
            .blur(radius: 14)
            .opacity(glowing ? 0.9 : 0)
            .allowsHitTesting(false)
            .onChange(of: count) {
                withAnimation(.easeOut(duration: 0.15)) { glowing = true }
                withAnimation(.easeIn(duration: 0.8).delay(0.35)) { glowing = false }
            }
    }
}
