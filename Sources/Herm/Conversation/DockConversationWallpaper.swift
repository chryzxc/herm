import SwiftUI
import WebKit

/// Only a visible conversation with embedded artwork needs a WebKit surface.
struct DockConversationWallpaper: View {
    @DockChromeTheme private var theme

    var body: some View {
        if let svg = theme.importedTheme?.conversationWallpaper {
            DockWallpaperImage(svg: svg)
                .opacity(0.45)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// WebKit renders SVG image animations. The fixed document has no scripts,
/// navigation, storage shared with other views, or access to remote assets.
struct DockWallpaperImage: NSViewRepresentable {
    let svg: Data

    private final class BackgroundView: WKWebView {
        override var acceptsFirstResponder: Bool { false }
        override var canBecomeKeyView: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        var loaded: Data?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = BackgroundView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != svg else { return }
        context.coordinator.loaded = svg
        view.loadHTMLString(Self.document(svg: svg), baseURL: nil)
    }

    static func document(svg: Data) -> String {
        """
        <!doctype html><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body,img{margin:0;width:100%;height:100%;overflow:hidden}img{display:block;object-fit:cover;object-position:center bottom}</style>
        <img alt="" draggable="false" src="data:image/svg+xml;base64,\(svg.base64EncodedString())">
        """
    }
}
