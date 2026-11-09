import SwiftUI

/// Hermes' inline widget contract (`::preview{file="path.html"}`): the agent writes an HTML file and the
/// reply frames it live, offline and sandboxed. Matches Hermes Desktop's sizing and `hermes.send` channel.
enum HermesInlinePreview {
    static let minHeight: CGFloat = 120
    static let maxHeight: CGFloat = 1200
    static let maxPromptLength = 500
    static let maxFileBytes = 2 * 1_048_576

    /// A local HTML file path, or nil when the target belongs on an attachment card.
    static func htmlURL(_ file: String) -> URL? {
        guard file.hasPrefix("/") || file.hasPrefix("~/") || file.hasPrefix("file://"),
            let url = ArtifactOpener.url(file), url.isFileURL,
            ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased())
        else { return nil }
        return url
    }

    nonisolated static func load(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFileBytes,
            let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }

    /// Hermes' frame defaults go first so the widget's own styles win; scripts run after its markup.
    static func document(_ html: String) -> String {
        let prelude = "<style>html,body{margin:0;padding:0;color:var(--foreground,inherit);}</style>"
        guard let close = html.range(of: "</body", options: [.caseInsensitive, .backwards]) else {
            return prelude + html + script
        }
        return prelude + html[..<close.lowerBound] + script + html[close.lowerBound...]
    }

    /// Reports content height and exposes `window.hermes.send` / `data-hermes-send`, acked by Herm.
    static let script = """
        <script>(function(){var last=0;function post(){var b=document.body,d=document.documentElement;\
        var h=b?b.scrollHeight:(d?d.scrollHeight:0);if(Math.abs(h-last)>1){last=h;\
        parent.postMessage({type:'hermes-inline-preview-size',height:h},'*')}}\
        if(typeof ResizeObserver==='function'){var ro=new ResizeObserver(post);ro.observe(document.documentElement);\
        if(document.body)ro.observe(document.body)}addEventListener('load',post);post();\
        var n=0,w={};addEventListener('message',function(e){var d=e.data;\
        if(e.source!==parent||!d||d.type!=='hermes-inline-preview-intent-ack'||!w[d.id])return;\
        var r=w[d.id];delete w[d.id];r(d.ack)});\
        function send(p){if(typeof p!=='string'||!p.trim())return Promise.resolve({ok:false,error:'invalid'});\
        var id=++n;return new Promise(function(res){var k=setTimeout(function(){if(w[id]){delete w[id];\
        res({ok:false,error:'undelivered'})}},30000);w[id]=function(a){clearTimeout(k);res(a)};\
        parent.postMessage({type:'hermes-inline-preview-intent',id:id,prompt:p},'*')})}\
        window.hermes={send:send,maxLength:\(maxPromptLength)};\
        addEventListener('click',function(e){var el=e.target&&e.target.closest?e.target.closest('[data-hermes-send]'):null;\
        if(el)send(el.getAttribute('data-hermes-send')||'')},true)})()</script>
        """
}

/// Host side of a widget frame: sizes it and turns accepted intents into a user turn in its session.
@MainActor
final class HermesPreviewBridge: GeneratedHTMLBridge {
    var send: (([String: Any]) -> Void)?
    var resize: ((CGFloat) -> Void)?
    var submit: ((String) async -> Bool)?
    var now: () -> Date = Date.init
    private var lastIntent: Date?

    func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "hermes-inline-preview-size":
            if let height = (message["height"] as? NSNumber)?.doubleValue, height.isFinite, height > 0 {
                resize?(min(max(CGFloat(height), HermesInlinePreview.minHeight), HermesInlinePreview.maxHeight))
            }
        case "hermes-inline-preview-intent":
            guard let id = message["id"] as? Int else { return }
            let prompt = (message["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if prompt.isEmpty { return ack(id, ["ok": false, "error": "invalid"]) }
            if prompt.count > HermesInlinePreview.maxPromptLength {
                return ack(id, ["ok": false, "error": "too_long", "maxLength": HermesInlinePreview.maxPromptLength])
            }
            let time = now()
            if let lastIntent, time.timeIntervalSince(lastIntent) < 1 {
                let wait = Int(((1 - time.timeIntervalSince(lastIntent)) * 1000).rounded())
                return ack(id, ["ok": false, "error": "throttled", "retryAfterMs": wait])
            }
            lastIntent = time
            Task {
                let delivered = await submit?(prompt) ?? false
                ack(id, delivered ? ["ok": true] : ["ok": false, "error": "undelivered"])
            }
        default:
            break
        }
    }

    private func ack(_ id: Int, _ ack: [String: Any]) {
        send?(["type": "hermes-inline-preview-intent-ack", "id": id, "ack": ack])
    }
}

struct HermesInlinePreviewView: View {
    let file: String
    @Environment(\.richReplyContext) private var context
    @State private var html: String?
    @State private var loaded = false
    @State private var height: CGFloat = 280
    @StateObject private var state = GeneratedHTMLLoadState()

    var body: some View {
        if let url = HermesInlinePreview.htmlURL(file) {
            Group {
                if let html, state.error == nil {
                    GeneratedHTMLWebView(
                        html: html, state: state, bridge: bridge(),
                        passesScroll: height < HermesInlinePreview.maxHeight
                    )
                    .id(DockThemeRuntime.revision)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous))
                    .accessibilityLabel(url.lastPathComponent)
                } else if loaded {
                    ChatMediaAttachmentCard(path: file)
                } else {
                    Color.clear.frame(height: height)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: file) {
                html = await Task.detached(priority: .utility) { HermesInlinePreview.load(url) }.value
                    .map(HermesInlinePreview.document)
                loaded = true
            }
        } else {
            ChatMediaAttachmentCard(path: file)
        }
    }

    private func bridge() -> HermesPreviewBridge {
        let bridge = HermesPreviewBridge()
        bridge.resize = { height = $0 }
        let context = context
        bridge.submit = { prompt in
            guard let context, context.isCurrent, let model = context.model else { return false }
            var record = QuickDraftRecord(destination: context.destination, text: prompt)
            record.requestsVisualReply = false
            return (try? await model.submitQuickDraft(record) { _ in }) != nil
        }
        return bridge
    }
}
