import SwiftUI

enum GitHubAccessRequirement: Equatable, Sendable {
    case signIn, permission

    init?(error: Error) {
        switch error as? GitHubRequestError {
        case .unauthorized: self = .signIn
        case .forbidden, .insufficientScopes: self = .permission
        default: return nil
        }
    }

    func command() -> String {
        self == .signIn
            ? "gh auth login --hostname github.com --web"
            : "gh auth refresh -h github.com -s repo"
    }
}

/// Shared recovery for the existing GitHub CLI credential. Never runs authorization automatically.
struct GitHubAccessRecoveryView: View {
    let feature: String
    let requirement: GitHubAccessRequirement
    let isRetrying: Bool
    let retry: () -> Void
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "lock.rectangle")
                    .font(.system(size: 24)).foregroundStyle(Color.dockSecondaryText)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Allow access to GitHub \(feature)").dockFont(.body, weight: .semibold)
                    Text(
                        requirement == .signIn
                            ? "Sign in with GitHub CLI to continue."
                            : "Authorize access with your existing GitHub sign-in."
                    )
                    .foregroundStyle(Color.dockSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(requirement.command())
                        .dockFont(.metadata, design: .monospaced).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .dockPadding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.dockSurface, in: RoundedRectangle(cornerRadius: 8))
                    Text(
                        "Run this in Terminal, complete GitHub authorization, then retry. Updated credentials may take a minute to appear."
                    )
                    .foregroundStyle(Color.dockSecondaryText).fixedSize(horizontal: false, vertical: true)
                    if requirement == .permission {
                        Text(
                            "For a token, update its permissions. Organization repositories may also require SSO authorization or access from an administrator."
                        )
                        .foregroundStyle(Color.dockSecondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 10) {
                    Button(copied ? "Copied" : "Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(requirement.command(), forType: .string)
                        copied = true
                    }.buttonStyle(.dockSecondary)
                    Button(action: retry) {
                        HStack(spacing: 6) {
                            if isRetrying { ProgressView().controlSize(.mini) }
                            Text("Retry")
                        }
                    }.buttonStyle(.dockPrimary).disabled(isRetrying)
                }
            }
            .dockFont(.body).foregroundStyle(Color.dockPrimaryText)
            .frame(maxWidth: 440, alignment: .leading).dockPadding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dockCanvas)
        .onChange(of: requirement) { _, _ in copied = false }
    }
}
