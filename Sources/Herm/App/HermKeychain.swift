import Foundation
import Security

enum HermKeychain {
    private static let queue = DispatchQueue(label: "io.github.chryzxc.Herm.keychain", qos: .userInitiated)

    static func restrictAccess(service: String) async throws {
        try await perform {
            let status = SecItemUpdate(
                serviceItems(service) as CFDictionary,
                [kSecAttrAccess as String: try access(service)] as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
        }
    }

    static func read(service: String, account: String) async throws -> String? {
        try await perform {
            var query = item(service: service, account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            try check(status)
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            // Replace legacy helper trust without deleting or changing the credential.
            try check(
                SecItemUpdate(
                    item(service: service, account: account) as CFDictionary,
                    [kSecAttrAccess as String: try access(service)] as CFDictionary))
            return value
        }
    }

    static func write(service: String, account: String, value: String) async throws {
        try await perform {
            let query = item(service: service, account: account)
            let attributes: [String: Any] = [
                kSecValueData as String: Data(value.utf8), kSecAttrAccess as String: try access(service),
            ]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                try check(SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil))
            } else {
                try check(status)
            }
        }
    }

    static func remove(service: String, account: String) async throws {
        try await perform {
            let status = SecItemDelete(item(service: service, account: account) as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
        }
    }

    static func item(service: String, account: String) -> [String: Any] {
        serviceItems(service).merging([kSecAttrAccount as String: account]) { _, new in new }
    }

    static func serviceItems(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    static func access(_ label: String) throws -> SecAccess {
        var result: SecAccess?
        // A nil trusted list authorizes only this application, never a shared executable.
        try check(SecAccessCreate(label as CFString, nil, &result))
        guard let result else { throw CocoaError(.coderInvalidValue) }
        return result
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey: "Secure storage could not be accessed (\(status))."
                ])
        }
    }

    private static func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }
}
