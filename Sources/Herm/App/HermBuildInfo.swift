import Foundation

/// One build identity for app chrome and update presentation.
struct HermBuildInfo: Sendable {
    enum Channel: String, Sendable {
        case stable, nightly, dev
    }

    static let current = HermBuildInfo(
        channel: Bundle.main.infoDictionary?["HermBuildChannel"] as? String,
        commit: Bundle.main.infoDictionary?["HermBuildCommit"] as? String,
        isDebug: isDebugBuild)

    private static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    let channel: Channel
    let commit: String?

    init(channel: String?, commit: String?, isDebug: Bool) {
        self.channel = channel.flatMap(Channel.init(rawValue:)) ?? (isDebug ? .dev : .stable)
        self.commit = commit
    }

    func badge(includesCommit: Bool = false) -> String? {
        let label: String
        switch channel {
        case .stable: return nil
        case .nightly: label = "Nightly"
        case .dev: label = "Dev"
        }
        guard includesCommit, let commit, !commit.isEmpty else { return label }
        return "\(label) \(commit.prefix(8))"
    }
}
