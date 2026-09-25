import Foundation

/// Manages persistent, client-facing custom display names for quota providers.
/// Allows users to rename providers (e.g., "Codex (Account 2)" → "My Secondary Account")
/// without affecting backend provider IDs or data storage.
final class ProviderNicknameStore: @unchecked Sendable {
    private static let nicknameKey = "dock.provider.nicknames"
    private let defaults: UserDefaults
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    
    /// Returns the custom nickname for a provider, or nil if not set
    func nickname(for providerID: String) -> String? {
        let nicknames = defaults.dictionary(forKey: Self.nicknameKey) as? [String: String] ?? [:]
        return nicknames[providerID]
    }
    
    /// Sets a custom nickname for a provider
    func setNickname(_ nickname: String, for providerID: String) {
        var nicknames = defaults.dictionary(forKey: Self.nicknameKey) as? [String: String] ?? [:]
        let nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if nickname.isEmpty {
            nicknames.removeValue(forKey: providerID)
        } else {
            nicknames[providerID] = nickname
        }
        defaults.set(nicknames, forKey: Self.nicknameKey)
    }
    
    /// Removes the custom nickname for a provider (reverts to default)
    func removeNickname(for providerID: String) {
        setNickname("", for: providerID)
    }
    
    /// Returns the display name: custom nickname if set, otherwise the default name
    func displayName(for providerID: String, default defaultName: String) -> String {
        nickname(for: providerID) ?? defaultName
    }
    
    /// Returns all stored nicknames
    func allNicknames() -> [String: String] {
        defaults.dictionary(forKey: Self.nicknameKey) as? [String: String] ?? [:]
    }
}
