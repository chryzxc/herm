struct ProviderBackendAvailability {
    let isLocalBackend: Bool

    var allowsLocalAuth: Bool { isLocalBackend }

    func allowsLogin(for descriptor: QuotaProviderDescriptor) -> Bool {
        isLocalBackend || descriptor.id == "claude"
    }

    static let remoteQuotaMessage =
        "Hermes reports backend quota when available. Claude Code and Antigravity show this Mac's local accounts. Activity → Spend shows recorded usage, not remaining quota."
    static let remoteAuthMessage =
        "Use backend sign-in when supported, or sign in on the Hermes backend host in the intended profile "
        + "with hermes auth add <provider>. For API keys, use Settings → Providers → Save Key. "
        + "Backend quota is shown when Hermes reports it."
}
