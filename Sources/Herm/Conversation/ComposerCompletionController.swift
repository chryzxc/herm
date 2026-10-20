import Foundation

/// The `/`, `@` and `$` completion popover state shared by the chat composer
/// and the forward box. The owner supplies the text through `configure`.
@MainActor
final class ComposerCompletionController: ObservableObject {
    @Published private(set) var trigger: ComposerCompletionTrigger?
    @Published private(set) var result = ComposerCompletion.Result()
    @Published private(set) var index = 0

    /// UTF-16 caret the active trigger was detected at.
    private var caret = 0
    private var task: Task<Void, Never>?
    /// Last answer per trigger, shown instantly on reopen. ponytail: unbounded but
    /// one entry per distinct typed token; clear on `configure` if it ever grows.
    private var cache: [ComposerCompletionTrigger: ComposerCompletion.Result] = [:]
    private var model: DockModel?
    private var botMode: BotModeModel?
    private var text: () -> String = { "" }
    /// Replaces the whole text and moves the caret (UTF-16).
    private var apply: (String, Int) -> Void = { _, _ in }
    private var onOpenChanged: (Bool) -> Void = { _ in }
    /// Scopes completions to one bot's commands and files (the forward box).
    private var profileID: String?

    func configure(model: DockModel, botMode: BotModeModel, profileID: String? = nil,
                   text: @escaping () -> String, apply: @escaping (String, Int) -> Void,
                   onOpenChanged: @escaping (Bool) -> Void = { _ in }) {
        self.model = model
        self.botMode = botMode
        self.profileID = profileID
        self.text = text
        self.apply = apply
        self.onOpenChanged = onOpenChanged
    }

    /// Roster Bots offered ahead of Hermes' `@` rows. Typed refs like `@file:` skip them.
    private func botItems(for trigger: ComposerCompletionTrigger) -> [ComposerCompletionItem] {
        guard let botMode, case .mention(let token) = trigger else { return [] }
        let query = token.dropFirst().lowercased()
        guard !query.contains(":"), !query.contains("/") else { return [] }
        return botMode.visibleBots
            .filter { bot in
                query.isEmpty
                    || bot.id.localizedCaseInsensitiveContains(query)
                    || bot.name.localizedCaseInsensitiveContains(query)
                    || (bot.title?.localizedCaseInsensitiveContains(query) == true)
            }
            .map { ComposerCompletionItem(text: "@\($0.id)", display: "@\($0.id)", meta: $0.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", group: "", bot: $0) }
    }

    func update(for text: String, caret: Int) {
        guard let model else { return }
        let wasMention: Bool = { if case .mention = trigger { return true }; return false }()
        let caret = min(caret, (text as NSString).length)
        let detected = ComposerCompletionTrigger.detect(in: (text as NSString).substring(to: caret))
        if detected != nil, detected == trigger, caret == self.caret { return }
        self.caret = caret
        task?.cancel()
        let isFirstKeystroke = trigger == nil
        trigger = detected
        guard let detected else {
            close()
            return
        }
        if case .mention = detected,
           ComposerMentionRefreshPolicy.shouldRefresh(wasPickerVisible: wasMention, isPickerVisible: true) {
            Task { @MainActor [botMode] in await botMode?.refreshNow(force: true) }
        }
        // Show what is already known (local Bots, last RPC answer for this exact
        // trigger) right away; the RPC below replaces it. Only while nothing is
        // open, so a refinement doesn't flash stale rows.
        if isFirstKeystroke {
            let cached = cache[detected] ?? ComposerCompletion.Result(items: botItems(for: detected))
            if !cached.items.isEmpty {
                result = cached
                index = 0
                onOpenChanged(true)
            }
        }
        task = Task { @MainActor in
            // Same debounce as desktop's live completion adapter, skipped on the
            // opening keystroke so the popover isn't held back by it.
            if !isFirstKeystroke { try? await Task.sleep(for: .milliseconds(60)) }
            guard !Task.isCancelled else { return }
            let found = await model.composerCompletions(for: detected, bots: botItems(for: detected), profile: profileID)
            guard !Task.isCancelled, trigger == detected else { return }
            cache[detected] = found
            if found != result {
                result = found
                index = 0
            }
            onOpenChanged(!found.items.isEmpty)
        }
    }

    /// Moving the caret retargets or closes an open popover; only typing opens one.
    func caretMoved(text: String, caret: Int) {
        guard trigger != nil else { return }
        update(for: text, caret: caret)
    }

    func close() {
        task?.cancel()
        trigger = nil
        result = ComposerCompletion.Result()
        index = 0
        onOpenChanged(false)
    }

    /// The draft split at the trigger's caret; completions rewrite only `before`.
    private var split: (before: String, after: String) {
        let text = self.text() as NSString
        let caret = min(self.caret, text.length)
        return (text.substring(to: caret), text.substring(from: caret))
    }

    func accept(_ item: ComposerCompletionItem) {
        guard let trigger else { return }
        let (before, after) = split
        let accepted = ComposerCompletion.accepting(item, trigger: trigger, in: before, replaceFrom: result.replaceFrom)
        let tail = accepted.text.hasSuffix(" ") && after.hasPrefix(" ") ? String(after.dropFirst()) : after
        let caret = (accepted.text as NSString).length
        apply(accepted.text + tail, caret)
        close()
        if accepted.keepOpen { update(for: text(), caret: caret) }
    }

    func handleKey(_ key: ComposerCompletionKey) -> Bool {
        guard trigger != nil, result.items.indices.contains(index) else { return false }
        let count = result.items.count
        switch key {
        case .up, .down:
            index = (index + (key == .down ? 1 : -1) + count) % count
        case .escape:
            close()
        case .tab, .enter:
            let item = result.items[index]
            // Enter on a command that is already fully typed runs it instead of re-inserting it.
            if key == .enter,
               let trigger,
               case let before = split.before,
               ComposerCompletion.accepting(item, trigger: trigger, in: before, replaceFrom: result.replaceFrom)
                .text.trimmingCharacters(in: .whitespaces) == before.trimmingCharacters(in: .whitespaces) {
                close()
                return false
            }
            accept(item)
        }
        return true
    }
}
