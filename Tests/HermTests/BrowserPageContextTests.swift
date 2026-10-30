import Foundation
import Testing

@testable import Herm

@MainActor
struct BrowserPageContextTests {
    @Test func snapshotIncludesTabAndSelectionWithoutInventingAgentAccess() {
        let context = BrowserPageContext.make(
            url: "https://example.com/page#section", title: "Example", targetID: "tab-2", selection: "Selected words")
        #expect(context.body.contains("Shared browser tab ID: tab-2"))
        #expect(context.body.contains("https://example.com/page#section"))
        #expect(context.body.contains("Selected words"))
        #expect(context.body.contains("untrusted"))
        let fallback = BrowserPageContext.make(url: "https://example.com", title: "", targetID: nil, selection: "")
        #expect(!fallback.body.contains("Shared browser tab"))
        #expect(!fallback.body.contains("Selected text:"))
        #expect(fallback.title == "example.com")
    }

    @Test func attachingPreservesDraftAndRefreshesOneRemovableChipWithoutSending() throws {
        let model = DockModel(initialSessionID: "browser-context")
        let key = try #require(model.browserSessionKey)
        model.draft = "Explain this error"
        let count = model.messages.count
        let first = BrowserPageContext.make(
            url: "https://example.com", title: "Page", targetID: "tab", selection: "old")
        model.attachBrowserPage(first, owner: key)
        model.attachBrowserPage(
            BrowserPageContext.make(url: "https://example.com", title: "Page", targetID: "tab", selection: "new"),
            owner: key)
        #expect(model.attachedContexts.count == 1)
        #expect(model.attachedContexts[0].body.contains("new"))
        #expect(model.draft == "Explain this error")
        #expect(model.messages.count == count)
        #expect(!model.isSending)
        model.removeAttachedContext(first)
        #expect(model.attachedContexts.isEmpty)
    }

    @Test func staleSessionCannotAttachToAnotherConversation() {
        let model = DockModel(initialSessionID: "current")
        model.attachBrowserPage(
            BrowserPageContext.make(url: "https://example.com", title: "Page", targetID: nil, selection: ""),
            owner: .init(profileID: nil, sessionID: "previous"))
        #expect(model.attachedContexts.isEmpty)
    }

    @Test func hermBrowserPreferenceGuardsExternalOpensOnlyWhileOn() throws {
        let name = "BrowserPreference-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AgentBrowser.opensInHerm(defaults: defaults))
        let surface = AgentBrowser.agentSurface(defaults: defaults)
        #expect(surface.rules.contains("available Hermes browser tools"))
        #expect(!surface.rules.contains("browser_navigate"))
        #expect(!surface.rules.contains("browser_snapshot"))
        let guards = surface.guards
        func blocked(_ command: String) -> Bool {
            guards.contains { rule in
                let regex = try? NSRegularExpression(pattern: rule.pattern, options: .caseInsensitive)
                return regex?.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
            }
        }
        #expect(blocked(#"open -a "Google Chrome" "https://example.com/dashboard""#))
        #expect(blocked("open https://example.com"))
        #expect(blocked("cd app && open -a Safari"))
        #expect(!blocked("curl https://example.com"))
        #expect(!blocked("git log --grep open"))
        #expect(!blocked("open ."))
        #expect(guards.contains { $0.tool == "computer_use" && $0.argument == "app" && $0.pattern.contains("chrome") })

        defaults.set(false, forKey: AgentBrowser.openInHermKey)
        #expect(!AgentBrowser.opensInHerm(defaults: defaults))
        #expect(AgentBrowser.agentSurface(defaults: defaults).guards.isEmpty)
    }
}
