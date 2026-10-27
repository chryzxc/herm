import AppKit
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
        let file = a["path"].map { ($0 as NSString).lastPathComponent }
        func quoted(_ text: String?) -> String? { text.map { "“\($0.prefix(80))”" } }
        let lower = name.lowercased()
        switch lower {
        case "browser_navigate": return (.globe, "Browsing \(host(a["url"]) ?? "the web")", a["url"])
        case "browser_click": return (.cursorClick, "Clicking on the page", nil)
        // Typed text may be a password, so it is never shown here.
        case "browser_type": return (.keyboard, "Filling in a field", nil)
        case "browser_scroll": return (.arrowsDownUp, "Scrolling \(a["direction"] ?? "the page")", nil)
        case "browser_back": return (.arrowLeft, "Going back", nil)
        case "browser_press": return (.keyboard, "Pressing \(a["key"] ?? "a key")", nil)
        case "browser_snapshot": return (.eye, "Reading the page", nil)
        case "browser_vision": return (.eye, "Looking at the page", a["question"])
        case "browser_get_images": return (.image, "Collecting images", nil)
        case "browser_console": return (.code, "Checking the console", nil)
        case "web_search": return (.magnifyingGlass, "Searching the web", quoted(a["query"]))
        case "web_extract":
            let link = a["urls"].flatMap(VoicePillQueue.target(in:))
            return (.fileText, "Reading \(host(link) ?? "a page")", nil)
        case "terminal": return (.terminalWindow, "Running a command", a["command"].map { String($0.prefix(90)) })
        case "write_file": return (.pencilSimple, "Writing \(file ?? "a file")", nil)
        case "patch": return (.pencilSimple, "Editing \(file ?? "a file")", nil)
        case "read_file": return (.fileText, "Reading \(file ?? "a file")", nil)
        case "search_files": return (.magnifyingGlass, "Searching files", quoted(a["pattern"]))
        case "memory":
            let forgets = a["action"]?.lowercased().contains("remove") == true
            let title = forgets ? (isComplete ? "Forgot" : "Forgetting") : (isComplete ? "Remembered" : "Remembering")
            return (
                .bookmarkSimple, title, (a["content"] ?? a["new_text"] ?? a["old_text"]).map { String($0.prefix(100)) }
            )
        case "skill_view": return (.sparkle, "Using skill \(a["name"] ?? "")".trimmingCharacters(in: .whitespaces), nil)
        case "image_generate":
            return (
                .image, isComplete ? "Image ready" : "Generating an image", a["prompt"].map { String($0.prefix(90)) }
            )
        case "vision_analyze": return (.eye, "Looking at an image", a["question"])
        case "delegate_task": return (.robot, "Delegating", nil)
        case "todo", "todo_list", "todo_write": return (.listChecks, "Updating the plan", nil)
        case "cronjob", "cronjob_manage": return (.calendarCheck, "Scheduling", a["action"])
        case "clarify": return (.chatCircleText, "Asking you", nil)
        case "execute_code": return (.code, "Running code", nil)
        case "text_to_speech": return (.waveform, "Speaking", nil)
        default:
            if lower.contains("send") || lower.hasSuffix("_dm") {
                let to = a["to"] ?? a["target"] ?? a["recipient"] ?? a["chat_id"] ?? a["channel"] ?? a["user"]
                let text = a["message"] ?? a["text"] ?? a["content"]
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

    /// Tools with their own HUD card, kept out of the pills.
    static func hasCard(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("browser_") || ["web_search", "terminal", "image_generate"].contains(lower)
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
    let lastLine: String?
    let exitCode: Int?
    let duration: TimeInterval?
    let tests: TestSummary?
    let isBusy: Bool
    let updatedAt: Date

    init?(calls: [ActiveToolCall]) {
        guard let call = calls.last(where: { $0.name.lowercased() == "terminal" }) else { return nil }
        command = call.args?["command"] ?? call.input
        let output = ToolText.field("output", in: call.result) ?? call.result ?? ""
        lastLine = output.split(whereSeparator: \.isNewline)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { String($0.trimmingCharacters(in: .whitespaces).prefix(120)) }
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

/// The large cards beside the orb, newest first.
struct VoiceHUDState: Equatable {
    enum Card: Equatable, Identifiable {
        case browser(BrowserSession)
        case search(SearchFan)
        case terminal(TerminalTicker)
        case media(GeneratedMedia)

        var id: String {
            switch self {
            case .browser: "browser"
            case .search: "search"
            case .terminal: "terminal"
            case .media: "media"
            }
        }

        var updatedAt: Date {
            switch self {
            case .browser(let card): card.updatedAt
            case .search(let card): card.updatedAt
            case .terminal(let card): card.updatedAt
            case .media(let card): card.updatedAt
            }
        }

        var isBusy: Bool {
            switch self {
            case .browser(let card): card.isBusy
            case .search(let card): card.isBusy
            case .terminal(let card): card.isBusy
            case .media: false
            }
        }
    }

    static let limit = 2
    /// Finished cards fade this long after their last update.
    static let lingering: TimeInterval = 90

    var cards: [Card] = []

    init(calls: [ActiveToolCall] = []) {
        let all: [Card?] = [
            BrowserSession(calls: calls).map(Card.browser),
            SearchFan(calls: calls).map(Card.search),
            TerminalTicker(calls: calls).map(Card.terminal),
            GeneratedMedia(calls: calls).map(Card.media),
        ]
        cards = Array(all.compactMap { $0 }.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.limit))
    }

    func visible(at now: Date) -> [Card] {
        cards.filter { $0.isBusy || now.timeIntervalSince($0.updatedAt) < Self.lingering }
    }
}

// MARK: - Views

extension View {
    fileprivate func hudCard(tint: Color = .dockAccent) -> some View {
        padding(12)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.paneRadius + 4, style: .continuous)
                    .dockSurfaceFill(
                        Color.dockSurface6.opacity(0.94), stroke: tint.opacity(0.3), lineWidth: 0.6, strokeOnGlass: true
                    )
            )
            .shadow(color: tint.opacity(0.18), radius: 16)
    }
}

private struct HUDHeader: View {
    let icon: Ph
    let title: String
    var detail: String?
    var isBusy = false
    var opens = false
    var tint: Color = .dockAccent

    var body: some View {
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
                        .dockFont(size: 10.5)
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

/// Browser, search, terminal and image cards beside the orb.
struct VoiceHUDDeck: View {
    let state: VoiceHUDState
    var width: CGFloat = 300

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 12) {
                ForEach(state.visible(at: context.date)) { card in
                    Group {
                        switch card {
                        case .browser(let browser): BrowserCard(browser: browser)
                        case .search(let search): SearchCard(search: search)
                        case .terminal(let terminal): TerminalCard(terminal: terminal)
                        case .media(let media): MediaCard(media: media)
                        }
                    }
                    .frame(width: width)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: state.visible(at: context.date).map(\.id))
        }
    }
}

private struct BrowserCard: View {
    let browser: BrowserSession
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                browser.url.map(ArtifactOpener.open)
            } label: {
                HUDHeader(
                    icon: .globe, title: browser.title ?? "Browser", detail: ToolStep.host(browser.url),
                    isBusy: browser.isBusy, opens: browser.url != nil)
            }
            .buttonStyle(.dockHover)
            .help(browser.url ?? "")
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 130)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if browser.hosts.count > 1 {
                HStack(spacing: 4) {
                    ForEach(Array(browser.hosts.enumerated()), id: \.offset) { index, host in
                        let isCurrent = index == browser.hosts.count - 1
                        Text(host)
                            .dockFont(.compactStatus, weight: isCurrent ? .semibold : .regular)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
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
        .hudCard()
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
                            .dockFont(size: 11.5, weight: .medium)
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(1)
                        Text(ToolStep.host(hit.url) ?? hit.url)
                            .dockFont(.compactStatus, weight: .regular)
                            .foregroundStyle(Color.dockAccent)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
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
        .hudCard()
    }
}

private struct TerminalCard: View {
    let terminal: TerminalTicker

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
            Text("$ " + terminal.command)
                .dockFont(.metadata, weight: .regular, design: .monospaced)
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(2)
            if let line = terminal.lastLine {
                Text(line)
                    .dockFont(size: 10.5, design: .monospaced)
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
        .hudCard(tint: tint)
    }
}

private struct MediaCard: View {
    let media: GeneratedMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                ArtifactOpener.open(media.source)
            } label: {
                HUDHeader(icon: .image, title: "Image ready", detail: media.prompt, opens: true, tint: .dockSuccess)
            }
            .buttonStyle(.dockHover)
            Group {
                if let url = media.fileURL {
                    AttachmentThumbnailView(url: url)
                } else if let url = URL(string: media.source), media.source.hasPrefix("http") {
                    AsyncImage(url: url) {
                        $0.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        ProgressView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 180)
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

/// Repo, elapsed time with steps, and the plan's progress, above the orb.
struct VoiceStatusStrip: View {
    @ObservedObject var model: DockModel
    let repositoryPath: String?
    @State private var branch: String?

    var body: some View {
        HStack(spacing: 8) {
            if let repositoryPath {
                chip(
                    icon: .gitBranch,
                    text: ([(repositoryPath as NSString).lastPathComponent, branch].compactMap { $0 }).joined(
                        separator: " · ")
                )
                .help(repositoryPath)
            }
            if model.status == .working, let start = turnStart {
                TimelineView(.dockMotion(rate: 1)) { context in
                    let elapsed = Int(context.date.timeIntervalSince(start))
                    let steps = model.activeToolCalls.filter { !$0.name.hasPrefix("__") }.count
                    chip(
                        icon: .timer,
                        text: String(format: "%d:%02d", elapsed / 60, elapsed % 60)
                            + (steps > 0 ? " · \(steps) step\(steps == 1 ? "" : "s")" : ""),
                        tint: elapsed >= 120 ? .dockWarning : .dockAccent)
                }
            }
            if let plan = model.todoPlan, plan.sessionID == model.sessionID, plan.done < plan.items.count,
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
        .task(id: repositoryPath) { branch = repositoryPath.flatMap(Self.branch(in:)) }
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

    /// The checked-out branch, read from `.git/HEAD`.
    static func branch(in repository: String) -> String? {
        guard let head = try? String(contentsOfFile: repository + "/.git/HEAD", encoding: .utf8) else { return nil }
        let ref = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return ref.hasPrefix("ref: refs/heads/") ? String(ref.dropFirst(16)) : String(ref.prefix(7))
    }
}

private struct ChipStyle: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .dockFont(.metadata, weight: .medium)
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.dockSurface6.opacity(0.9)).stroke(tint.opacity(0.3), lineWidth: 0.6))
    }
}

/// Running subagents as small orbs that pulse while they work.
struct VoiceSubagentOrbs: View {
    let agents: [HermesSubagent]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(agents.prefix(6), id: \.id) { agent in
                let running = !["completed", "complete", "done", "failed", "error", "cancelled"].contains(
                    agent.status.lowercased())
                let tint: Color =
                    agent.status.lowercased().contains("fail") || agent.status == "error"
                    ? .dockDestructive
                    : running ? .dockAccent : .dockSuccess
                VStack(spacing: 4) {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [tint, tint.opacity(0.2)], center: .center, startRadius: 1, endRadius: 11)
                        )
                        .frame(width: 18, height: 18)
                        .shadow(color: tint.opacity(0.6), radius: running ? 8 : 3)
                        .phaseAnimator(running ? [false, true] : [false]) { orb, pulse in
                            orb.scaleEffect(pulse ? 1.15 : 0.9)
                        }
                    Text(agent.name ?? "Agent")
                        .dockFont(size: 9.5, weight: .medium)
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: 70)
                }
                .help(agent.latestActivity ?? agent.goal)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4), value: agents.map(\.id))
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
