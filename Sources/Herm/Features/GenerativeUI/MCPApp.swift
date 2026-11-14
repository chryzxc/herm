import AppKit
import SwiftUI

/// MCP Apps (`io.modelcontextprotocol/ui`): an MCP tool that declares a `ui://` view renders it beside its step.
/// The `herm` plugin caches the view and the call's input/result and adds a `herm.mcp-app.v1` receipt to the result.
enum MCPApp {
    static let schema = "herm.mcp-app.v1"
    static let protocolVersion = "2026-01-26"
    /// Beside `HermAgentSurfaces.fileURL`, where the plugin writes it.
    nonisolated static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
        0
    ]
    .appendingPathComponent("Herm/mcp-apps")

    /// The receipt ID in an MCP tool's result; only the plugin writes this top-level key.
    nonisolated static func receiptID(tool: String, result: String) -> String? {
        guard tool.hasPrefix("mcp__"), result.utf8.count <= 4 * 1_048_576,
            let data = result.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let receipt = payload["herm_app"] as? [String: Any], receipt["schema"] as? String == schema,
            let id = receipt["id"] as? String, isHex(id, length: 32)
        else { return nil }
        return id
    }

    nonisolated static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// One cached call: the view's HTML and what the bridge hands it. nil when this Mac has no cache for it.
    struct Call: Sendable {
        let server: String
        let toolName: String
        let toolTitle: String?
        let html: String
        /// Network domains the view declared in `_meta.ui.csp`; Herm keeps views offline.
        let requestedDomains: [String]
        let arguments: Data
        let result: Data

        var title: String { toolTitle?.isEmpty == false ? toolTitle! : toolName }

        nonisolated static func load(id: String, directory: URL = MCPApp.directory) -> Call? {
            guard isHex(id, length: 32),
                let data = try? Data(contentsOf: directory.appendingPathComponent(id + ".json")),
                let call = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let digest = call["html"] as? String, isHex(digest, length: 64),
                let html = try? String(contentsOf: directory.appendingPathComponent(digest + ".html"), encoding: .utf8),
                let server = call["server"] as? String, let tool = call["tool"] as? [String: Any],
                let name = tool["name"] as? String
            else { return nil }
            let csp = call["csp"] as? [String: Any] ?? [:]
            let domains = ["connectDomains", "resourceDomains", "frameDomains"].flatMap { csp[$0] as? [String] ?? [] }
            func json(_ value: Any?) -> Data {
                guard let value, JSONSerialization.isValidJSONObject(value) else { return Data("{}".utf8) }
                return (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
            }
            return Call(
                server: server, toolName: name, toolTitle: tool["title"] as? String, html: html,
                requestedDomains: Array(Set(domains)).sorted(), arguments: json(call["arguments"]),
                result: json(call["result"]))
        }
    }
}

/// Host side of the MCP Apps postMessage JSON-RPC. Supports initialization, tool input/result, sizing and links;
/// other requests get "method not found" until Herm can route them through existing approval paths.
@MainActor
final class MCPAppBridge: GeneratedHTMLBridge {
    let call: MCPApp.Call
    var send: (([String: Any]) -> Void)?
    var resize: ((CGFloat) -> Void)?
    var openLink: ((URL) -> Void)?
    var authorize: ((GeneratedHTMLActionApproval.Action) async -> Bool)?
    private var active = true
    private var pending = false
    var hostContext: () -> [String: Any]

    init(call: MCPApp.Call, hostContext: @escaping () -> [String: Any]) {
        self.call = call
        self.hostContext = hostContext
    }

    func receive(_ message: [String: Any]) {
        guard active, message["jsonrpc"] as? String == "2.0" else { return }
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "ui/initialize":
            respond(
                id,
                result: [
                    "protocolVersion": MCPApp.protocolVersion,
                    "hostInfo": ["name": "Herm", "version": Bundle.main.shortVersion],
                    "hostCapabilities": ["openLinks": [String: Any](), "logging": [String: Any]()],
                    "hostContext": hostContext(),
                ])
        case "ui/notifications/initialized":
            notify("ui/notifications/tool-input", params: ["arguments": object(call.arguments)])
            notify("ui/notifications/tool-result", params: object(call.result))
        case "ui/notifications/size-changed":
            if let height = (params["height"] as? NSNumber)?.doubleValue, height.isFinite {
                resize?(CGFloat(height))
            }
        case "ui/open-link":
            guard let id, id is String || (id is NSNumber && CFGetTypeID(id as CFTypeRef) != CFBooleanGetTypeID())
            else { return }
            guard let text = params["url"] as? String, let url = RichResourcePolicy.url(text) else {
                return fail(id, code: -32602, "Herm opens only public HTTPS links.")
            }
            guard !pending, openLink != nil else { return fail(id, code: -32000, "Action unavailable or busy.") }
            pending = true
            Task {
                defer { pending = false }
                let approved = await authorize?(.openLink(url: url, source: "\(call.server) · \(call.title)")) ?? false
                guard active, !Task.isCancelled else { return }
                guard approved, let openLink else { return fail(id, code: -32000, "Action cancelled.") }
                openLink(url)
                respond(id, result: [:])
            }
        case "ping":
            respond(id, result: [:])
        case "notifications/message":
            break
        case let method?:
            fail(id, code: -32601, "Herm does not support \(method) yet.")
        case nil:
            break
        }
    }

    func invalidate() { active = false }

    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    private func notify(_ method: String, params: [String: Any]) {
        send?(["jsonrpc": "2.0", "method": method, "params": params])
    }
    private func respond(_ id: Any?, result: [String: Any]) {
        guard let id else { return }
        send?(["jsonrpc": "2.0", "id": id, "result": result])
    }
    private func fail(_ id: Any?, code: Int, _ message: String) {
        guard let id else { return }
        send?(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }
}

extension Bundle {
    fileprivate var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// The app view for one completed MCP tool call. Like generated HTML, it runs only after an explicit Open.
struct MCPAppCard: View {
    let callID: String
    let appID: String
    @ObservedObject private var coordinator = GeneratedHTMLCoordinator.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var call: MCPApp.Call?
    @State private var loaded = false
    @State private var height: CGFloat = 320
    @StateObject private var state = GeneratedHTMLLoadState()

    private var key: String { "mcp-app:" + appID }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DockIcon(.appWindow, size: 13, color: Color.dockSecondaryText)
                Text(call?.title ?? "App view").dockFont(.body, weight: .medium).lineLimit(1)
                if let call { Text(call.server).dockFont(.metadata).foregroundStyle(Color.dockMetadataText) }
                Spacer(minLength: 8)
                if call != nil {
                    if coordinator.activeKey == key {
                        Button("Close") { coordinator.close() }.buttonStyle(.dockSecondary)
                    } else {
                        Button("Open") { coordinator.open(key) }.buttonStyle(.dockSecondary)
                    }
                }
            }
            .dockButtonSize(.compact)
            if let call {
                if !call.requestedDomains.isEmpty {
                    Text(
                        "Herm runs app views offline. Requested network access: "
                            + call.requestedDomains.joined(separator: ", ")
                    )
                    .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if coordinator.activeKey == key {
                    if let error = state.error {
                        Text(error).dockFont(.body).foregroundStyle(Color.dockWarning)
                    } else {
                        GeneratedHTMLWebView(html: call.html, state: state, bridge: bridge(call))
                            .id("\(appID):\(callID):\(DockThemeRuntime.revision)")
                            .frame(height: height)
                            .overlay {
                                if state.loading { ProgressView().controlSize(.small).allowsHitTesting(false) }
                            }
                    }
                }
            } else if loaded {
                Text("This app view is unavailable on this Mac.")
                    .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard()
        .task(id: appID) {
            let id = appID
            call = await Task.detached(priority: .utility) { MCPApp.Call.load(id: id) }.value
            loaded = true
        }
    }

    private func bridge(_ call: MCPApp.Call) -> MCPAppBridge {
        let dark = colorScheme == .dark
        let bridge = MCPAppBridge(call: call) {
            [
                "theme": dark ? "dark" : "light", "displayMode": "inline", "availableDisplayModes": ["inline"],
                "platform": "desktop", "locale": Locale.current.identifier,
                "timeZone": TimeZone.current.identifier,
                "toolInfo": ["id": callID, "tool": ["name": call.toolName, "title": call.title]],
            ]
        }
        bridge.resize = { height = min(max($0, 80), 720) }
        bridge.openLink = { openURL($0) }
        return bridge
    }
}
