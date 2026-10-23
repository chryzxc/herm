import Foundation

/// The subscription providers the Quota surface knows about. Every provider in
/// the catalog is always listed; providers without a working login render in a
/// disabled state with an explicit connect action instead of disappearing.
struct QuotaProviderDescriptor: Identifiable, Equatable, Hashable {
    enum ConnectKind: Equatable, Hashable {
        /// The user pastes an API key; `storageKey` is the catalog entry the
        /// dock-owned key store (and the quota services' own parsers) read.
        case apiKey(instruction: String, storageKey: String)
        /// The provider authenticates through its CLI's login command, which
        /// opens a browser and stores credentials in the CLI's own files.
        case login(command: String, instruction: String)
        /// The provider authenticates inside its desktop app; quota is read
        /// from the app's local service while it runs.
        case openApp(applicationName: String, instruction: String)
    }

    let id: String
    let displayName: String
    let summary: String
    let website: URL?
    let connect: ConnectKind

    var storageKey: String? {
        if case .apiKey(_, let storageKey) = connect { return storageKey }
        return nil
    }
}

enum QuotaProviderCatalog {
    static let all: [QuotaProviderDescriptor] = [
        codexHermes, opencode, glm, deepseek, kimi, openrouter, claude, antigravity,
    ]
    private static let orderDefaultsKey = "quota.providerOrder"

    static let codexHermes = QuotaProviderDescriptor(
        id: "codex-hermes",
        displayName: "Codex via Hermes",
        summary: "Quota for the Codex account authenticated inside Hermes.",
        website: URL(string: "https://chatgpt.com/codex"),
        connect: .login(
            command: "hermes auth add openai-codex",
            instruction: "Starts Hermes-managed Codex sign-in."
        )
    )

    static let opencode = QuotaProviderDescriptor(
        id: "opencode",
        displayName: "OpenCode Go",
        summary: "OpenCode Go session, weekly, and monthly allowance windows.",
        website: URL(string: "https://opencode.ai"),
        connect: .apiKey(
            instruction:
                "Paste your OpenCode Go API key. It is stored in Herm's own provider config and used only to read quota.",
            storageKey: "opencode-go"
        )
    )

    static let glm = QuotaProviderDescriptor(
        id: "glm",
        displayName: "GLM Coding Plan",
        summary: "Z.ai GLM Coding Plan session, weekly, and web-search windows.",
        website: URL(string: "https://z.ai"),
        connect: .apiKey(
            instruction:
                "Paste your Z.ai API key. It is stored in Herm's own provider config and used only to read quota.",
            storageKey: "glm"
        )
    )

    static let deepseek = QuotaProviderDescriptor(
        id: "deepseek",
        displayName: "DeepSeek",
        summary: "DeepSeek API pay-as-you-go balance.",
        website: URL(string: "https://platform.deepseek.com"),
        connect: .apiKey(
            instruction:
                "Paste your DeepSeek API key, or leave it to Hermes' DEEPSEEK_API_KEY. It is stored in Herm's own provider config and used only to read the balance.",
            storageKey: "deepseek"
        )
    )

    static let kimi = QuotaProviderDescriptor(
        id: "kimi",
        displayName: "Kimi",
        summary: "Moonshot (Kimi) open platform pay-as-you-go balance.",
        website: URL(string: "https://platform.moonshot.ai"),
        connect: .apiKey(
            instruction:
                "Paste your Moonshot platform API key, or leave it to Hermes' MOONSHOT_API_KEY / KIMI_API_KEY. It is stored in Herm's own provider config and used only to read the balance.",
            storageKey: "kimi"
        )
    )

    static let openrouter = QuotaProviderDescriptor(
        id: "openrouter",
        displayName: "OpenRouter",
        summary: "OpenRouter credits and the key's spend limit.",
        website: URL(string: "https://openrouter.ai"),
        connect: .apiKey(
            instruction:
                "Paste your OpenRouter API key, or leave it to Hermes' OPENROUTER_API_KEY. It is stored in Herm's own provider config and used only to read credits.",
            storageKey: "openrouter"
        )
    )

    static let claude = QuotaProviderDescriptor(
        id: "claude",
        displayName: "Claude",
        summary: "Claude Code session and weekly allowance windows.",
        website: URL(string: "https://claude.ai/code"),
        connect: .login(
            command: "claude auth login",
            instruction:
                "Starts the Claude Code CLI sign-in, which opens your browser to authenticate with your Anthropic account. Herm then reads the credential the CLI stores on this Mac."
        )
    )

    static let antigravity = QuotaProviderDescriptor(
        id: "antigravity",
        displayName: "Antigravity",
        summary: "Antigravity shared Gemini and Claude pool windows while it runs.",
        website: URL(string: "https://antigravity.google"),
        connect: .openApp(
            applicationName: "Antigravity",
            instruction:
                "Opens the Antigravity app. Sign in inside Antigravity; quota is read from its local service whenever the app is running."
        )
    )

    static func descriptor(for id: String) -> QuotaProviderDescriptor? {
        all.first { $0.id == id }
    }

    /// Returns the user's order while retaining catalog entries added by a
    /// newer Dock version.
    static func orderedProviderIDs(defaults: UserDefaults = .standard) -> [String] {
        let catalogIDs = all.map(\.id)
        let storedIDs = defaults.stringArray(forKey: orderDefaultsKey) ?? []
        var seenIDs = Set<String>()
        let validStoredIDs = storedIDs.filter {
            catalogIDs.contains($0) && seenIDs.insert($0).inserted
        }
        return validStoredIDs + catalogIDs.filter { !validStoredIDs.contains($0) }
    }

    static func saveProviderOrder(_ ids: [String], defaults: UserDefaults = .standard) {
        let catalogIDs = Set(all.map(\.id))
        var seenIDs = Set<String>()
        let validIDs = ids.filter {
            catalogIDs.contains($0) && seenIDs.insert($0).inserted
        }
        defaults.set(validIDs, forKey: orderDefaultsKey)
    }
}
