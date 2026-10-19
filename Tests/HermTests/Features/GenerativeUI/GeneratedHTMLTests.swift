import AppKit
import Testing
import WebKit

@testable import Herm

@MainActor
struct GeneratedHTMLTests {
  @Test func policiesDenyNavigationAndEscapeAuthoredMarkup() throws {
    let initial = try #require(URL(string: "herm-generated://preview/test"))
    for value in [
      "https://example.com", "http://127.0.0.1:8080", "file:///etc/passwd", "data:text/html,test",
      "herm-generated://preview/other",
    ] {
      #expect(!GeneratedHTMLPolicy.allowsNavigation(URL(string: value), initialURL: initial))
    }
    #expect(GeneratedHTMLPolicy.allowsNavigation(URL(string: "about:srcdoc"), initialURL: initial))
    let wrapper = GeneratedHTMLPolicy.wrapper("\"</iframe><script>escape()</script>", theme: "")
    #expect(wrapper.contains("&lt;/iframe&gt;"))
    #expect(!wrapper.contains("allow-same-origin"))
    #expect(!wrapper.contains("<script>escape()"))
  }

  @Test func realWebKitRunsOfflineAndBlocksForbiddenCapabilities() async throws {
    let authored = """
      <body><button onclick="this.textContent='Worked'">Calculate</button><script>
      (async()=>{
        const result = {computed: 6*7, bridge: !!window.webkit?.messageHandlers?.herm};
        for (const name of ['localStorage','sessionStorage']) {
          try { window[name].setItem('secret','value'); result[name] = false; } catch { result[name] = true; }
        }
        try { parent.document.body; result.parentBlocked = false; } catch { result.parentBlocked = true; }
        result.rtcBlocked = typeof RTCPeerConnection === 'undefined';
        result.workerBlocked = typeof Worker === 'undefined';
        result.popupBlocked = window.open('about:blank') === null;
        for (const [key,url] of Object.entries({external:'https://example.com/test',loopback:'http://127.0.0.1:9/test',file:'file:///etc/passwd'})) {
          try { await fetch(url); result[key] = false; } catch { result[key] = true; }
        }
        parent.postMessage({testResult:result}, '*');
      })();
      </script></body>
      """
    let state = GeneratedHTMLLoadState()
    let coordinator = GeneratedHTMLWebView.Coordinator(html: authored, state: state)
    let web = coordinator.makeWebView()
    // Test-only observer; production exposes no script message handlers or action bridge.
    web.configuration.userContentController.addUserScript(
      WKUserScript(
        source:
          "window.__testResult=null;addEventListener('message',e=>{if(e.data.testResult)window.__testResult=e.data.testResult});",
        injectionTime: .atDocumentStart, forMainFrameOnly: true))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 380, height: 420), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = web
    window.orderFrontRegardless()
    defer {
      GeneratedHTMLWebView.dismantleNSView(web, coordinator: coordinator)
      window.orderOut(nil)
    }
    coordinator.load()
    var result: [String: Any]?
    for _ in 0..<100 {
      try await Task.sleep(for: .milliseconds(100))
      result = try? await web.evaluateJavaScript("window.__testResult") as? [String: Any]
      if result != nil || state.error != nil { break }
    }
    #expect(state.error == nil)
    let values = try #require(result)
    #expect(values["computed"] as? Int == 42)
    #expect(values["bridge"] as? Bool == false)
    for key in [
      "localStorage", "sessionStorage", "parentBlocked", "rtcBlocked", "workerBlocked",
      "popupBlocked", "external", "loopback", "file",
    ] {
      #expect(values[key] as? Bool == true, "Forbidden capability was available: \(key)")
    }
    #expect(!web.configuration.websiteDataStore.isPersistent)
    coordinator.webViewWebContentProcessDidTerminate(web)
    #expect(state.error?.contains("stopped") == true)
  }
  @Test func coordinatorKeepsOnlyOneActivePreview() {
    let coordinator = GeneratedHTMLCoordinator()
    coordinator.open("a")
    coordinator.open("b")
    #expect(coordinator.activeKey == "b")
    coordinator.close()
    #expect(coordinator.activeKey == nil)
  }
}
