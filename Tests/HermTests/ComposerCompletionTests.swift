import Foundation
import Testing
@testable import Herm

struct ComposerCompletionTests {
    @Test func detectsSlashAndMentionTriggers() {
        #expect(ComposerCompletionTrigger.detect(in: "/he") == .slash("/he"))
        #expect(ComposerCompletionTrigger.detect(in: "/personality al") == .slash("/personality al"))
        #expect(ComposerCompletionTrigger.detect(in: "/goal\nmore") == nil)
        #expect(ComposerCompletionTrigger.detect(in: "look at @src/ma") == .mention("@src/ma"))
        #expect(ComposerCompletionTrigger.detect(in: "plain text") == nil)
    }

    @Test func parsesSubmittedSlashCommands() {
        #expect(ComposerSlashCommand("/Goal ship it ") == ComposerSlashCommand("/goal ship it"))
        #expect(ComposerSlashCommand("/goal ship it")?.arg == "ship it")
        #expect(ComposerSlashCommand("/usr/local/bin is weird") == nil)
        #expect(ComposerSlashCommand("/ nothing") == nil)
        #expect(ComposerSlashCommand("hello /help") == nil)
    }

    @Test func slashRowsHideNonDesktopCommandsAndGroupCommandsFirst() {
        let payload: [String: Any] = ["replace_from": 1, "items": [
            ["text": "work", "meta": "skill", "kind": "skill"],
            ["text": "/help", "meta": "help", "kind": "command"],
            ["text": "/quit", "kind": "command"],
        ]]
        let result = ComposerCompletion.slashResult(from: payload) { $0 == "/quit" }
        #expect(result.items.map(\.display) == ["/help", "/work"])
        #expect(result.items.map(\.group) == ["Commands", "Skills"])
    }

    @Test func acceptingReplacesOnlyTheActiveToken() {
        let command = ComposerCompletionItem(text: "help", display: "/help", meta: "", group: "Commands")
        let accepted = ComposerCompletion.accepting(command, trigger: .slash("/he"), in: "/he", replaceFrom: 1)
        #expect(accepted.text == "/help ")
        #expect(accepted.keepOpen)

        let option = ComposerCompletionItem(text: "alice", display: "alice", meta: "", group: "Options")
        let picked = ComposerCompletion.accepting(option, trigger: .slash("/personality al"), in: "/personality al", replaceFrom: 13)
        #expect(picked.text == "/personality alice ")
        #expect(!picked.keepOpen)

        let folder = ComposerCompletionItem(text: "@folder:Sources/", display: "Sources/", meta: "dir", group: "")
        let drilled = ComposerCompletion.accepting(folder, trigger: .mention("@Sou"), in: "see @Sou", replaceFrom: 1)
        #expect(drilled.text == "see @folder:Sources/")
        #expect(drilled.keepOpen)

        let file = ComposerCompletionItem(text: "@file:README.md", display: "README.md", meta: "", group: "")
        #expect(ComposerCompletion.accepting(file, trigger: .mention("@READ"), in: "see @READ", replaceFrom: 1).text == "see @file:README.md ")
    }

    @Test func mentionRowsPutBotsFirstWithoutDuplicates() {
        let bots = [ComposerCompletionItem(text: "@coder", display: "@coder", meta: "Coder", group: "")]
        let payload: [String: Any] = ["items": [["text": "@coder", "meta": "agent profile"], ["text": "@diff", "meta": "git diff"]]]
        #expect(ComposerCompletion.mentionResult(from: payload, bots: bots).items.map(\.meta) == ["Coder", "git diff"])
    }

    @Test func caretTextDetectsInlineSkillsAfterACommand() {
        #expect(ComposerCompletionTrigger.detect(in: "/work /cle") == .skill("/cle"))
        #expect(ComposerCompletionTrigger.detect(in: "tidy with /") == .skill("/"))
        #expect(ComposerCompletionTrigger.detect(in: "see /usr/lo") == nil)
        let skill = ComposerCompletionItem(text: "clean", display: "/clean", meta: "", group: "Skills")
        #expect(ComposerCompletion.accepting(skill, trigger: .skill("/cl"), in: "tidy with /cl", replaceFrom: 1).text == "tidy with /clean ")
    }

    @Test func bareSlashRefsBecomeTypedRefs() {
        #expect(ComposerCompletion.pathifyingBareRefs("read @src/app.ts and @docs/") == "read @file:src/app.ts and @folder:docs/")
        #expect(ComposerCompletion.pathifyingBareRefs("ask @coder, @file:a/b, a@b/c") == "ask @coder, @file:a/b, a@b/c")
    }

    @Test func slashTokensSkipPathsAndProse() {
        let text = "/work tidy /clean then see /usr/bin, a/b, /a.txt and /model."
        let ns = text as NSString
        #expect(SlashCommandTokens.ranges(in: text).map(ns.substring) == ["/work", "/clean", "/model"])
    }

    @Test func slashTokensIncludeNamespacedSkillsAndCommands() {
        let text = "🚀 merge it as well /cpipe:run, then /plugin-name:skill_name and /plugin:group:run.\n/help: see /usr/bin and /plugin:run/file.txt"
        let ns = text as NSString
        #expect(SlashCommandTokens.ranges(in: text).map(ns.substring) == [
            "/cpipe:run", "/plugin-name:skill_name", "/plugin:group:run", "/help",
        ])
    }
}
