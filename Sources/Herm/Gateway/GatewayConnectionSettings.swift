import Combine
import Foundation
import Security

struct GatewayConnectionSettings: Codable, Equatable, Identifiable {
    enum Mode: String, Codable, CaseIterable { case local, remote, ssh, cloud }
    enum Authentication: String, Codable, CaseIterable { case token, signIn }
    var id = UUID().uuidString
    var name = "Local"
    var mode: Mode = .local
    var remoteURL = ""
    var authentication: Authentication = .token
    var sshHost = ""
    var sshUser = ""
    var sshPort = 22
    var sshKeyPath = ""
    var remoteHermesPath = ""
    var remoteProfile = ""
    var cloudOrganization = ""

    static func normalizedURL(_ text: String) throws -> URL {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = text.contains("://")
        if !hasScheme { text = "https://" + text }
        guard var parts = URLComponents(string: text),
            ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
            let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            parts.port.map({ (1...65535).contains($0) }) ?? true
        else {
            throw GatewayConnectionError.invalidURL
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.lowercased()
        let isLoopback = ["localhost", "127.0.0.1", "[::1]"].contains(host.lowercased())
        if !hasScheme && isLoopback { parts.scheme = "http" }
        guard parts.scheme == "https" || isLoopback else { throw GatewayConnectionError.insecureURL }
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        guard let url = parts.url else { throw GatewayConnectionError.invalidURL }
        return url
    }

    static func endpoint(_ base: URL, _ path: String) throws -> URL {
        let base = try normalizedURL(base.absoluteString)
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
            let url = URL(string: base.absoluteString + path), url.host == base.host
        else {
            throw GatewayConnectionError.invalidURL
        }
        return url
    }

    func validated() throws -> Self {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.name.isEmpty { copy.name = mode == .local ? "Local" : mode.rawValue.capitalized }
        switch mode {
        case .local: break
        case .remote, .cloud:
            copy.remoteURL = try Self.normalizedURL(remoteURL).absoluteString
            if mode == .cloud { copy.authentication = .signIn }
        case .ssh:
            copy.sshHost = sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let allowed = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:@[]")
            guard !copy.sshHost.isEmpty, !copy.sshHost.hasPrefix("-"),
                copy.sshHost.unicodeScalars.allSatisfy(allowed.contains),
                !sshUser.hasPrefix("-"), sshUser.unicodeScalars.allSatisfy(allowed.contains),
                (1...65535).contains(sshPort),
                remoteProfile.isEmpty
                    || remoteProfile.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_-]*$"#, options: .regularExpression) != nil,
                !sshKeyPath.contains("\n"), !remoteHermesPath.contains("\n")
            else {
                throw GatewayConnectionError.invalidSSH
            }
        }
        return copy
    }
}

enum GatewayConnectionError: LocalizedError {
    case invalidURL, insecureURL, invalidSSH, missingToken
    case storage(Int32)
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter an HTTP or HTTPS gateway URL without credentials, query parameters, or a fragment."
        case .insecureURL:
            "Remote gateways require HTTPS to protect credentials. Use HTTPS or an SSH connection; HTTP is allowed only on localhost, 127.0.0.1, or [::1]."
        case .invalidSSH: "Enter a valid SSH host, user, port, and profile. Use key-based SSH authentication."
        case .missingToken: "Enter a session token, or choose Sign in for a hosted gateway."
        case .storage(let status): "Could not access the gateway token in Keychain (\(status))."
        case .unavailable(let message): message
        }
    }
}

enum GatewayTokenStore {
    static func read(_ account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw GatewayConnectionError.storage(status)
        }
        return token
    }

    static func write(_ account: String, _ token: String) throws {
        let query = query(account)
        let attributes: [CFString: Any] = [kSecValueData: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query.merging(attributes) { _, new in new }
            addition[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GatewayConnectionError.storage(status) }
    }

    static func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GatewayConnectionError.storage(status)
        }
    }

    private static func query(_ account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword, kSecAttrService: "io.github.chryzxc.Herm.gateway",
            kSecAttrAccount: account,
        ]
    }
}

@MainActor
final class GatewayConnectionStore: ObservableObject {
    static let shared = GatewayConnectionStore()
    @Published private(set) var selected = GatewayConnectionSettings()
    @Published private(set) var connections: [GatewayConnectionSettings] = []
    @Published private(set) var error: String?
    let launchSettings: GatewayConnectionSettings
    let environmentOverride: Bool
    let launchToken: String?
    private let defaults: UserDefaults
    private let readToken: (String) throws -> String?
    private let writeToken: (String, String) throws -> Void
    private static let settingsKey = "gateway.connection"
    private static let connectionsKey = "gateway.savedConnections"

    init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readToken: @escaping (String) throws -> String? = GatewayTokenStore.read,
        writeToken: @escaping (String, String) throws -> Void = GatewayTokenStore.write
    ) {
        self.defaults = defaults
        self.readToken = readToken
        self.writeToken = writeToken
        environmentOverride = !(environment["HERMES_DESKTOP_REMOTE_URL"] ?? "").isEmpty
        launchToken = environmentOverride ? environment["HERMES_DESKTOP_REMOTE_TOKEN"] : nil
        var settings = GatewayConnectionSettings()
        var loadError: String?
        if let data = defaults.data(forKey: Self.settingsKey) {
            do { settings = try JSONDecoder().decode(GatewayConnectionSettings.self, from: data).validated() } catch {
                loadError = "Saved gateway settings could not be read. Save a valid connection to recover."
            }
        }
        if environmentOverride {
            settings.mode = .remote
            settings.name = "Startup override"
            settings.remoteURL = environment["HERMES_DESKTOP_REMOTE_URL"] ?? ""
            settings.authentication = .token
            do {
                settings = try settings.validated()
                loadError = nil
            } catch { loadError = error.localizedDescription }
        }
        launchSettings = settings
        selected = settings
        error = loadError
        if let data = defaults.data(forKey: Self.connectionsKey) {
            connections = (try? JSONDecoder().decode([GatewayConnectionSettings].self, from: data)) ?? []
        }
    }

    func token(for settings: GatewayConnectionSettings, draft: String = "") throws -> String {
        let token = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let value =
            try token.isEmpty
            ? readToken(GatewayConnectionSettings.normalizedURL(settings.remoteURL).absoluteString) ?? "" : token
        guard !value.isEmpty, !value.contains("\r"), !value.contains("\n") else {
            throw GatewayConnectionError.missingToken
        }
        return value
    }

    func save(_ settings: GatewayConnectionSettings, token: String) throws {
        guard !environmentOverride else {
            throw GatewayConnectionError.unavailable(
                "The gateway connection is controlled by startup environment settings.")
        }
        let settings = try settings.validated()
        if settings.mode == .remote && settings.authentication == .token {
            let resolved = try self.token(for: settings, draft: token)
            try writeToken(settings.remoteURL, resolved)
        }
        let data = try JSONEncoder().encode(settings)
        var saved = connections.filter { $0.id != settings.id }
        saved.append(settings)
        let savedData = try JSONEncoder().encode(saved)
        defaults.set(data, forKey: Self.settingsKey)
        defaults.set(savedData, forKey: Self.connectionsKey)
        selected = settings
        connections = saved
        error = nil
    }

    func remove(_ settings: GatewayConnectionSettings) throws {
        let saved = connections.filter { $0.id != settings.id }
        defaults.set(try JSONEncoder().encode(saved), forKey: Self.connectionsKey)
        connections = saved
    }
}
