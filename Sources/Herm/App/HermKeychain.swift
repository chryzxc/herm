import Foundation
import Security

enum HermKeychain {
    private static let queue = DispatchQueue(label: "io.github.chryzxc.Herm.keychain", qos: .userInitiated)

    static func restrictAccess(service: String) async throws {
        try await perform { try replaceHelperTrust(serviceItems(service), label: service) }
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
            try replaceHelperTrust(item(service: service, account: account), label: service)
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

    /// Replaces legacy `/usr/bin/security` trust without deleting or changing the credential.
    /// Changing an item's access asks for the login password, so items already migrated are left alone.
    private static func replaceHelperTrust(_ query: [String: Any], label: String) throws {
        var refs = query
        refs[kSecReturnRef as String] = true
        refs[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(refs as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        try check(status)
        for item in result as? [SecKeychainItem] ?? [] where trustsSharedHelper(item) {
            try check(SecKeychainItemSetAccess(item, try access(label)))
        }
    }

    static func trustsSharedHelper(_ item: SecKeychainItem) -> Bool {
        var itemAccess: SecAccess?
        guard SecKeychainItemCopyAccess(item, &itemAccess) == errSecSuccess, let itemAccess else { return false }
        return trustedPaths(itemAccess).contains { $0.contains("/usr/bin/security") }
    }

    static func trustedPaths(_ access: SecAccess) -> [String] {
        let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL] ?? []
        return acls.flatMap { acl -> [String] in
            var applications: CFArray?
            var label: CFString?
            var prompt = SecKeychainPromptSelector(rawValue: 0)
            guard SecACLCopyContents(acl, &applications, &label, &prompt) == errSecSuccess else { return [] }
            return (applications as? [SecTrustedApplication] ?? []).compactMap { application in
                var data: CFData?
                guard SecTrustedApplicationCopyData(application, &data) == errSecSuccess, let data else { return nil }
                return String(decoding: data as Data, as: UTF8.self)
            }
        }
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
