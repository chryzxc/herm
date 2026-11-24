import Foundation
import Testing

@testable import Herm

/// Serves each profile its own rows, plus the all-profile sidebar scan.
@MainActor
private final class ProfileSessionsRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var rowsByProfile: [String: [[String: Any]]] = [
        "bot-a": [["id": "a-1", "title": "A one", "last_activity_at": 200]],
        "bot-b": [["id": "b-1", "title": "B one", "last_activity_at": 300]],
    ]
    var scanRows: [[String: Any]]?
    var olderPageGate: (started: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)?
    var scanGate: (started: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)?
    var scopedReadGate: (started: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)?
    var pinACKGate: (started: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)?
    private(set) var renameCommand: String?
    private(set) var listedProfiles: [String] = []

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "session.list":
            let profile = params["profile"] as? String ?? ""
            listedProfiles.append(profile)
            return ["sessions": rowsByProfile[profile] ?? []]
        case "session.resume":
            return ["session_id": params["session_id"] as? String ?? "", "messages": []]
        case "session.active_list":
            return ["sessions": []]
        case "shell.exec":
            let command = params["command"] as? String ?? ""
            if command.contains("--help") {
                return ["code": 0, "stdout": "sessions rename session_id title"]
            }
            renameCommand = command
            return ["code": 0]
        default:
            throw HermesGateway.GatewayError.malformedResponse
        }
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if path.hasPrefix("/api/profiles/sessions/sidebar") {
            guard let scanRows else { throw HermesGateway.GatewayError.malformedResponse }
            if let gate = scanGate {
                scanGate = nil
                gate.started.finish()
                for await _ in gate.release {}
            }
            return ["recents": ["sessions": scanRows]]
        }
        if path.hasPrefix("/api/sessions/shared/mutation-snapshot") {
            return ["session_id": "shared", "exists": true, "runtime_revision": 1, "runtime_generation": 1]
        }
        guard path.hasPrefix("/api/sessions?") else { throw HermesGateway.GatewayError.malformedResponse }
        let query = URLComponents(string: path)?.queryItems
        let profile = query?.first { $0.name == "profile" }?.value ?? ""
        let rows = rowsByProfile[profile] ?? []
        if profile == "bot-a", let gate = scopedReadGate {
            scopedReadGate = nil
            gate.started.finish()
            for await _ in gate.release {}
        }
        if profile == "bot-a", let gate = olderPageGate {
            if query?.contains(where: { $0.name == "offset" }) == true {
                olderPageGate = nil
                gate.started.finish()
                for await _ in gate.release {}
                return ["sessions": [["id": "older-a", "title": "Older A"]], "total": rows.count + 1]
            }
            return ["sessions": rows, "total": rows.count + 1]
        }
        return ["sessions": rows]
    }

    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        guard method == "PATCH", path == "/api/sessions/shared", body["pinned"] as? Bool == false,
            let profile = body["profile"] as? String, profile == "bot-a"
        else { throw HermesGateway.GatewayError.malformedResponse }
        if let gate = pinACKGate {
            pinACKGate = nil
            gate.started.finish()
            for await _ in gate.release {}
        }
        rowsByProfile[profile] = rowsByProfile[profile]?.map { row in
            row["id"] as? String == "shared" ? row.merging(["pinned": false]) { _, new in new } : row
        }
        return ["ok": true]
    }
}

@MainActor
struct ProfileSessionRetentionTests {
    private func withModel(
        _ body: (DockModel, ProfileSessionsRPCClient) async throws -> Void
    ) async throws {
        let suite = "ProfileSessionRetentionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ProfileSessionsRPCClient()
        let model = DockModel(defaults: defaults, rpcClient: client)
        defer { model.shutdown() }
        try await body(model, client)
    }

    private func settle(_ model: DockModel) async {
        await model.sessionLoadTask?.value
        await model.allBotSessionsTask?.value
    }

    private func snapshot(_ model: DockModel) -> SessionNavSidebarSnapshot {
        SessionNavSidebarSnapshot(inputs: SessionNavSidebarSnapshot.inputs(model: model, control: ControlCenterModel()))
    }

    @Test func switchingWhileOlderHistoryLoadsKeepsTheFirstPagesPins() async throws {
        try await withModel { model, client in
            let (started, didStart) = AsyncStream<Void>.makeStream()
            let (hold, release) = AsyncStream<Void>.makeStream()
            defer { release.finish() }
            client.olderPageGate = (didStart, hold)
            client.rowsByProfile["bot-a"] = [["id": "a-pin", "title": "A pin", "pinned": true]]
            model.setProfileScope("bot-a")
            let oldLoad = model.sessionLoadTask
            for await _ in started {}
            #expect(model.sessionProjectionState == .loading)
            #expect(snapshot(model).allProfilePinPresentation.sessions.map(\.id) == ["a-pin"])
            model.setProfileScope("bot-b")
            #expect(snapshot(model).allProfilePinPresentation.sessions.map(\.id) == ["a-pin"])
            #expect(model.retainedProfileSessions["bot-a"] == nil)
            release.finish()
            await oldLoad?.value
            await settle(model)
            #expect(snapshot(model).allProfilePinPresentation.sessions.map(\.id) == ["a-pin"])
            #expect(model.sessions.map(\.id) == ["b-1"])
        }
    }

    @Test func authoritativeEmptyPinsWinOverAHeldScanAfterSwitching() async throws {
        try await withModel { model, client in
            let pinned: [String: Any] = ["id": "shared", "title": "A pin", "pinned": true]
            client.rowsByProfile["bot-a"] = [pinned]
            model.setProfileScope("bot-a")
            await settle(model)
            model.setProfileScope("bot-b")
            await settle(model)
            let (started, didStart) = AsyncStream<Void>.makeStream()
            let (hold, release) = AsyncStream<Void>.makeStream()
            defer { release.finish() }
            client.scanRows = [pinned.merging(["profile": "bot-a"]) { _, new in new }]
            client.scanGate = (didStart, hold)
            model.loadAllBotSessions(force: true)
            let oldScan = model.allBotSessionsTask
            for await _ in started {}
            client.rowsByProfile["bot-a"] = []
            model.setProfileScope("bot-a")
            await model.sessionLoadTask?.value
            #expect(model.pinnedSessions.isEmpty)
            model.setProfileScope("bot-b")
            release.finish()
            await oldScan?.value
            await settle(model)
            #expect(snapshot(model).allProfilePinPresentation.sessions.isEmpty)
            model.loadAllBotSessions(force: true)
            await model.allBotSessionsTask?.value
            #expect(snapshot(model).allProfilePinPresentation.sessions.map(\.id) == ["shared"])
            model.setProfileScope("bot-a")
            await settle(model)
            model.setProfileScope("bot-b")
            await settle(model)
            client.scanRows = []
            model.loadAllBotSessions(force: true)
            await model.allBotSessionsTask?.value
            #expect(snapshot(model).allProfilePinPresentation.sessions.isEmpty)
        }
    }

    @Test func selectedOwnersUnpinStaysRemovedAfterSwitchAndScanOmission() async throws {
        try await withModel { model, client in
            let pinned: [String: Any] = ["id": "shared", "title": "A pin", "pinned": true]
            client.rowsByProfile["bot-a"] = [pinned]
            client.scanRows = [pinned.merging(["profile": "bot-a"]) { _, new in new }]
            model.setProfileScope("bot-a")
            await settle(model)
            model.setProfileScope("bot-b")
            await settle(model)
            model.setProfileScope("bot-a")
            await settle(model)
            let pin = try #require(snapshot(model).allProfilePinPresentation.sessions.first)
            client.scanRows = []
            #expect(await model.toggleSessionPinned(pin, isPinned: true))
            model.setProfileScope("bot-b")
            await settle(model)
            #expect(snapshot(model).allProfilePinPresentation.sessions.isEmpty)
        }
    }

    @Test func renameFencesOnlyItsOwnRowInAHeldScan() async throws {
        try await withModel { model, client in
            let renamed: [String: Any] = ["id": "shared", "profile": "bot-a", "title": "Old", "pinned": true]
            let sibling: [String: Any] = ["id": "sibling", "profile": "bot-a", "title": "Sibling", "pinned": true]
            client.rowsByProfile["bot-a"] = [renamed, sibling]
            model.setProfileScope("bot-a")
            await settle(model)
            model.setProfileScope("bot-b")
            await settle(model)
            let key = ProfileScopedID(profileID: "bot-a", resourceID: "shared")
            let pin = try #require(snapshot(model).allProfilePinPresentation.selectedRow(key))
            #expect(Set(snapshot(model).allProfilePinPresentation.sessions.map(\.id)) == ["shared", "sibling"])

            let (started, didStart) = AsyncStream<Void>.makeStream()
            let (hold, release) = AsyncStream<Void>.makeStream()
            defer { release.finish() }
            client.scanRows = [renamed, sibling.merging(["pinned": false]) { _, new in new }]
            client.scanGate = (didStart, hold)
            model.loadAllBotSessions(force: true)
            let scan = model.allBotSessionsTask
            for await _ in started {}
            #expect(await model.renameSession(pin, title: "New"))
            release.finish()
            await scan?.value
            await settle(model)

            let settled = snapshot(model)
            #expect(settled.allBotConversations.first { $0.scopedID == key }?.title == "Old")
            #expect(settled.allProfilePinned.first { $0.scopedID == key }?.title == "New")
            let pins = settled.allProfilePinPresentation
            #expect(pins.sessions.map(\.id) == ["shared"])
            #expect(pins.selectedRow(key)?.title == "New")
        }
    }

    @Test func remoteUnpinACKUpdatesTheOwnerSelectedWhileTheWriteWasPending() async throws {
        try await withModel { model, client in
            let pinned: [String: Any] = ["id": "shared", "profile": "bot-a", "title": "A pin", "pinned": true]
            client.rowsByProfile["bot-a"] = [pinned]
            client.scanRows = [pinned]
            model.setProfileScope("bot-b")
            await settle(model)
            model.loadAllBotSessions(force: true)
            await settle(model)
            let key = ProfileScopedID(profileID: "bot-a", resourceID: "shared")
            let pin = try #require(snapshot(model).allProfilePinPresentation.selectedRow(key))

            let (patchStarted, didStartPatch) = AsyncStream<Void>.makeStream()
            let (holdPatch, releasePatch) = AsyncStream<Void>.makeStream()
            let (readStarted, didStartRead) = AsyncStream<Void>.makeStream()
            let (holdRead, releaseRead) = AsyncStream<Void>.makeStream()
            defer {
                releasePatch.finish()
                releaseRead.finish()
            }
            client.pinACKGate = (didStartPatch, holdPatch)
            let unpin = Task { await model.toggleSessionPinned(pin, isPinned: true) }
            for await _ in patchStarted {}
            model.setProfileScope("bot-a")
            await settle(model)
            #expect(model.pinnedSessions.map(\.id) == ["shared"])

            client.scopedReadGate = (didStartRead, holdRead)
            let staleRead = model.loadSessions(quiet: true)
            for await _ in readStarted {}
            client.scanRows = []
            releasePatch.finish()
            #expect(await unpin.value)
            #expect(model.pinnedSessions.isEmpty)
            releaseRead.finish()
            await staleRead?.value
            await settle(model)
            #expect(snapshot(model).allProfilePinPresentation.selectedRow(key) == nil)
        }
    }

    @Test func retainedPinSelectionRenameAndMenuLookupUseTheOwner() async throws {
        try await withModel { model, client in
            client.rowsByProfile["bot-a"] = [["id": "shared", "title": "A pin", "pinned": true]]
            client.rowsByProfile["bot-b"] = [["id": "shared", "title": "B pin", "pinned": true]]
            client.scanRows = []
            model.setProfileScope("bot-a")
            await settle(model)
            model.setProfileScope("bot-b")
            await settle(model)
            let aKey = ProfileScopedID(profileID: "bot-a", resourceID: "shared")
            let bKey = ProfileScopedID(profileID: "bot-b", resourceID: "shared")
            let presentation = snapshot(model).allProfilePinPresentation
            #expect(Set(presentation.sessions.map(\.scopedID)) == [aKey, bKey])
            let retainedPin = try #require(presentation.selectedRow(aKey))
            #expect(presentation.selectedRow(bKey)?.title == "B pin")
            #expect(model.isAllProfileSessionPinned(retainedPin))
            #expect(!model.isAllProfileSessionPinned(retainedPin.withPinned(true, profileID: "bot-c")))
            #expect(await model.renameSession(retainedPin, title: "A renamed"))
            await settle(model)
            #expect(client.renameCommand?.contains("bot-a") == true)
            let renamed = snapshot(model).allProfilePinPresentation
            #expect(renamed.selectedRow(aKey)?.title == "A renamed")
            #expect(renamed.selectedRow(bKey)?.title == "B pin")
        }
    }

    @Test func returningToAProfileShowsItsListAtOnceThenRefreshesQuietly() async throws {
        try await withModel { model, client in
            model.setProfileScope("bot-a")
            await settle(model)
            model.setProfileScope("bot-b")
            #expect(model.sessions.isEmpty)
            #expect(model.sessionProjectionState == .loading)
            await settle(model)
            #expect(model.sessions.map(\.id) == ["b-1"])

            client.rowsByProfile["bot-a"]?.append(["id": "a-2", "title": "A two", "last_activity_at": 400])
            model.setProfileScope("bot-a")
            // Shown before Hermes answers, and the re-read does not flip to a loading state.
            #expect(model.sessions.map(\.id) == ["a-1"])
            #expect(model.sessionProjectionState == .ready(model.sessions))
            #expect(!model.isLoadingSessions)
            await settle(model)
            #expect(Set(model.sessions.map(\.id)) == ["a-1", "a-2"])
            #expect(model.sessions.allSatisfy { $0.profileID == "bot-a" })
            #expect(client.listedProfiles == ["bot-a", "bot-b", "bot-a"])
        }
    }

    @Test func firstVisitShowsThatProfilesRowsFromTheBackgroundScan() async throws {
        try await withModel { model, client in
            client.scanRows = [
                ["id": "a-1", "title": "A one", "profile": "bot-a", "last_activity_at": 200],
                ["id": "b-old", "title": "B old", "profile": "bot-b", "last_activity_at": 100],
                ["id": "b-pin", "title": "B pin", "profile": "bot-b", "last_activity_at": 150, "pinned": true],
            ]
            model.setProfileScope("bot-a")
            await settle(model)
            #expect(model.allBotSessionsState != .loading)

            model.setProfileScope("bot-b")
            #expect(model.sessions.map(\.id) == ["b-pin", "b-old"])
            #expect(model.pinnedSessions.map(\.id) == ["b-pin"])
            #expect(model.sessions.allSatisfy { $0.profileID == "bot-b" })
            await settle(model)
            // The profile's own read replaces the preview.
            #expect(model.sessions.map(\.id) == ["b-1"])
        }
    }

    @Test func switchingToAnAllProfilesPinKeepsThePinnedCountBeforeTheIndexReturns() async throws {
        try await withModel { model, client in
            let control = ControlCenterModel()
            @MainActor
            func snapshot(reusing previous: SessionNavSidebarSnapshot? = nil) -> SessionNavSidebarSnapshot {
                SessionNavSidebarSnapshot(
                    inputs: SessionNavSidebarSnapshot.inputs(model: model, control: control), reusing: previous)
            }

            // Visit B before B's pin exists, so its retained scoped list has no pins.
            model.setProfileScope("bot-b")
            await settle(model)
            client.rowsByProfile["bot-a"] = [["id": "a-pin", "title": "A pin", "pinned": true]]
            model.setProfileScope("bot-a")
            await settle(model)
            // B's new pin is already known to All profiles; A's older pin is outside the recents scan.
            let remotePin: [String: Any] = ["id": "b-pin", "title": "B pin", "pinned": true]
            client.rowsByProfile["bot-b"]?.append(remotePin)
            client.scanRows = [remotePin.merging(["profile": "bot-b"]) { value, _ in value }]
            model.loadAllBotSessions(force: true)
            await model.allBotSessionsTask?.value

            let before = snapshot()
            let a = try #require(before.allProfilePinPresentation.sessions.first { $0.id == "a-pin" })
            let b = try #require(before.allProfilePinPresentation.sessions.first { $0.id == "b-pin" })
            let expected = Set([a.scopedID, b.scopedID])
            try #require(before.allProfilePinPresentation.count == 2)

            // The sidebar switches to the owner before it resumes the selected row.
            model.resumeSession(a)
            _ = await model.sessionResumeTask?.value
            model.setProfileScope("bot-b")
            model.resumeSession(b)
            let during = snapshot(reusing: before).allProfilePinPresentation
            #expect(during.count == 2)
            #expect(Set(during.sessions.map(\.scopedID)) == expected)
            _ = await model.sessionResumeTask?.value
            await settle(model)
            #expect(Set(snapshot().allProfilePinPresentation.sessions.map(\.scopedID)) == expected)

            model.allBotSessionsState = .ready([a.withPinned(false, profileID: "bot-a"), b])
            #expect(snapshot().allProfilePinPresentation.sessions.map(\.scopedID) == [b.scopedID])
            model.allBotSessionsState = .ready([b])
            #expect(snapshot().allProfilePinPresentation.sessions.map(\.scopedID) == [b.scopedID])
        }
    }

    @Test func aProfileWithoutLoadedRowsStillLoadsNormally() async throws {
        try await withModel { model, _ in
            model.setProfileScope("bot-a")
            // Left before its list arrived: nothing honest to retain.
            model.setProfileScope("bot-b")
            await settle(model)
            model.setProfileScope("bot-a")
            #expect(model.sessionProjectionState == .loading)
            await settle(model)
            #expect(model.sessions.map(\.id) == ["a-1"])
        }
    }

    @Test func returningReportsTheChatTheProfileWasLeftOn() async throws {
        try await withModel { model, _ in
            model.setProfileScope("bot-a")
            await settle(model)
            let chat = try #require(model.sessions.first)
            #expect(await model.resumeSession(chat, reportFailure: true))

            #expect(model.setProfileScope("bot-b") == nil)
            await settle(model)
            let returning = try #require(model.setProfileScope("bot-a"))
            #expect(returning.id == "a-1")
            #expect(returning.profileID == "bot-a")

            // Leaving on a new chat reopens nothing.
            model.newChat()
            model.setProfileScope("bot-b")
            #expect(model.setProfileScope("bot-a") == nil)
        }
    }

    @Test func deletedAndPinnedSessionsUpdateTheRetainedCopy() {
        let model = DockModel(rpcClient: ProfileSessionsRPCClient())
        defer { model.shutdown() }
        let kept = HermesSession(
            id: "keep", profileID: "bot-a", title: "", preview: "", startedAt: nil, messageCount: 0, source: "")
        let gone = HermesSession(
            id: "gone", profileID: "bot-a", title: "", preview: "", startedAt: nil, messageCount: 0, source: "")
        model.retainedProfileSessions["bot-a"] = RetainedProfileSessions(
            sessions: [kept, gone], pinnedSessions: [gone], historyLoadedAt: Date(), openSession: gone)

        model.forgetRetainedSession("gone", profileID: "bot-a")
        model.applyRetainedPin(true, to: kept, profileID: "bot-a")

        let retained = model.retainedProfileSessions["bot-a"]
        #expect(retained?.sessions.map(\.id) == ["keep"])
        #expect(retained?.pinnedSessions.map(\.id) == ["keep"])
        #expect(retained?.openSession == nil)
        #expect(retained?.historyLoadedAt == nil)
    }
}
