import Foundation

/// Transient navigation feedback, owned by each live browser tab.
struct BrowserNavigationState: Equatable {
  var isLoading = false
  var canGoBack = false
  var canGoForward = false
  var error: String?

  mutating func start() {
    isLoading = true
    error = nil
  }

  mutating func finish() { isLoading = false }

  mutating func fail(_ message: String) {
    isLoading = false
    error = message
  }

  mutating func updateHistory(_ result: [String: Any]) {
    guard let index = result["currentIndex"] as? Int,
      let entries = result["entries"] as? [[String: Any]],
      entries.indices.contains(index)
    else {
      canGoBack = false
      canGoForward = false
      return
    }
    canGoBack = index > 0
    canGoForward = index < entries.count - 1
  }

  /// Subframe loads must never replace the top-level page's feedback.
  mutating func receiveCDP(_ method: String, params: [String: Any], mainFrameID: String?) {
    switch method {
    case "Page.frameStartedLoading":
      guard let mainFrameID, params["frameId"] as? String == mainFrameID else { return }
      start()
    case "Page.frameStoppedLoading", "Page.navigatedWithinDocument":
      guard let mainFrameID, params["frameId"] as? String == mainFrameID else { return }
      finish()
    case "Page.frameNavigated":
      guard let frame = params["frame"] as? [String: Any], frame["parentId"] == nil else { return }
      if let unreachable = frame["unreachableUrl"] as? String, !unreachable.isEmpty {
        fail("The page couldn’t be loaded. Check the address and connection, then try again.")
      }
    default: break
    }
  }
}

enum BrowserAddress {
  static func url(for input: String) -> URL? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if text.contains("://") {
      guard let url = URL(string: text),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
        let host = url.host, !host.isEmpty
      else { return nil }
      return url
    }
    if !text.contains(where: \.isWhitespace),
      let components = URLComponents(string: "http://\(text)"), let host = components.host
    {
      let loopback =
        host.lowercased() == "localhost" || host.lowercased().hasSuffix(".localhost")
        || host == "127.0.0.1" || host == "[::1]" || host == "::1"
      if loopback { return components.url }
      if host.contains(".") { return URL(string: "https://\(text)") }
    }
    var search = URLComponents(string: "https://www.google.com/search")!
    search.queryItems = [URLQueryItem(name: "q", value: text)]
    return search.url
  }
}
