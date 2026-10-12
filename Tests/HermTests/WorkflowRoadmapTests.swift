import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
private final class WorkflowFixture: HermesRPCClientProtocol {
  var onEvent: ((String, [String: Any]) -> Void)?
  var calls: [(String, [String: Any])] = []
  var replies: [String: [String: Any]] = [:]
  var failures = Set<String>()
  var searchDelay = false
  func connect() async throws {}
  func close() {}
  func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
    calls.append((method, params))
    if failures.contains(method) {
      throw NSError(
        domain: "fixture", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "unknown method: \(method)"])
    }
    if let result = replies[method] { return result }
    if method == "session.resume" {
      return [
        "session_id": "runtime", "stored_session_id": params["session_id"] ?? "owner",
        "info": ["profile_name": params["profile"] ?? "default", "cwd": "/tmp/worktree"],
        "running": false,
      ]
    }
    return [:]
  }
  func fetchHTTP(_ path: String) async throws -> [String: Any] {
    calls.append(("GET " + path, [:]))
    if path.hasPrefix("/api/sessions/search") {
      if searchDelay && path.contains("q=older") { try? await Task.sleep(for: .milliseconds(150)) }
      return replies["search"] ?? [
        "results": [
          [
            "session_id": path.contains("q=older") ? "older" : "newer", "profile": "research",
            "snippet": "A past decision",
          ]
        ]
      ]
    }
    return replies["GET"] ?? [:]
  }
  func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
    calls.append((method + " " + path, body))
    return replies[method] ?? ["ok": true]
  }
}

@MainActor
struct WorkflowRoadmapTests {
  private var owner: HermesSession {
    HermesSession(
      id: "owner", profileID: "research", title: "Research", preview: "", startedAt: nil,
      messageCount: 0, source: "herm")
  }
  private func options(accounts: [[String: Any]] = []) -> [String: Any] {
    [
      "provider": "codex", "model": "configured",
      "providers": [["slug": "codex", "models": ["configured"], "usage": ["accounts": accounts]]],
    ]
  }
  private func refusing(_ operation: () async throws -> Void) async {
    do {
      try await operation()
      Issue.record("An unacknowledged or wrongly scoped operation succeeded")
    } catch {}
  }
  @Test func wrongProfileCannotResumeOrMutate() async {
    let client = WorkflowFixture()
    await refusing {
      _ = try await HermesWorkflowRPC(client: client, profileID: "coding").resumeOwned(owner)
    }
    #expect(client.calls.isEmpty)
  }
  @Test func resumeRequiresDurableOwnerAndNamedProfileEcho() async {
    for result: [String: Any] in [
      ["session_id": "other", "info": ["profile_name": "research"]],
      ["session_id": "runtime", "stored_session_id": "owner", "info": ["profile_name": "coding"]],
      ["session_id": "runtime", "stored_session_id": "owner"],
    ] {
      let client = WorkflowFixture()
      client.replies["session.resume"] = result
      await refusing {
        _ = try await HermesWorkflowRPC(client: client, profileID: "research").sessionDirectory(
          owner)
      }
      #expect(client.calls.count == 1)
    }
  }
  @Test func launchProfileCannotAcceptAnotherProfileResponse() async {
    let client = WorkflowFixture()
    client.replies["session.resume"] = [
      "session_id": "launch-owner", "info": ["profile_name": "coding", "cwd": "/tmp/worktree"],
      "running": false,
    ]
    let launch = HermesSession(
      id: "launch-owner", title: "Launch", preview: "", startedAt: nil, messageCount: 0,
      source: "herm")
    await refusing {
      _ = try await HermesWorkflowRPC(client: client, profileID: nil).resumeOwned(launch)
    }
    await refusing {
      _ = try EdgeResultContent.parse(
        ["profile": "coding", "data": [["role": "assistant", "content": "Wrong owner"]]],
        session: launch)
    }
  }
  @Test func directoryReadUsesOneScopedResume() async throws {
    let client = WorkflowFixture()
    let directory = try await HermesWorkflowRPC(client: client, profileID: "research")
      .sessionDirectory(owner)
    #expect(directory == "/tmp/worktree")
    #expect(client.calls.count == 1)
    #expect(client.calls[0].1["profile"] as? String == "research")
    #expect(client.calls[0].1["session_id"] as? String == "owner")
  }
  @Test func accountMappingAndLowQuotaAreConservative() throws {
    let account: [String: Any] = [
      "id": "account-a", "state": "limited",
      "windows": [
        ["scope": "account", "used_percent": 80, "resets_at": "tomorrow"],
        ["scope": "model", "used_percent": 99],
      ],
    ]
    let single = try SessionCapacitySnapshot.parse(
      session: owner, runtimeID: "runtime", running: false, result: options(accounts: [account]))
    #expect(single.allowance == 20 && single.low)
    #expect(single.resetsAt == "tomorrow")
    for accounts in [
      [], [account, account], [["state": "ready", "windows": [["used_percent": 90]]]],
    ] {
      let unknown = try SessionCapacitySnapshot.parse(
        session: owner, runtimeID: "runtime", running: false, result: options(accounts: accounts))
      #expect(unknown.allowance == nil && !unknown.low)
    }
  }
  @Test func modelChoiceRequiresIdleConfiguredAcknowledgedSessionScope() async throws {
    let choice = HermesModelOption(provider: "codex", model: "configured")
    for acknowledgment: [String: Any] in [
      [:], ["key": "model", "value": "configured", "scope": "global"],
      ["key": "model", "value": "configured", "scope": "session", "deferred": true],
    ] {
      let client = WorkflowFixture()
      client.replies["model.options"] = options()
      client.replies["config.set"] = acknowledgment
      await refusing {
        try await HermesWorkflowRPC(client: client, profileID: "research").setSessionModel(
          owner, option: choice)
      }
    }
    let client = WorkflowFixture()
    client.replies["model.options"] = options()
    client.replies["config.set"] = ["key": "model", "scope": "session", "value": "configured"]
    try await HermesWorkflowRPC(client: client, profileID: "research").setSessionModel(
      owner, option: choice)
    let mutation = try #require(client.calls.last)
    #expect(mutation.1["session_id"] as? String == "runtime")
    #expect(mutation.1["profile"] as? String == "research")
  }
  @Test func busySessionAndUnconfiguredModelNeverReachConfigSet() async {
    let client = WorkflowFixture()
    client.replies["session.resume"] = [
      "session_id": "runtime", "stored_session_id": "owner", "profile": "research", "running": true,
    ]
    await refusing {
      try await HermesWorkflowRPC(client: client, profileID: "research").setSessionModel(
        owner, option: HermesModelOption(provider: "x", model: "y"))
    }
    #expect(!client.calls.contains { $0.0 == "config.set" })
    client.replies["session.resume"] = nil
    client.replies["model.options"] = options()
    await refusing {
      try await HermesWorkflowRPC(client: client, profileID: "research").setSessionModel(
        owner, option: HermesModelOption(provider: "x", model: "y"))
    }
    #expect(!client.calls.contains { $0.0 == "config.set" })
  }
  @Test func stoppingAndRoutinePauseRejectNegativeAcknowledgments() async {
    let client = WorkflowFixture()
    client.replies["session.interrupt"] = ["status": "not_interrupted"]
    let service = HermesWorkflowRPC(client: client, profileID: "research")
    await refusing { try await service.stopSession(owner) }
    client.replies["cron.manage"] = [
      "success": true, "job": ["job_id": "different", "enabled": false],
    ]
    await refusing { try await service.setRoutinePaused("job", paused: true) }
    #expect(client.calls.last?.1["profile"] as? String == "research")
  }
  @Test func repeatRoutineTriggersArePreventedAndOwnerIsCaptured() async {
    let client = WorkflowFixture()
    client.replies["cron.manage"] = [
      "scoped": "research",
      "jobs": [["job_id": "job", "name": "Daily", "enabled": true, "schedule": "daily"]],
    ]
    client.replies["shell.exec"] = ["code": 0, "stdout": "", "stderr": ""]
    let control = ControlCenterModel(
      rpc: HermesControlRPC(client: client),
      capabilities: [
        CapabilityState(
          id: "cron.runNow", title: "Run now", detail: "Available", isAvailable: true, recovery: nil
        )
      ])
    let reference = RoutineReference(
      profileID: "research",
      job: CronSummary(id: "job", name: "Daily", schedule: "daily", enabled: true, nextRun: nil),
      run: nil)
    async let first: Void = control.recoverRoutine(reference, run: true)
    async let second: Void = control.recoverRoutine(reference, run: true)
    _ = await (first, second)
    #expect(
      client.calls.filter {
        $0.0 == "shell.exec" && ($0.1["command"] as? String)?.contains("'cron' 'run' 'job'") == true
      }.count == 1)
    #expect(!control.canTriggerRoutine(reference))
    await control.confirmRoutineReview(reference)
    #expect(control.canTriggerRoutine(reference))
    #expect(
      client.calls.filter { $0.0 == "cron.manage" }.allSatisfy {
        $0.1["profile"] as? String == "research"
      })
    #expect(
      client.calls.first { $0.0 == "shell.exec" }?.1["command"] as? String
        == "'hermes' '--profile' 'research' 'cron' 'run' 'job'")
  }
  @Test func routineWorkspaceNavigationRetainsOwnerUntilItsInventoryArrives() {
    let control = ControlCenterModel()
    let reference = RoutineReference(
      profileID: "research",
      job: CronSummary(id: "job", name: "Job", schedule: "daily", enabled: true, nextRun: nil),
      run: nil)
    control.requestAutomation(reference)
    #expect(control.requestedAutomationOwner?.profileID == "research")
    #expect(control.requestedAutomationJobID == "job")
    #expect(!control.requestedAutomationMatchesInventory())
    var launch = reference.job
    launch.owner = CronOwner(profileID: nil)
    control.requestAutomation(RoutineReference(profileID: nil, job: launch, run: nil))
    #expect(control.requestedAutomationMatchesInventory())
    #expect(control.profileForRoutine(launch) == nil)
  }
  @Test func routineListingRejectsUnscopedNamedInventory() async {
    let client = WorkflowFixture()
    client.replies["cron.manage"] = ["jobs": [], "scoped": "coding"]
    await refusing {
      _ = try await HermesWorkflowRPC(client: client, profileID: "research").routineJobs()
    }
  }
  @Test func executionAndDeliveryRemainIndependent() {
    let job = CronSummary(
      id: "job", name: "Job", schedule: "daily", enabled: true, nextRun: nil,
      lastRunAt: "2026-10-11T12:00:00Z", lastStatus: "ok",
      details: CronJobDetails(deliveryError: "delivery failed"))
    let reference = RoutineReference(profileID: "research", job: job, run: nil)
    #expect(reference.needsAttention)
    #expect(AutomationWorkspaceRowPresentation.make(job: job, latestRun: nil).result == .succeeded)
    #expect(reference.row.phase == .attention)
    #expect(reference.row.routine?.profileID == "research")
  }
  @Test func oauthCancellationCarriesCapturedProfileAndFlow() async throws {
    let client = WorkflowFixture()
    client.replies["mcp.servers.oauth.cancel"] = ["ok": true]
    try await HermesWorkflowRPC(client: client, profileID: "research").cancelOAuth(
      "docs", flow: "captured-flow")
    #expect(client.calls.last?.1["profile"] as? String == "research")
    #expect(client.calls.last?.1["session_id"] as? String == "captured-flow")
    client.replies["mcp.servers.oauth.start"] = [
      "ok": true, "session_id": "flow", "auth_url": "file:///tmp/credential",
    ]
    await refusing {
      _ = try await HermesWorkflowRPC(client: client, profileID: "research").startOAuth("docs")
    }
  }
  @Test func unsupportedIntegrationOperationDoesNotDisableOthers() async {
    let client = WorkflowFixture()
    client.failures.insert("skills.manage")
    client.replies["mcp.servers.test"] = ["ok": true, "oauth_needed": false, "tools": []]
    let model = WorkflowIntegrationModel(client: client, profileID: "research")
    await model.perform("Inspect", item: WorkflowIntegrationItem(id: "skill", detail: ""))
    #expect(model.unsupported.contains("Inspect"))
    await model.perform("Test", item: WorkflowIntegrationItem(id: "docs", detail: ""))
    #expect(model.status.contains("Connection confirmed"))
  }
  @Test func skillRemovalChecksReturnedProcessInsteadOfAssumingSuccess() async throws {
    let client = WorkflowFixture()
    client.replies["POST"] = ["ok": true, "pid": 123, "name": "skills-uninstall-example-abcd"]
    let service = HermesWorkflowRPC(client: client, profileID: "research")
    let removal = try await service.removeSkill("example")
    client.replies["GET"] = ["name": removal.name, "pid": 124, "running": false, "exit_code": 0]
    await refusing { _ = try await service.skillRemovalOutcome(removal) }
    client.replies["GET"] = ["name": removal.name, "pid": 123, "running": false, "exit_code": 1]
    #expect(try await service.skillRemovalOutcome(removal) == 1)
    #expect(client.calls.first?.1["profile"] as? String == "research")
  }
  @Test func customMCPSetupRejectsEmbeddedCredentials() async {
    let client = WorkflowFixture()
    await refusing {
      try await HermesWorkflowRPC(client: client, profileID: "research").addCustomMCP(
        name: "docs", url: "https://user:secret@example.com/mcp")
    }
    #expect(client.calls.isEmpty)
  }
  @Test func memoryEditingUsesFingerprintsAndNamedProfileHTTP() async throws {
    let client = WorkflowFixture()
    let id = "memory:memory:2:0123456789abcdef"
    client.replies["GET"] = ["ok": true, "id": id, "kind": "memory", "content": "An old decision"]
    let service = HermesWorkflowRPC(client: client, profileID: "research")
    #expect(try await service.memoryDetail(id) == "An old decision")
    try await service.correctMemory(id, content: "Corrected decision")
    #expect(
      client.calls.allSatisfy {
        $0.0.contains("/api/learning/node") && $0.0.contains("profile=research")
      })
    #expect(client.calls.last?.1["profile"] as? String == "research")
    #expect(client.calls.last?.1["id"] as? String == id)
    let previous = client.calls.count
    await refusing {
      try await service.correctMemory("memory:memory:2", content: "Unsafe positional edit")
    }
    #expect(client.calls.count == previous)
  }
  @Test func memoryDetailNeverTruncatesAnEditableEntry() async {
    let client = WorkflowFixture()
    let id = "memory:profile:0:0123456789abcdef"
    client.replies["learning.detail"] = [
      "ok": true, "id": id, "kind": "memory", "content": String(repeating: "x", count: 64_001),
    ]
    await refusing {
      _ = try await HermesWorkflowRPC(client: client, profileID: nil).memoryDetail(id)
    }
  }
  @Test func subagentSteeringRemainsQueuedAndTargetsExactRuntime() async throws {
    let client = WorkflowFixture()
    client.replies["subagent.list"] = [
      "subagents": [
        [
          "subagent_id": "child", "status": "running", "accepting_steer": true,
          "goal": "Inspect sources",
        ], ["subagent_id": "finished", "status": "completed"],
      ]
    ]
    client.replies["subagent.steer"] = ["subagent_id": "child", "status": "queued"]
    let service = HermesWorkflowRPC(client: client, profileID: "research")
    let live = try await service.liveSubagents(owner)
    #expect(live.1.map(\.id) == ["child"])
    #expect(
      try await service.steer(sessionID: live.0, subagentID: "child", text: "Use primary sources")
        == .queued)
    #expect(client.calls.last?.1["session_id"] as? String == "runtime")
    #expect(client.calls.last?.1["profile"] as? String == "research")
    client.replies["subagent.steer"] = ["subagent_id": "different", "status": "queued"]
    await refusing {
      _ = try await service.steer(sessionID: live.0, subagentID: "child", text: "Correction")
    }
  }
  @Test func recallRejectsWrongProfileAndDiscardsLateResults() async throws {
    let client = WorkflowFixture()
    let model = EdgeRecallModel()
    client.replies["search"] = [
      "results": [["session_id": "other", "profile": "coding", "snippet": "wrong"]]
    ]
    await model.search("decision", profileID: "research", client: client)
    #expect(model.hits.isEmpty && model.error != nil)
    client.replies["search"] = nil
    client.searchDelay = true
    let old = Task { await model.search("older", profileID: "research", client: client) }
    try await Task.sleep(for: .milliseconds(320))
    await model.search("newer", profileID: "research", client: client)
    await old.value
    #expect(model.hits.map(\.session.id) == ["newer"])
    #expect(
      client.calls.contains { $0.0.contains("profile=research") && $0.0.contains("limit=20") })
  }
  @Test func savedReferencesRetainOriginsButDiscardRuntimeAliases() throws {
    let name = "workflow-test-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = CommandCenterPreferencesStore(defaults: defaults)
    let destination = QuickDestination(
      profileID: "research", sessionID: "owner", runtimeID: "ephemeral", title: "Research",
      projectPath: "/tmp/worktree")
    preferences.saveWorkingSet(name: "Research", destination: destination)
    preferences.pinSource(
      origin: destination, url: "https://example.com/paper", label: "Primary source")
    preferences.pinSource(origin: destination, url: "file:///tmp/private")
    let restored = CommandCenterPreferencesStore(defaults: defaults)
    #expect(restored.workingSets.first?.destinations.first?.runtimeID == nil)
    #expect(restored.workingSets.first?.destinations.first?.profileID == "research")
    #expect(
      restored.sourcePins.count == 1 && restored.sourcePins.first?.origin.sessionID == "owner")
  }
  @Test func sourcePinsRetainReplyReferencesAcrossRestarts() throws {
    let name = "workflow-source-revisions-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = CommandCenterPreferencesStore(defaults: defaults)
    let origin = QuickDestination(profileID: "research", sessionID: "owner")
    preferences.pinSource(origin: origin, url: "https://example.com/paper", revisionID: "reply-a")
    preferences.pinSource(origin: origin, url: "https://example.com/paper", revisionID: "reply-b")
    preferences.pinSource(origin: origin, url: "https://example.com/paper", revisionID: "reply-b")
    let restored = CommandCenterPreferencesStore(defaults: defaults)
    #expect(restored.sourcePins.map(\.revisionID) == ["reply-a", "reply-b"])
    let content = EdgeResultContent(text: "Reviewed excerpt", artifacts: [], revisionID: "reply-b")
    let markdown = ResultSourceLinks.markdown(content, origin: origin, pins: restored.sourcePins)
    #expect(markdown.contains("Reply reference: reply-b"))
    #expect(markdown.contains("pinned from reply reference reply-a"))
  }
  @Test func recallInsertionAndPreviewNavigationPreserveRecipientAndDraft() {
    let state = EdgeNotchState()
    state.selectQuickTarget(owner)
    state.quickDraft = "Existing correction"
    state.insertRecall(
      RecallHit(
        session: HermesSession(
          id: "source", profileID: "coding", title: "Source", preview: "", startedAt: nil,
          messageCount: 0, source: "herm"), snippet: "A past decision"))
    #expect(state.captureRecord().destination.sessionID == "owner")
    #expect(state.quickSources.contains("Source conversation: coding/source"))
    state.capacityTarget = owner
    state.steeringTarget = owner
    state.showingRecall = true
    state.clearPreviewDetails()
    #expect(!state.isReadingDetail)
    #expect(state.quickDraft.contains("Existing correction"))
  }
  @Test func savedSessionDestinationKeepsItsExplicitProject() {
    let state = EdgeNotchState()
    let destination = QuickDestination(
      profileID: "research", sessionID: "owner", title: "Research",
      projectPath: "/tmp/explicit-project")
    state.useSavedDestination(destination)
    #expect(state.captureRecord().destination.projectPath == "/tmp/explicit-project")
    #expect(state.captureRecord().destination.sessionID == "owner")
  }
  @Test func sourceShelfOnlyOffersActualHTTPLinks() {
    let links = ResultSourceLinks.candidates(
      in: "Use https://example.com/paper and file:///private/note. Also https://example.com/paper")
    #expect(links == ["https://example.com/paper"])
  }
  @Test func isolatedSessionFailureRetainsWorktreeAndReturnedSession() async {
    let client = WorkflowFixture()
    client.replies["session.create"] = ["session_id": "runtime", "stored_session_id": "owner"]
    let result = await HermesWorkflowRPC(client: client, profileID: "research")
      .createIsolatedSession(path: "/tmp/different-worktree", text: "Build this", id: UUID())
    #expect(result.draft.destination.projectPath == "/tmp/different-worktree")
    #expect(result.draft.destination.sessionID == "owner")
    #expect(result.draft.delivery == .needsReview)
    #expect(result.error != nil)
    #expect(!client.calls.contains { $0.0 == "prompt.submit" })
    #expect(client.calls.first?.1["cwd_explicit"] as? Bool == true)
  }
  @Test func baselineRequiresAcknowledgedObservedTurnAndRejectsLateAcknowledgments() {
    let developer = DeveloperWorkflowModel()
    let origin = QuickDestination(profileID: "research", sessionID: "owner")
    let attempt = UUID()
    developer.turnBaselines[origin.sessionKey] = TurnRepositoryBaseline(
      origin: origin, path: "/tmp/worktree", head: "abcdef", clean: true, capturedAt: .now,
      attemptID: attempt)
    developer.observeTurnBaseline(origin: origin, started: true)
    #expect(developer.turnBaselines[origin.sessionKey]?.eligible == false)
    developer.acknowledgeTurnBaseline(origin: origin, attemptID: UUID())
    #expect(developer.turnBaselines[origin.sessionKey]?.acknowledged == false)
    developer.acknowledgeTurnBaseline(origin: origin, attemptID: attempt)
    developer.observeTurnBaseline(origin: origin, completed: true)
    #expect(developer.turnBaselines[origin.sessionKey]?.eligible == true)
    developer.observeTurnBaseline(origin: origin, started: true)
    #expect(developer.turnBaselines[origin.sessionKey] == nil)
  }
  @Test func missingStartAndFailedSubmissionCannotLabelChangesSinceTurnStarted() {
    let developer = DeveloperWorkflowModel()
    let origin = QuickDestination(profileID: "research", sessionID: "owner")
    developer.turnBaselines[origin.sessionKey] = TurnRepositoryBaseline(
      origin: origin, path: "/tmp/worktree", head: "abcdef", clean: true, capturedAt: .now)
    developer.observeTurnBaseline(origin: origin, completed: true)
    #expect(developer.turnBaselines[origin.sessionKey] == nil)
    developer.turnBaselines[origin.sessionKey] = TurnRepositoryBaseline(
      origin: origin, path: "/tmp/worktree", head: "abcdef", clean: true, capturedAt: .now)
    developer.observeTurnBaseline(origin: origin, started: true, failed: true)
    #expect(developer.turnBaselines[origin.sessionKey] == nil)
  }
  @Test func realGitBaselineAndIsolatedWorktreeStayWithinTheFixture() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "herm-workflow-git-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ arguments: [String]) throws {
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["-C", root.path] + arguments
      process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
      process.standardOutput = pipe
      process.standardError = pipe
      try process.run()
      _ = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)
    }
    try git(["init", "--quiet"])
    let file = root.appendingPathComponent("decision.txt")
    try "original".write(to: file, atomically: true, encoding: .utf8)
    try git(["add", "decision.txt"])
    try git([
      "-c", "user.name=Workflow Fixture", "-c", "user.email=fixture@example.invalid", "commit",
      "--quiet", "-m", "Fixture",
    ])
    let origin = QuickDestination(profileID: "research", sessionID: "owner")
    let developer = DeveloperWorkflowModel()
    await developer.captureTurnBaseline(origin: origin, path: root.path)
    let baseline = try #require(developer.turnBaselines[origin.sessionKey])
    #expect(baseline.clean)
    let head = try #require(baseline.head)
    try "updated".write(to: file, atomically: true, encoding: .utf8)
    #expect(
      try await RepositoryService.changesSince(path: root.path, head: head) == ["decision.txt"])
    #expect(
      try await RepositoryService.diffSince(path: root.path, head: head, file: "decision.txt")
        .contains("+updated"))
    await developer.captureTurnBaseline(origin: origin, path: root.path)
    #expect(developer.turnBaselines[origin.sessionKey]?.clean == false)
    let storage = root.appendingPathComponent("isolated")
    let worktree = try await RepositoryService.createTaskWorktree(
      path: root.path, id: UUID(), storage: storage)
    #expect(worktree.hasPrefix(storage.path))
    #expect(
      try String(
        contentsOf: URL(fileURLWithPath: worktree).appendingPathComponent("decision.txt"),
        encoding: .utf8) == "original")
    #expect(try String(contentsOf: file, encoding: .utf8) == "updated")
    await refusing {
      _ = try await RepositoryService.diffSince(path: root.path, head: head, file: "../outside")
    }
    try git(["worktree", "remove", worktree])
  }
  @Test func renderNewPreviewStatesAtTheFixedGeometry() async throws {
    guard let directory = ProcessInfo.processInfo.environment["NOTCH_SNAPSHOT_DIR"] else { return }
    let client = WorkflowFixture()
    client.replies["model.options"] = options(accounts: [
      ["id": "account-a", "state": "limited", "windows": [["used_percent": 90]]]
    ])
    client.replies["subagent.list"] = [
      "subagents": [
        [
          "subagent_id": "child", "status": "running", "accepting_steer": true,
          "goal": "Inspect primary sources",
        ]
      ]
    ]
    let service = HermesWorkflowRPC(client: client, profileID: "research")
    let state = EdgeNotchState()
    state.selectQuickTarget(owner)
    let model = DockModel(initialSessionID: "workspace", rpcClient: client)
    let name = "workflow-render-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = CommandCenterPreferencesStore(defaults: defaults)
    let job = CronSummary(
      id: "job", name: "Daily research", schedule: "daily", enabled: true, nextRun: nil,
      lastStatus: "error", lastError: "Provider unavailable",
      details: CronJobDetails(deliveryError: "Delivery failed separately"))
    let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
    let views: [(String, AnyView)] = [
      (
        "capacity",
        AnyView(EdgeSessionCapacity(destination: owner, service: service, back: {}, open: {}))
      ),
      (
        "steering",
        AnyView(EdgeSubagentSteering(origin: owner, service: service, back: {}, open: {}))
      ),
      (
        "recall-empty",
        AnyView(
          EdgeRecallView(
            profileID: "research", client: client, back: {}, open: { _ in }, insert: { _ in }))
      ),
      (
        "routine-failure",
        AnyView(
          EdgeRoutinePreview(
            reference: RoutineReference(profileID: "research", job: job, run: nil),
            control: control, preferences: preferences, back: {}, openAutomation: {}))
      ),
      (
        "working-sets",
        AnyView(EdgeWorkingSetsView(state: state, model: model, back: {}, openWorkspace: {}))
      ),
    ]
    for (name, view) in views {
      let host = NSHostingView(
        rootView: view.background(Color.dockCanvas).dockThemedRoot().frame(width: 368, height: 308)
      )
      host.frame = NSRect(x: 0, y: 0, width: 368, height: 308)
      let window = NSPanel(
        contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
        defer: false)
      window.appearance = NSAppearance(named: .darkAqua)
      window.contentView = host
      window.orderFrontRegardless()
      defer { window.orderOut(nil) }
      for _ in 0..<3 {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
      }
      #expect(host.frame.size == CGSize(width: 368, height: 308))
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      try data.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("workflow-\(name).png"))
    }
  }
  @Test func routineDigestReconcilesWithoutCopyingReports() {
    let coordinator = HermInterruptionCoordinator()
    coordinator.start()
    let first = HermNotice(
      kind: .completion, source: .routine, profileID: "research", sourceID: "job", eventID: "run-a")
    let next = HermNotice(
      kind: .completion, source: .routine, profileID: "research", sourceID: "job", eventID: "run-b")
    #expect(!coordinator.admit(first, channel: .notch))
    #expect(!coordinator.admit(first, channel: .system))
    #expect(!coordinator.admit(next, channel: .notch))
    #expect(coordinator.entries.count == 2)
    coordinator.reconcileRoutines(profileID: "research", jobIDs: [])
    #expect(coordinator.entries.allSatisfy { $0.unavailable })
    coordinator.reconcileRoutines(profileID: "research", jobIDs: ["job"])
    #expect(coordinator.entries.allSatisfy { !$0.unavailable })
    #expect(
      coordinator.admit(
        HermNotice(
          kind: .failure, source: .routine, profileID: "research", sourceID: "job", eventID: "run-c"
        ), channel: .notch))
  }
}
