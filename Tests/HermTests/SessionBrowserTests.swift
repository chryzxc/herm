import AppKit
import Foundation
import Testing
import WebKit

@testable import Herm

@MainActor
struct SessionBrowserTests {
    @Test func sessionSwitchesRetainBrowsersAndIsolateTheirData() {
        let store = SessionBrowserStore()
        let a = SessionBrowserKey(profileID: nil, sessionID: "a")
        let b = SessionBrowserKey(profileID: nil, sessionID: "b")
        let first = store.workspace(for: a)
        let extra = first.addTab()
        let second = store.workspace(for: b)
        let returned = store.workspace(for: a)

        #expect(returned === first)
        #expect(returned.primary.web === first.primary.web)
        #expect(returned.agent === first.agent)
        #expect(returned.extras.first === extra)
        #expect(first.agent !== second.agent)
        #expect(
            first.primary.web.configuration.websiteDataStore
                !== second.primary.web.configuration.websiteDataStore)
        #expect(
            first.primary.web.configuration.websiteDataStore === extra.web.configuration.websiteDataStore)
        first.closeTab(extra.id)
        #expect(first.extras.isEmpty)
        #expect(store.workspace(for: b) === second)
    }

    @Test func reapsOnlyOrphanedAgentBrowserChromes() {
        let root = "/Users/me/Library/Application Support/Herm/AgentBrowser"
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new"
        let ps = """
              3099     1 \(chrome) --user-data-dir=\(root)/abc --no-first-run
              3148  3099 Google Chrome Helper --user-data-dir=\(root)/abc
             10580 75208 \(chrome) --user-data-dir=\(root)/def
               500     1 \(chrome) --user-data-dir=/tmp/other
               600     1 /usr/sbin/cfprefsd agent
            """
        #expect(AgentBrowser.orphanPIDs(psOutput: ps, profileRoot: root) == [3099])
    }

    @Test func botProfilesHaveSeparateBrowserIdentities() {
        let a = SessionBrowserKey(profileID: "one", sessionID: "chat")
        let b = SessionBrowserKey(profileID: "two", sessionID: "chat")
        let store = SessionBrowserStore()
        #expect(store.workspace(for: a) !== store.workspace(for: b))
        #expect(a.profileDirectory != b.profileDirectory)
        #expect(
            a.profileDirectory == SessionBrowserKey(profileID: "one", sessionID: "chat").profileDirectory)
        #expect(!a.profileDirectory.contains("chat"))
    }

    @Test func runtimeAliasesKeepTheStoredSessionsBrowser() {
        let model = DockModel(initialSessionID: "stored-session")
        let key = model.browserSessionKey
        model.sessionID = "runtime-alias"
        #expect(model.browserSessionKey == key)
    }

    @Test func liveDocumentAndFormSurviveSessionSwitchAndViewRecreation() async throws {
        let store = SessionBrowserStore()
        let a = SessionBrowserKey(profileID: nil, sessionID: "a")
        let first = store.workspace(for: a)
        let tab = first.addTab()
        let web = tab.web
        web.loadHTMLString(
            "<input id='draft'><script>window.pageToken = 'original';</script>", baseURL: nil)
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("window.pageToken")) as? String == "original" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await web.evaluateJavaScript(
            "document.getElementById('draft').value = 'unfinished form'; window.pageToken = 'retained'")
        let model = DockModel(initialSessionID: "a")
        var view: SessionBrowserView? = SessionBrowserView(model: model, workspace: first, browser: tab)
        view = nil
        _ = store.workspace(for: SessionBrowserKey(profileID: nil, sessionID: "b"))
        let returned = store.workspace(for: a)
        view = SessionBrowserView(model: model, workspace: returned, browser: returned.extras[0])
        #expect(view != nil)
        #expect(try await web.evaluateJavaScript("window.pageToken") as? String == "retained")
        #expect(
            try await web.evaluateJavaScript("document.getElementById('draft').value") as? String
                == "unfinished form")
    }

    @Test func chatLinkWhileStartingKeepsItsExactDestination() throws {
        let store = SessionBrowserStore()
        let workspace = store.workspace(for: SessionBrowserKey(profileID: nil, sessionID: "chat"))
        let destination = try #require(
            URL(string: "http://localhost:5173/preview_(draft)?next=%2Ffoo%3Fa%3D1&token=a%2Bb#section-2")
        )
        workspace.primary.address = "https://previous.example/"
        // No model: the asynchronous startup exits before launching Chromium.
        workspace.agent.start()
        workspace.open(destination)
        _ = store.workspace(for: SessionBrowserKey(profileID: nil, sessionID: "other"))
        _ = SessionBrowserView(model: DockModel(initialSessionID: "chat"), workspace: workspace)
        #expect(workspace.agent.pendingURL == destination)
        #expect(workspace.primary.address == destination.absoluteString)
        #expect(workspace.primary.web.url == nil)
    }

    @Test func markdownClicksRouteTheLinkDestinationWithoutReparsingIt() throws {
        let destination = try #require(
            URL(string: "https://example.com/a_(b)?next=%2Fx%3Fy%3D1&token=a%2Bb#part-2"))
        let rendered = NativeMarkdownMessageView.Coordinator.attributedString(
            for: "[Open preview](\(destination.absoluteString))")
        let range = (rendered.string as NSString).range(of: "Open preview")
        let link = try #require(rendered.attribute(.link, at: range.location, effectiveRange: nil))
        let expected = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        #expect(expected == destination)
        var received: URL?
        let observer = NotificationCenter.default.addObserver(
            forName: .hermOpenInBrowser, object: nil, queue: .main
        ) { notification in
            let url = notification.object as? URL
            MainActor.assumeIsolated {
                received = url
                InAppBrowser.handled = true
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        NativeMarkdownTextView().clicked(onLink: link, at: range.location)
        #expect(received == destination)
        received = nil
        NativeMarkdownTextSectionView().clicked(onLink: link, at: range.location)
        #expect(received == destination)
    }
}
