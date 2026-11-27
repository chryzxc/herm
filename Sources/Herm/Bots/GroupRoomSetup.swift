import Foundation

enum GroupRoomCreationOutcome {
    case notCreated
    case complete(String)
    case partial(GroupRoomSetup)
}

struct GroupRoomSetup {
    let roomID: String
    let name: String
    let generation: Int
    let total: Int
    var remaining: [RemoteMemberInvite]
    var failureSummary: String?

    var note: String {
        let count = "\(total - remaining.count) of \(total) registered"
        let progress = "\(name) was created, but remote-bot setup is incomplete (\(count))."
        return failureSummary.map { "\(progress) \($0)" } ?? progress
    }

    @MainActor
    func register(using client: HermesRPCClientProtocol, isCurrent: () -> Bool) async -> GroupRoomSetup {
        var setup = self
        while let invite = setup.remaining.first, isCurrent() {
            do {
                _ = try await client.request(
                    HermesFeatureIDs.ID.groupsPeerRegister.rawValue,
                    params: [
                        "room_id": roomID, "member_id": invite.memberID, "target_url": invite.endpointURL,
                        "target_profile": invite.targetProfile, "grant": invite.grant, "catalog": invite.catalog,
                    ])
                guard isCurrent() else { return setup }
                setup.remaining.removeFirst()
            } catch {
                guard isCurrent() else { return setup }
                setup.failureSummary = HermesDiagnosticsService.safeSummary(error.localizedDescription)
                return setup
            }
        }
        return setup
    }
}
