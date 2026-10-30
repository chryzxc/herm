import SwiftUI

/// One row of the composer's `/` or `@` popover, shaped from Hermes'
/// `complete.slash` / `complete.path` rows (the same RPCs Hermes desktop uses).
struct ComposerCompletionItem: Identifiable, Equatable {
    /// Gateway `text`: what picking the row inserts.
    let text: String
    let display: String
    let meta: String
    /// Section header; rows sharing one render under a single header.
    let group: String
    /// Roster Bot behind an `@handle` row, shown with its avatar.
    var bot: BotSummary? = nil

    var id: String { "\(group)|\(text)" }
}

enum ComposerCompletionTrigger: Hashable {
    /// The draft is a slash command being typed: the command token or its argument.
    case slash(String)
    /// A `/skill` reference dropped mid-message; desktop offers skills only here.
    case skill(String)
    /// A trailing `@token` being typed.
    case mention(String)

    /// Detects against the text before the caret, like desktop's `detectTrigger`.
    /// The inline `/skill` shape is tested first so `/work /cle` completes the
    /// second slash instead of treating it as the first command's argument.
    static func detect(in text: String) -> ComposerCompletionTrigger? {
        if let inline = text.firstMatch(of: #/\s(\/(?:[a-zA-Z][\w-]*)?)$/#) { return .skill(String(inline.1)) }
        if text.hasPrefix("/"), !text.contains(where: \.isNewline) { return .slash(text) }
        if let token = ComposerMentionPresentation.activeToken(in: text) { return .mention(token) }
        return nil
    }
}

/// A submitted `/name arg` line. `/usr/local` is a path, not a `/usr` command,
/// matching Hermes desktop's `SLASH_COMMAND_RE`.
struct ComposerSlashCommand: Equatable {
    let name: String
    let arg: String

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let token = body.prefix { !$0.isWhitespace }
        guard let first = token.first, first.isLetter,
            token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        else { return nil }
        name = token.lowercased()
        arg = body.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `/command` and inline `/skill` tokens, highlighted in the composer and in
/// sent messages. Paths (`/usr/bin`, `/a.txt`) and `and/or` are not tokens.
enum SlashCommandTokens {
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<!\S)/[A-Za-z][\w-]*(?::[\w-]+)*(?![\w/-]|:[\w-]|\.\w)"#)

    static func ranges(in text: String) -> [NSRange] {
        guard text.contains("/") else { return [] }
        return pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }
}

enum ComposerCompletion {
    /// Hermes' TUI-only display toggles that `complete.slash` still appends.
    static let terminalOnlyCommands: Set<String> = ["/density", "/details", "/logs", "/mouse"]

    struct Result: Equatable {
        var items: [ComposerCompletionItem] = []
        /// `complete.slash` offset (in characters) where the picked row's text goes.
        var replaceFrom = 1
    }

    /// `complete.slash` rows, minus commands Hermes marks as having no desktop
    /// surface, with Commands before Skills like the desktop popover.
    static func slashResult(from payload: [String: Any], hidden: (String) -> Bool) -> Result {
        let replaceFrom = payload["replace_from"] as? Int ?? 1
        let isArgument = replaceFrom > 1
        let rows = payload["items"] as? [[String: Any]] ?? []
        let items = rows.compactMap { row -> ComposerCompletionItem? in
            guard let text = row["text"] as? String, !text.isEmpty else { return nil }
            let command = text.hasPrefix("/") ? text : "/\(text)"
            if !isArgument, hidden(command.lowercased()) { return nil }
            return ComposerCompletionItem(
                text: text,
                display: isArgument ? (row["display"] as? String ?? text) : command,
                meta: row["meta"] as? String ?? "",
                group: isArgument ? "Options" : (row["kind"] as? String == "skill" ? "Skills" : "Commands")
            )
        }
        let order = ["Commands", "Skills", "Options"]
        let sorted = items.enumerated().sorted {
            let lhs = order.firstIndex(of: $0.element.group) ?? 0
            let rhs = order.firstIndex(of: $1.element.group) ?? 0
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
        return Result(items: sorted, replaceFrom: replaceFrom)
    }

    /// `complete.path` rows with roster Bots ahead, deduplicated by handle
    /// (Hermes lists profiles as `@name` too).
    static func mentionResult(from payload: [String: Any], bots: [ComposerCompletionItem]) -> Result {
        let rows = (payload["items"] as? [[String: Any]] ?? []).compactMap { row -> ComposerCompletionItem? in
            guard let text = row["text"] as? String, !text.isEmpty else { return nil }
            if let canonical = bots.first(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
                return canonical
            }
            let namedBots = bots.filter { item in
                item.bot.map { "@\($0.name)".caseInsensitiveCompare(text) == .orderedSame } == true
            }
            if namedBots.count == 1 { return namedBots[0] }
            return ComposerCompletionItem(
                text: text, display: row["display"] as? String ?? text, meta: row["meta"] as? String ?? "", group: "")
        }
        var seen = Set<String>()
        let items = (bots + rows).filter { seen.insert($0.text.lowercased()).inserted }
        return Result(items: items)
    }

    /// Hand-typed `@src/app.ts` / `@src/` become `@file:` / `@folder:` refs on
    /// send, like desktop's `pathifyRefs`. A `/` is required so `@name`
    /// handles stay Bot mentions.
    static func pathifyingBareRefs(_ text: String) -> String {
        text.replacing(
            #/(^|[^\w@\/])@((?!(?:file|folder|url|image|tool|line|terminal|session|git):)[^\s@:]*\/[^\s@:]*)/#
        ) { match in
            let (lead, path) = (match.1, match.2)
            return lead + (path.hasSuffix("/") ? "@folder:" : "@file:") + path
        }
    }

    /// The draft after picking `item`, and whether the popover should stay open
    /// (a folder or an `@file:` starter keeps drilling down, like desktop's Tab).
    static func accepting(
        _ item: ComposerCompletionItem,
        trigger: ComposerCompletionTrigger,
        in text: String,
        replaceFrom: Int
    ) -> (text: String, keepOpen: Bool) {
        switch trigger {
        case .slash:
            let prefix = String(text.prefix(max(0, replaceFrom)))
            let insert = prefix.hasSuffix("/") && item.text.hasPrefix("/") ? String(item.text.dropFirst()) : item.text
            // A picked command stays open for its argument options; a picked option is final.
            return (prefix + insert + " ", replaceFrom <= 1)
        case .skill(let token):
            let name = item.text.hasPrefix("/") ? item.text : "/\(item.text)"
            return (String(text.dropLast(token.count)) + name + " ", false)
        case .mention(let token):
            let keepOpen = item.text.hasSuffix("/") || item.text.hasSuffix(":")
            return (String(text.dropLast(token.count)) + item.text + (keepOpen ? "" : " "), keepOpen)
        }
    }
}

/// Keyboard-driven `/` and `@` popover above the composer.
struct ComposerCompletionPopover: View {
    let trigger: ComposerCompletionTrigger
    let items: [ComposerCompletionItem]
    let selectedIndex: Int
    var avatarImages: [String: Data] = [:]
    /// Replaces the key hints when a picked Bot would not be reached.
    var notice: String? = nil
    let onSelect: (ComposerCompletionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if !item.group.isEmpty, index == 0 || items[index - 1].group != item.group {
                                Text(item.group.uppercased())
                                    .dockFont(.compactStatus, weight: .semibold, design: .monospaced)
                                    .tracking(0.6)
                                    .foregroundStyle(Color.dockMetadataText)
                                    .dockPadding(.horizontal, 12)
                                    .dockPadding(.top, index == 0 ? 8 : 10)
                                    .dockPadding(.bottom, 4)
                            }
                            row(item, isSelected: index == selectedIndex)
                                .id(item.id)
                        }
                    }
                }
                .onChange(of: selectedIndex) { _, index in
                    guard items.indices.contains(index) else { return }
                    proxy.scrollTo(items[index].id)
                }
            }
            .frame(maxHeight: 280)

            Text(notice ?? "↑↓ to navigate · ↩ or ⇥ to select · esc to dismiss")
                .dockFont(.compactStatus, weight: .regular)
                .foregroundStyle(notice == nil ? Color.dockMetadataText : Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dockPadding(.horizontal, 12)
                .dockPadding(.vertical, 6)
                .dockPaneTint(Color.dockSurface6.opacity(0.5))
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .dockFloatingSurface(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous), stroke: .clear
        )
        .overlay {
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline)
        }
        .shadow(color: .black.opacity(DockThemeStyle.current.material == .glass ? 0 : 0.18), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            {
                if case .mention = trigger { return "Mentions and references" }
                return "Slash commands"
            }())
    }

    private func row(_ item: ComposerCompletionItem, isSelected: Bool) -> some View {
        Button {
            onSelect(item)
        } label: {
            HStack(spacing: 10) {
                if let bot = item.bot {
                    BotAvatarView(bot: bot, imageData: avatarImages[bot.id], size: 18, orbits: false)
                }
                Text(item.display)
                    .dockFont(.body, weight: .medium, design: .monospaced)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                if !item.meta.isEmpty {
                    Text(item.meta)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .dockPadding(.horizontal, 12)
            .dockPadding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.dockAccent.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
