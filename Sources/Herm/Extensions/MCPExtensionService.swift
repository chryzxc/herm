import Foundation

public enum MCPExtensionParseError: Error, Equatable, Sendable {
    case unsupportedInput
    case malformedFixture
}

public enum MCPExtensionOperation: CaseIterable, Sendable {
    case addServer, editServer, removeServer, testConnection, reload
    case enablePlugin, disablePlugin, validatePlugin
    /// Deliberately represented so the UI can explain the upstream blocker;
    /// this is not an invocation implementation.
    case invokeThirdPartyTool
}

public enum MCPExtensionUnavailableReason: Equatable, Sendable {
    case unverifiedContract
    case unsupportedCommand
    case denied
    case confirmationRequired
    case upstreamBlocked
}

public enum MCPExtensionOperationResult: Equatable, Sendable {
    case unavailable(MCPExtensionUnavailableReason)
}

public struct MCPExtensionService: Sendable {
    private static let fixtureSchema = "hermes.extensions.inventory.fixture.v1"
    private static let maximumFixtureBytes = 64 * 1024
    private static let maximumIdentifierBytes = 128

    public init() {}

    // This parser accepts only a Dock-owned fixture envelope. It is not a
    // verified live Hermes contract; current live CLI output remains
    // unsupported until such a contract is established.
    public func parseFixture(_ input: String) throws -> MCPExtensionInventory {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{", trimmed.last == "}" else { throw MCPExtensionParseError.unsupportedInput }
        guard let data = trimmed.data(using: .utf8), data.count <= Self.maximumFixtureBytes else {
            throw MCPExtensionParseError.malformedFixture
        }
        guard DuplicateKeyScanner(data: data).isValidAndUnique else { throw MCPExtensionParseError.malformedFixture }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw MCPExtensionParseError.malformedFixture
        }
        guard let root = object as? [String: Any],
              let schema = root["schema"] as? String,
              schema == Self.fixtureSchema else { throw MCPExtensionParseError.unsupportedInput }
        if containsForbiddenInput(root) { throw MCPExtensionParseError.unsupportedInput }
        guard Set(root.keys) == Set(["schema", "state", "servers", "plugins"]),
              let stateValue = root["state"] as? String,
              let state = MCPExtensionInventoryState(rawValue: stateValue),
              let serverRows = root["servers"] as? [Any],
              let pluginRows = root["plugins"] as? [Any] else { throw MCPExtensionParseError.malformedFixture }
        return MCPExtensionInventory(
            state: state,
            servers: try serverRows.map { try parseServer($0) },
            plugins: try pluginRows.map { try parsePlugin($0) }
        )
    }

    private func parseServer(_ value: Any) throws -> MCPServerInventory {
        guard let row = value as? [String: Any], Set(row.keys) == Set(["id", "name", "status", "capabilities"]),
              let id = row["id"] as? String,
              let name = row["name"] as? String,
              let status = row["status"] as? String, let connection = MCPConnectionStatus(rawValue: status),
              let capabilities = parseCapabilities(row["capabilities"]) else { throw MCPExtensionParseError.malformedFixture }
        guard isSafeIdentifierOrLabel(id), isSafeIdentifierOrLabel(name) else { throw MCPExtensionParseError.unsupportedInput }
        return MCPServerInventory(id: id, name: name, connection: connection, capabilities: capabilities)
    }

    private func parsePlugin(_ value: Any) throws -> MCPPluginInventory {
        guard let row = value as? [String: Any], Set(row.keys) == Set(["id", "name", "status", "capabilities"]),
              let id = row["id"] as? String,
              let name = row["name"] as? String,
              let status = row["status"] as? String, let pluginStatus = MCPPluginStatus(rawValue: status),
              let capabilities = parseCapabilities(row["capabilities"]) else { throw MCPExtensionParseError.malformedFixture }
        guard isSafeIdentifierOrLabel(id), isSafeIdentifierOrLabel(name) else { throw MCPExtensionParseError.unsupportedInput }
        return MCPPluginInventory(id: id, name: name, status: pluginStatus, capabilities: capabilities)
    }

    private func parseCapabilities(_ value: Any?) -> [MCPExtensionCapability]? {
        guard let values = value as? [Any] else { return nil }
        let capabilities = values.compactMap { ($0 as? String).flatMap(MCPExtensionCapability.init(rawValue:)) }
        return capabilities.count == values.count ? capabilities : nil
    }

    private func isSafeIdentifierOrLabel(_ value: String) -> Bool {
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= Self.maximumIdentifierBytes,
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        let lowercased = value.lowercased()
        let credentialMarkers = ["api_key=", "api-key=", "api key=", "access_token=", "access-token=", "password=", "secret=", "token="]
        return !credentialMarkers.contains(where: lowercased.contains)
            && !lowercased.hasPrefix("sk-")
            && !lowercased.hasPrefix("ghp_")
            && !lowercased.hasPrefix("eyj")
    }

    public func operation(_ operation: MCPExtensionOperation, name: String) -> MCPExtensionOperationResult {
        self.operation(operation, name: name, confirmed: true)
    }

    /// Returns an honest availability result without attempting a CLI/RPC
    /// operation. Hermes v0.20.6 has no verified contract for these actions.
    public func operation(_ operation: MCPExtensionOperation, name: String, confirmed: Bool) -> MCPExtensionOperationResult {
        guard confirmed else { return .unavailable(.confirmationRequired) }
        switch operation {
        case .reload: return .unavailable(.unsupportedCommand)
        case .invokeThirdPartyTool: return .unavailable(.upstreamBlocked)
        case .addServer, .editServer, .removeServer, .testConnection, .enablePlugin, .disablePlugin, .validatePlugin:
            return .unavailable(.unverifiedContract)
        }
    }

    private func containsForbiddenInput(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            let forbidden = Set(["url", "command", "args", "headers", "env", "tool", "payload", "arguments", "secret", "token", "authorization"])
            if !forbidden.isDisjoint(with: dictionary.keys.map { $0.lowercased() }) { return true }
            return dictionary.values.contains { containsForbiddenInput($0) }
        }
        if let array = value as? [Any] { return array.contains { containsForbiddenInput($0) } }
        if let string = value as? String {
            let lower = string.lowercased()
            return lower.contains("http://") || lower.contains("https://") || lower.contains("bearer ") || lower.contains("api_key")
        }
        return false
    }
}

private struct DuplicateKeyScanner {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    private var duplicateFound = false

    init(data: Data) { bytes = Array(data) }

    var isValidAndUnique: Bool {
        var scanner = self
        _ = scanner.parseValue()
        return !scanner.duplicateFound
    }

    private mutating func skipWhitespace() -> Bool {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        return true
    }

    private mutating func parseValue() -> Bool {
        guard depth < 64 else { return false }
        _ = skipWhitespace()
        guard index < bytes.count else { return false }
        switch bytes[index] {
        case 123: return parseObject()
        case 91: return parseArray()
        case 34: return parseString() != nil
        case 116: return parseLiteral(Array("true".utf8))
        case 102: return parseLiteral(Array("false".utf8))
        case 110: return parseLiteral(Array("null".utf8))
        default: return parseNumber()
        }
    }

    private mutating func parseObject() -> Bool {
        index += 1; depth += 1; defer { depth -= 1 }
        _ = skipWhitespace()
        if consume(125) { return true }
        var keys = Set<String>()
        while index < bytes.count {
            guard let key = parseString() else { return false }
            guard keys.insert(key).inserted else { duplicateFound = true; return false }
            _ = skipWhitespace(); guard consume(58), parseValue() else { return false }
            _ = skipWhitespace()
            if consume(125) { return true }
            guard consume(44) else { return false }
            _ = skipWhitespace()
        }
        return false
    }

    private mutating func parseArray() -> Bool {
        index += 1; depth += 1; defer { depth -= 1 }
        _ = skipWhitespace()
        if consume(93) { return true }
        while index < bytes.count {
            guard parseValue() else { return false }
            _ = skipWhitespace()
            if consume(93) { return true }
            guard consume(44) else { return false }
            _ = skipWhitespace()
        }
        return false
    }

    private mutating func parseString() -> String? {
        guard consume(34) else { return nil }
        let start = index - 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if escaped { escaped = false; continue }
            if byte == 92 { escaped = true; continue }
            if byte == 34 {
                let encoded = Data(bytes[start..<index])
                return (try? JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])) as? String
            }
            if byte < 32 { return nil }
        }
        return nil
    }

    private mutating func parseLiteral(_ literal: [UInt8]) -> Bool {
        guard bytes[index..<min(index + literal.count, bytes.count)].elementsEqual(literal) else { return false }
        index += literal.count; return true
    }

    private mutating func parseNumber() -> Bool {
        let start = index
        if consume(45) {};
        guard consumeDigits() else { return false }
        if consume(46) && !consumeDigits() { return false }
        if index < bytes.count && (bytes[index] == 101 || bytes[index] == 69) {
            index += 1; if index < bytes.count && (bytes[index] == 43 || bytes[index] == 45) { index += 1 }
            if !consumeDigits() { return false }
        }
        return index > start
    }

    private mutating func consumeDigits() -> Bool {
        let start = index
        while index < bytes.count && bytes[index] >= 48 && bytes[index] <= 57 { index += 1 }
        return index > start
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1; return true
    }
}
