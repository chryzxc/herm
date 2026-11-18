import AppKit
import Foundation
import UniformTypeIdentifiers

/// The closed set of things a plugin page may ask Herm for (`bridge.js` is the other end); any
/// other op is rejected. `request` forwards any Hermes RPC method, as Desktop's `host.request` does:
/// plugins are trusted code (see docs/adr/0001-desktop-plugin-pages.md).
enum DesktopPluginOp {
    case request(method: String, params: [String: Any], profile: String?)
    case rest(path: String, method: String, body: [String: Any]?)
    case openSession(String)
    case pickSavePath(defaultPath: String?, title: String?, extensions: [String])
    case notify(String, isError: Bool)
    case ready
    case failed(String)
}

enum DesktopPluginBridgeError: LocalizedError, Equatable {
    case malformed
    case unsupported(String)
    case illegalPath(String)
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .malformed: "Herm could not read this plugin request."
        case .unsupported(let op): "\(op) is not available in Herm yet."
        case .illegalPath(let path): "The plugin path \"\(path)\" is not allowed."
        case .sessionNotFound: "That chat is not in Herm's session list."
        }
    }
}

struct DesktopPluginMessage {
    /// `0` for fire-and-forget posts that expect no reply.
    let id: Int
    let op: DesktopPluginOp

    static let restMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    static func parse(_ text: String) throws -> DesktopPluginMessage {
        guard text.utf8.count <= 4_194_304,
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let id = object["id"] as? Int, let name = object["op"] as? String
        else { throw DesktopPluginBridgeError.malformed }
        let args = object["args"] as? [String: Any] ?? [:]
        func string(_ key: String) -> String? { (args[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let op: DesktopPluginOp
        switch name {
        case "request":
            guard let method = string("method") else { throw DesktopPluginBridgeError.malformed }
            op = .request(method: method, params: args["params"] as? [String: Any] ?? [:], profile: string("profile"))
        case "rest":
            let method = (string("method") ?? "GET").uppercased()
            guard let path = string("path"), restMethods.contains(method) else {
                throw DesktopPluginBridgeError.malformed
            }
            if args["body"] != nil, !(args["body"] is NSNull), !(args["body"] is [String: Any]) {
                throw DesktopPluginBridgeError.unsupported("A non-object request body")
            }
            op = .rest(path: try restSuffix(path), method: method, body: args["body"] as? [String: Any])
        case "openSession":
            guard let id = string("id") else { throw DesktopPluginBridgeError.malformed }
            op = .openSession(id)
        case "pickSavePath":
            let filters = args["filters"] as? [[String: Any]] ?? []
            op = .pickSavePath(
                defaultPath: string("defaultPath"), title: string("title"),
                extensions: filters.flatMap { $0["extensions"] as? [String] ?? [] })
        case "notify":
            op = .notify(string("message") ?? "", isError: args["error"] as? Bool ?? false)
        case "status":
            op = string("state") == "ready" ? .ready : .failed(string("message") ?? "The plugin stopped.")
        default:
            throw DesktopPluginBridgeError.unsupported(name)
        }
        return DesktopPluginMessage(id: id, op: op)
    }

    /// The path inside the plugin's own `/api/plugins/<id>` namespace; `..` cannot climb out of it.
    static func restSuffix(_ path: String) throws -> String {
        let suffix = path.hasPrefix("/") ? path : "/" + path
        let bare = suffix.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? suffix
        guard !bare.split(separator: "/").contains(".."), !bare.lowercased().contains("%2e") else {
            throw DesktopPluginBridgeError.illegalPath(path)
        }
        return suffix
    }

    static func restPath(pluginID: String, suffix: String) -> String {
        let id = pluginID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? pluginID
        return "/api/plugins/\(id)\(suffix)"
    }
}

/// Runs a plugin page's requests against Herm's own Hermes connection. It never touches views:
/// navigation and notices go out through the closures the page supplies.
@MainActor
final class DesktopPluginBridge {
    struct Host {
        let client: HermesRPCClientProtocol
        let events: HermesEventRouter
        /// Opens a stored session in Herm; false when Herm does not list it.
        let openSession: (String) -> Bool
    }

    let pluginID: String
    private let host: Host
    var reply: (_ id: Int, _ ok: Bool, _ value: Any) -> Void = { _, _, _ in }
    var push: (_ event: [String: Any]) -> Void = { _ in }
    var onReady: () -> Void = {}
    var onFailed: (String) -> Void = { _ in }
    var onNotice: (String, Bool) -> Void = { _, _ in }
    private var subscription: UUID?

    init(pluginID: String, host: Host) {
        self.pluginID = pluginID
        self.host = host
    }

    // ponytail: forwards every gateway event while the page is open; filter by the types the
    // page listens to if streaming chats make that measurable.
    func start() {
        guard subscription == nil else { return }
        subscription = host.events.subscribe { [weak self] type, params in
            var event: [String: Any] = ["type": type, "payload": params["payload"] ?? [:]]
            if let session = params["session_id"] { event["session_id"] = session }
            self?.push(event)
        }
    }

    func stop() {
        if let subscription { host.events.unsubscribe(subscription) }
        subscription = nil
    }

    func receive(_ text: String) async {
        let message: DesktopPluginMessage
        do {
            message = try DesktopPluginMessage.parse(text)
        } catch {
            // Without a readable id there is no one to answer.
            if let id = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["id"] as? Int,
                id > 0
            {
                reply(id, false, error.localizedDescription)
            }
            return
        }
        do {
            let value = try await perform(message.op)
            if message.id > 0 { reply(message.id, true, value) }
        } catch {
            if message.id > 0 {
                reply(message.id, false, HermesDiagnosticsService.safeSummary(error.localizedDescription))
            }
        }
    }

    private func perform(_ op: DesktopPluginOp) async throws -> Any {
        switch op {
        case .request(let method, var params, let profile):
            if let profile { params["profile"] = profile }
            return try await host.client.request(method, params: params)
        case .rest(let suffix, let method, let body):
            let path = DesktopPluginMessage.restPath(pluginID: pluginID, suffix: suffix)
            return method == "GET"
                ? try await host.client.fetchHTTP(path)
                : try await host.client.sendHTTP(method, path: path, body: body ?? [:])
        case .openSession(let id):
            guard host.openSession(id) else { throw DesktopPluginBridgeError.sessionNotFound }
            return NSNull()
        case .pickSavePath(let defaultPath, let title, let extensions):
            let panel = NSSavePanel()
            panel.title = title ?? ""
            panel.nameFieldStringValue = defaultPath.map { ($0 as NSString).lastPathComponent } ?? ""
            panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
            guard await panel.begin() == .OK, let url = panel.url else { return NSNull() }
            return url.path
        case .notify(let message, let isError):
            if !message.isEmpty { onNotice(message, isError) }
            return NSNull()
        case .ready:
            onReady()
            return NSNull()
        case .failed(let message):
            onFailed(HermesDiagnosticsService.safeSummary(message))
            return NSNull()
        }
    }
}
