import Foundation
import Testing

@testable import Herm

@MainActor
struct GroupChatCreationTests {
    @Test func secondRemoteRegistrationFailureReportsExistingRoom() async throws {
        let client = GroupCreationClient()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let store = GroupChatStore(defaults: defaults)
        store.bind(to: client)
        let invites = ["One", "Two", "Three"].map { name in
            RemoteMemberInvite(
                memberID: "peer-\(name.lowercased())", handle: name.lowercased(), targetProfile: name.lowercased(),
                displayName: name, grant: "fixture", endpointURL: "https://far.example/roomlink",
                catalogJSON: "{\"installation_id\":\"far\",\"catalog_digest\":\"abc\"}")
        }

        let outcome = await store.create(name: "Planning Room", bots: [], remote: invites, roomID: "existing-room")

        #expect(client.createCount == 1)
        #expect(store.rooms.contains { $0.id == "existing-room" && $0.name == "Planning Room" })
        #expect(client.attemptedMembers == ["peer-one", "peer-two"])
        #expect(client.registeredMembers == ["peer-one"])
        guard case .partial(let setup) = outcome else {
            Issue.record("Expected partial setup")
            return
        }
        #expect(setup.note.contains("Planning Room"))
        #expect(setup.note.contains("was created"))
        // A fresh sheet has no checkpoint and must not inherit the old warning.
        #expect(store.errorMessage == nil)
        #expect(setup.total == 3 && setup.remaining.count == 2)
        guard case .complete(let roomID) = await store.retryRoomSetup(setup) else {
            Issue.record("Expected completed setup")
            return
        }
        #expect(roomID == "existing-room")
        #expect(client.createCount == 1)
        #expect(store.rooms.filter { $0.id == roomID }.count == 1)
        #expect(client.attemptedMembers == ["peer-one", "peer-two", "peer-two", "peer-three"])
        #expect(client.registeredMembers == ["peer-one", "peer-two", "peer-three"])
        #expect(store.errorMessage == nil)
    }

    @Test func retryKeepsProgressAfterAnotherRegistrationFailure() async throws {
        let client = GroupCreationClient()
        client.failures = [2, 4]
        let store = GroupChatStore(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        store.bind(to: client)
        let invites = ["one", "two", "three"].map {
            RemoteMemberInvite(
                memberID: "peer-\($0)", handle: $0, targetProfile: $0, displayName: $0,
                grant: "fixture", endpointURL: "https://far.example/roomlink", catalogJSON: "{}")
        }
        guard case .partial(let first) = await store.create(name: "Room", bots: [], remote: invites, roomID: "r"),
            case .partial(let second) = await store.retryRoomSetup(first)
        else {
            Issue.record("Expected two partial results")
            return
        }
        #expect(second.remaining.map(\.memberID) == ["peer-three"])
        #expect(second.note.contains("2 of 3 registered"))
        guard case .complete(let roomID) = await store.retryRoomSetup(second) else {
            Issue.record("Expected completion")
            return
        }
        #expect(roomID == "r")
        #expect(client.attemptedMembers == ["peer-one", "peer-two", "peer-two", "peer-three", "peer-three"])
        #expect(client.createCount == 1)
    }

    @Test func createRefusalDoesNotRegisterPeers() async throws {
        let client = GroupCreationClient()
        client.refuseCreate = true
        let store = GroupChatStore(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        store.bind(to: client)
        let invites = ["one", "two"].map {
            RemoteMemberInvite(
                memberID: $0, handle: $0, targetProfile: $0, displayName: $0,
                grant: "fixture", endpointURL: "https://far.example/roomlink", catalogJSON: "{}")
        }
        guard case .notCreated = await store.create(name: "Room", bots: [], remote: invites) else {
            Issue.record("Expected create refusal")
            return
        }
        #expect(client.attemptedMembers.isEmpty)
        #expect(store.errorMessage?.contains("Couldn't create") == true)
    }

    @Test func staleSetupCannotRegisterOnNewBinding() async throws {
        let client = GroupCreationClient()
        let store = GroupChatStore(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        store.bind(to: client)
        let invites = ["one", "two"].map {
            RemoteMemberInvite(
                memberID: $0, handle: $0, targetProfile: $0, displayName: $0,
                grant: "fixture", endpointURL: "https://far.example/roomlink", catalogJSON: "{}")
        }
        guard case .partial(let setup) = await store.create(name: "Room", bots: [], remote: invites, roomID: "r") else {
            Issue.record("Expected partial setup")
            return
        }
        let newClient = GroupCreationClient()
        store.bind(to: newClient)
        guard case .partial = await store.retryRoomSetup(setup) else {
            Issue.record("Expected stale setup")
            return
        }
        #expect(newClient.createCount == 0 && newClient.attemptedMembers.isEmpty)
        #expect(store.errorMessage == nil)
    }

    @Test func inFlightRegistrationCannotPublishAfterRebinding() async throws {
        for refusesReply in [false, true] {
            let client = GroupCreationClient()
            client.holdAttempt = 2
            client.failures = []
            client.refuseHeldReply = refusesReply
            let store = GroupChatStore(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
            store.bind(to: client)
            let invites = ["one", "two", "three"].map {
                RemoteMemberInvite(
                    memberID: $0, handle: $0, targetProfile: $0, displayName: $0,
                    grant: "fixture", endpointURL: "https://far.example/roomlink", catalogJSON: "{}")
            }
            let operation = Task { await store.create(name: "Room", bots: [], remote: invites, roomID: "r") }
            await client.waitUntilHeld()
            let replacement = GroupCreationClient()
            store.bind(to: replacement)
            client.releaseHeld()
            let outcome = await operation.value
            guard case .partial = outcome else {
                Issue.record("Stale registration must not complete")
                continue
            }
            #expect(client.attemptedMembers == ["one", "two"])
            #expect(replacement.attemptedMembers.isEmpty && replacement.createCount == 0)
            #expect(store.rooms.isEmpty)
            #expect(store.errorMessage == nil)
        }
    }
}

@MainActor
private final class GroupCreationClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private var room: [String: Any]?
    private(set) var createCount = 0
    private(set) var attemptedMembers: [String] = []
    private(set) var registeredMembers: [String] = []
    var failures: Set<Int> = [2]
    var refuseCreate = false
    var holdAttempt: Int?
    var refuseHeldReply = false
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?

    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }

    func releaseHeld() {
        held?.resume()
        held = nil
    }

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "groups.capabilities": return ["driver": true]
        case "groups.list": return ["rooms": room.map { [$0] } ?? []]
        case "groups.create":
            createCount += 1
            if refuseCreate { throw HermesGateway.GatewayError.httpRefused(503, "refused") }
            room = params
            return ["room": params]
        case "groups.peer.register":
            guard let member = params["member_id"] as? String,
                params["room_id"] as? String == room?["room_id"] as? String
            else { throw HermesGateway.GatewayError.httpRefused(400, "wrong room or member") }
            attemptedMembers.append(member)
            if attemptedMembers.count == holdAttempt {
                await withCheckedContinuation { continuation in
                    held = continuation
                    heldWaiter?.resume()
                    heldWaiter = nil
                }
                if refuseHeldReply { throw HermesGateway.GatewayError.httpRefused(503, "refused") }
            }
            if failures.contains(attemptedMembers.count) {
                throw HermesGateway.GatewayError.httpRefused(503, "refused")
            }
            registeredMembers.append(member)
            return [:]
        default: return [:]
        }
    }
}
