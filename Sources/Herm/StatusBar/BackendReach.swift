import Foundation

/// The one place that decides where a feature's data can come from on the
/// active gateway. Features ask for a resource; they never check the gateway
/// mode themselves, and nothing reads this Mac's files while the agent runs elsewhere.
enum BackendReach {
    enum Resource: CaseIterable {
        /// Sessions, approvals, Kanban, routines, processes, verification: Hermes RPC and events.
        case hermes
        /// git status and history for a repository.
        case repositoryFiles
        /// GitHub pull requests through `gh` beside the repository.
        case pullRequests
        /// Opening a dev server's localhost link.
        case processLinks
        /// Discovery of listeners owned by Herm's local workspace terminals.
        case localPreviews
        /// macOS Calendar on this Mac.
        case macCalendar
        /// A booted simulator the agent can drive.
        case simulator
    }

    enum Access: Equatable {
        case direct
        case viaHermes
        /// Works on this Mac whatever the gateway, like Calendar.
        case thisMac
        /// Listed, but part of it (such as a link) cannot work here.
        case partial(String)
        case unavailable(String)

        var isAvailable: Bool {
            if case .unavailable = self { return false }
            return true
        }

        var reason: String? {
            switch self {
            case .partial(let reason), .unavailable(let reason): reason
            default: nil
            }
        }
    }

    static func access(_ resource: Resource, mode: GatewayConnectionSettings.Mode) -> Access {
        switch (resource, mode) {
        case (.hermes, _): .viaHermes
        case (.macCalendar, _): .thisMac
        case (_, .local): .direct
        case (.repositoryFiles, _), (.pullRequests, _):
            .unavailable("Unavailable on \(mode.label): Herm reads repositories on this Mac only")
        case (.processLinks, .ssh):
            .partial("Listed through Hermes. Open the port through an SSH forward to reach it")
        case (.processLinks, _):
            .partial("Listed through Hermes. The server's port is not reachable from this Mac")
        case (.localPreviews, _): .unavailable("Local previews are available with the Local gateway")
        case (.simulator, _): .unavailable("Unavailable on \(mode.label): the agent can't reach this Mac")
        }
    }

    @MainActor static func access(_ resource: Resource) -> Access {
        access(resource, mode: GatewayConnectionStore.shared.selected.mode)
    }
}

extension GatewayConnectionSettings.Mode {
    var label: String {
        switch self {
        case .local: "Local"
        case .remote: "Remote"
        case .ssh: "SSH"
        case .cloud: "Cloud"
        }
    }
}
