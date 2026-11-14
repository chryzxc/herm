struct ProviderBackendAvailability {
    let isLocalBackend: Bool

    var allowsLocalAuth: Bool { isLocalBackend }

    func allowsLogin(for descriptor: QuotaProviderDescriptor) -> Bool {
        isLocalBackend || descriptor.id == "claude"
    }

    static let remoteQuotaMessage =
        "Remaining quota for Hermes-backed providers is unavailable with a remote backend. Claude Code and Antigravity show this Mac's local accounts. Activity → Spend shows recorded usage, not remaining quota."
    static let remoteAuthMessage =
        "Sign in on the Hermes backend host in the intended profile with hermes auth add <provider>. "
        + "Herm cannot run remote pool sign-in. For API keys, use Settings → Providers → Save Key. "
        + "Adding an account will not make remaining quota available here."
}
