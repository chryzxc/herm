import Foundation

struct WorkflowIntegrationItem: Identifiable, Equatable {
  let id: String
  let detail: String
  var installed = false
  var enabled = false
  var requiredKeys: [String] = []
}
struct WorkflowSkillRemoval {
  let name: String
  let pid: Int
}
struct WorkflowOAuthFlow: Equatable {
  let id: String
  let url: URL
}
struct WorkflowMemoryEntry: Identifiable {
  let id: String
  let label: String
}
struct WorkflowSubagent: Identifiable {
  let id: String
  let goal: String
  let accepting: Bool
}
enum WorkflowSteeringOutcome: String { case queued, rejected }
enum WorkflowOAuthStatus: Equatable { case pending, approved, failed }

/// Only verified named lifecycle operations; transport dictionaries stay outside views.
@MainActor
final class HermesWorkflowRPC {
  private let client: HermesRPCClientProtocol
  let profileID: String?
  init(client: HermesRPCClientProtocol, profileID: String?) {
    self.client = client
    self.profileID = profileID
  }
  private func scoped(_ input: [String: Any]) -> [String: Any] {
    var params = input
    if let profileID { params["profile"] = profileID }
    return params
  }
  private func request(_ method: HermesFeatureIDs.ID, _ params: [String: Any]) async throws
    -> [String: Any]
  {
    try await client.request(method.rawValue, params: scoped(params))
  }
  private func acknowledged(_ result: [String: Any]) throws {
    guard result["ok"] as? Bool == true else { throw HermesGateway.GatewayError.malformedResponse }
  }
  func storedSessionMetadata(limit: Int = 200) async throws -> [HermesSession] {
    let result = try await request(.sessionList, ["limit": max(1, min(limit, 200))])
    if let returned = result["profile"] as? String, returned != (profileID ?? "default") {
      throw HermesGateway.GatewayError.malformedResponse
    }
    guard let rows = result["sessions"] as? [[String: Any]] else {
      throw HermesGateway.GatewayError.malformedResponse
    }
    return try rows.map { row in
      guard let id = row["id"] as? String, !id.isEmpty else { throw HermesGateway.GatewayError.malformedResponse }
      return HermesSession(id: id, profileID: profileID, title: row["title"] as? String ?? "",
        preview: String((row["preview"] as? String ?? "").prefix(180)),
        startedAt: (row["started_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
        messageCount: row["message_count"] as? Int ?? 0, source: row["source"] as? String ?? "herm")
    }
  }
  func skills(query: String? = nil) async throws -> [WorkflowIntegrationItem] {
    if query == nil {
      let profileID = profileID ?? "default"
      let detail = try await BotService(client: client).profileDetail(profileID: profileID)
      guard detail.id == profileID else { throw HermesGateway.GatewayError.malformedResponse }
      return detail.skills.map {
        WorkflowIntegrationItem(id: $0.id, detail: $0.label, installed: true, enabled: $0.enabled)
      }
    }
    let result = try await request(.skillsManage, ["action": "search", "query": query ?? ""])
    guard let rows = result["results"] as? [[String: Any]] else {
      throw HermesGateway.GatewayError.malformedResponse
    }
    return try rows.prefix(20).map {
      guard let name = $0["name"] as? String, !name.isEmpty else {
        throw HermesGateway.GatewayError.malformedResponse
      }
      return WorkflowIntegrationItem(
        id: name, detail: String(($0["description"] as? String ?? "").prefix(300)))
    }
  }

  func inspectSkill(_ id: String) async throws -> String {
    let result = try await request(.skillsManage, ["action": "inspect", "query": id])
    guard let info = result["info"] as? [String: Any] else {
      throw HermesGateway.GatewayError.malformedResponse
    }
    return String(
      (info["skill_md_preview"] as? String ?? info["description"] as? String
        ?? "No preview returned.").prefix(12_000))
  }
  func installSkill(_ id: String) async throws {
    let result = try await request(.skillsManage, ["action": "install", "query": id])
    guard result["installed"] as? Bool == true else {
      throw HermesGateway.GatewayError.malformedResponse
    }
  }
  func toggleSkill(_ id: String, enabled: Bool) async throws {
    let result = try await client.sendHTTP(
      "PUT", path: "/api/skills/toggle", body: scoped(["name": id, "enabled": enabled]))
    try acknowledged(result)
    guard result["name"] as? String == id, result["enabled"] as? Bool == enabled else {
      throw HermesGateway.GatewayError.malformedResponse
    }
  }
  func removeSkill(_ id: String) async throws -> WorkflowSkillRemoval {
    let result = try await client.sendHTTP(
      "POST", path: "/api/skills/hub/uninstall", body: scoped(["name": id]))
    try acknowledged(result)
    guard let pid = result["pid"] as? Int, pid > 0, let name = result["name"] as? String,
      name.hasPrefix("skills-uninstall-"),
      name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
    else { throw HermesGateway.GatewayError.malformedResponse }
    return WorkflowSkillRemoval(name: name, pid: pid)
  }
  func skillRemovalOutcome(_ removal: WorkflowSkillRemoval) async throws -> Int? {
    let result = try await client.fetchHTTP("/api/actions/\(removal.name)/status?lines=1")
    guard result["name"] as? String == removal.name, result["pid"] as? Int == removal.pid,
      let running = result["running"] as? Bool
    else { throw HermesGateway.GatewayError.malformedResponse }
    if running { return nil }
    guard let code = result["exit_code"] as? Int else {
      throw HermesGateway.GatewayError.malformedResponse
    }
    return code
  }
  func addCustomMCP(name: String, url: String) async throws {
    guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
      let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme ?? ""),
      parsed.host != nil,
      parsed.user == nil, parsed.password == nil
    else {
      throw QuickDraftError.message(
        "Enter a server name and an HTTP or HTTPS URL without embedded credentials.")
    }
    let result = try await request(.mcpServersAdd, ["name": name, "config": ["url": url]])
    try acknowledged(result)
    guard result["name"] as? String == name else {
      throw HermesGateway.GatewayError.malformedResponse
    }
  }
  func reloadMCP() async throws {
    let result = try await request(.reloadMCP, ["confirm": true])
    guard result["status"] as? String == "reloaded" else {
      throw QuickDraftError.message(
        "The runtime reload was not acknowledged. Reconnect and inspect the configuration.")
    }
  }
  func mcpCatalog() async throws -> [WorkflowIntegrationItem] {
    let result = try await request(.mcpCatalog, [:])
    guard let rows = result["servers"] as? [[String: Any]] else {
      throw HermesGateway.GatewayError.malformedResponse
    }
    var items = try rows.map {
      guard let name = $0["name"] as? String, let installed = $0["installed"] as? Bool,
        let enabled = $0["enabled"] as? Bool
      else { throw HermesGateway.GatewayError.malformedResponse }
      return WorkflowIntegrationItem(
        id: name, detail: String(($0["description"] as? String ?? "").prefix(300)),
        installed: installed, enabled: enabled, requiredKeys: $0["requires"] as? [String] ?? [])
    }
    if let configured = try? await request(.mcpServersList, [:]),
      let servers = configured["servers"] as? [[String: Any]]
    {
      for row in servers {
        guard let name = row["name"] as? String, !items.contains(where: { $0.id == name }) else {
          continue
        }
        items.append(
          WorkflowIntegrationItem(
            id: name, detail: "Configured \(row["transport"] as? String ?? "MCP") server",
            installed: true, enabled: row["enabled"] as? Bool ?? false,
            requiredKeys: row["env"] as? [String] ?? []))
      }
    }
    return items
  }
  func addMCP(_ name: String) async throws {
    let result = try await request(.mcpServersAdd, ["name": name, "preset": name])
    try acknowledged(result)
    guard result["name"] as? String == name else {
      throw HermesGateway.GatewayError.malformedResponse
    }
  }
  func setMCPCredential(_ name: String, key: String, value: String) async throws {
    try acknowledged(
      try await request(.mcpServersKey, ["name": name, "env_var": key, "value": value]))
  }
  func removeMCP(_ name: String) async throws {
    let result = try await request(.mcpServersRemove, ["name": name])
    try acknowledged(result)
    guard result["removed"] as? Bool == true else {
      throw HermesGateway.GatewayError.malformedResponse
    }
  }
  func testMCP(_ name: String) async throws -> String {
    let result = try await request(.mcpServersTest, ["name": name])
    guard let ok = result["ok"] as? Bool, let oauth = result["oauth_needed"] as? Bool else {
      throw HermesGateway.GatewayError.malformedResponse
    }
    if oauth { return "Authorization required. Choose Authorize." }
    return ok
      ? "Connection confirmed. \((result["tools"] as? [Any])?.count ?? 0) tools available."
      : HermesDiagnosticsService.safeSummary(result["error"] as? String ?? "Connection failed.")
  }
  func startOAuth(_ name: String) async throws -> WorkflowOAuthFlow {
    let result = try await request(.mcpOAuthStart, ["name": name])
    try acknowledged(result)
    guard let id = result["session_id"] as? String, !id.isEmpty,
      let value = result["auth_url"] as? String,
      let url = URL(string: value), ["https", "http"].contains(url.scheme ?? ""), url.host != nil
    else { throw HermesGateway.GatewayError.malformedResponse }
    return WorkflowOAuthFlow(id: id, url: url)
  }
  func pollOAuth(_ name: String, flow: String) async throws -> WorkflowOAuthStatus {
    let result = try await request(.mcpOAuthPoll, ["name": name, "session_id": flow])
    try acknowledged(result)
    switch result["status"] as? String {
    case "pending": return .pending
    case "approved": return .approved
    case "error": return .failed
    default: throw HermesGateway.GatewayError.malformedResponse
    }
  }
  func cancelOAuth(_ name: String, flow: String) async throws {
    try acknowledged(try await request(.mcpOAuthCancel, ["name": name, "session_id": flow]))
  }
  func setRoutinePaused(_ id: String, paused: Bool) async throws {
    let result = try await request(
      .cronManage, ["action": paused ? "pause" : "resume", "name": id])
    guard result["success"] as? Bool == true, let job = result["job"] as? [String: Any],
      job["job_id"] as? String == id, job["enabled"] as? Bool == !paused
    else { throw HermesGateway.GatewayError.malformedResponse }
  }
  func routineJobs() async throws -> [CronSummary] {
    let result = try await request(.cronManage, ["action": "list", "include_disabled": true])
    if let profileID, result["scoped"] as? String != profileID {
      throw HermesGateway.GatewayError.malformedResponse
    }
    guard result["jobs"] is [[String: Any]] else {
      throw HermesGateway.GatewayError.malformedResponse
    }
    return ControlCenterModel.parseCronJobs(result).map { job in
      var job = job
      job.owner = CronOwner(profileID: profileID)
      return job
    }
  }
  func runRoutine(_ id: String) async throws {
    var words = ["hermes"]
    if let profileID { words += ["--profile", profileID] }
    words += ["cron", "run", id]
    let result = try await HermesControlRPC(client: client).runCommand(HermesCLICommand(words))
    guard result["code"] as? Int == 0 else {
      throw HermesCLIError.failed(
        "Hermes did not confirm the new run. Refresh Automation before trying again.")
    }
  }
  func steer(sessionID: String, subagentID: String, text: String) async throws
    -> WorkflowSteeringOutcome
  {
    let result = try await request(
      .subagentSteer, ["session_id": sessionID, "subagent_id": subagentID, "text": text])
    guard result["subagent_id"] as? String == subagentID, let status = result["status"] as? String,
      let outcome = WorkflowSteeringOutcome(rawValue: status)
    else { throw HermesGateway.GatewayError.malformedResponse }
    return outcome
  }
  private func ownedResume(_ session: HermesSession) async throws -> [String: Any] {
    guard session.profileID == profileID else { throw HermesGateway.GatewayError.malformedResponse }
    let result = try await client.request(
      HermesFeatureIDs.ID.sessionResume.rawValue,
      params: scoped(["session_id": session.id, "omit_messages": true, "source": "herm"]))
    let runtime = result["session_id"] as? String ?? session.id
    let info = result["info"] as? [String: Any] ?? [:]
    guard
      DockModel.resumeResponseProvesSessionOwnership(
        requestedSessionID: session.id, resolvedSessionID: runtime, result: result)
    else { throw HermesGateway.GatewayError.malformedResponse }
    let returnedProfile = result["profile"] as? String ?? info["profile_name"] as? String
    if profileID != nil, returnedProfile == nil {
      throw QuickDraftError.message(
        "Hermes did not confirm the session's owner profile. Open its workspace to review compatibility."
      )
    }
    if profileID != nil || returnedProfile != nil, returnedProfile != (profileID ?? "default") {
      throw HermesGateway.GatewayError.malformedResponse
    }
    return result
  }
  func resumeOwned(_ session: HermesSession) async throws -> (String, Bool) {
    let result = try await ownedResume(session)
    let info = result["info"] as? [String: Any] ?? [:]
    guard let running = result["running"] as? Bool ?? info["running"] as? Bool else {
      throw HermesGateway.GatewayError.malformedResponse
    }
    return (result["session_id"] as? String ?? session.id, running)
  }
  func modelOptions(_ runtime: String) async throws -> [String: Any] {
    try await client.request(
      HermesFeatureIDs.ID.modelOptions.rawValue,
      params: scoped(["session_id": runtime, "explicit_only": true]))
  }
  func setSessionModel(_ session: HermesSession, option: HermesModelOption) async throws {
    let (runtime, running) = try await resumeOwned(session)
    guard !running else {
      throw QuickDraftError.message("The destination is busy. Change its model when idle.")
    }
    let available = try DockModel.runtimeModelOptions(from: await modelOptions(runtime))
    guard available.contains(option) else {
      throw QuickDraftError.message("That model is no longer configured.")
    }
    let params = DockModel.sessionRuntimeModelSwitchRequest(option: option, sessionID: runtime)
      .parameters
    let result = try await client.request(
      HermesFeatureIDs.ID.configSet.rawValue, params: scoped(params))
    guard result["key"] as? String == "model", result["scope"] as? String == "session",
      let value = result["value"] as? String, !value.isEmpty,
      result["confirm_required"] as? Bool != true, result["deferred"] as? Bool != true
    else {
      throw QuickDraftError.message(
        "The model change was not confirmed. Refresh the session before retrying.")
    }
  }
  func stopSession(_ session: HermesSession) async throws {
    let (runtime, _) = try await resumeOwned(session)
    let result = try await client.request(
      HermesFeatureIDs.ID.sessionInterrupt.rawValue, params: scoped(["session_id": runtime]))
    guard result["status"] as? String == "interrupted", result["interrupted"] as? Bool != false
    else {
      throw QuickDraftError.message("Hermes did not confirm stopping this turn. Refresh its state.")
    }
  }
  func sessionDirectory(_ session: HermesSession) async throws -> String {
    let result = try await ownedResume(session)
    let info = result["info"] as? [String: Any] ?? [:]
    let runtime = result["session_id"] as? String ?? session.id
    guard
      DockModel.resumeResponseProvesSessionOwnership(
        requestedSessionID: session.id, resolvedSessionID: runtime, result: result),
      let path = result["cwd"] as? String ?? info["cwd"] as? String, path.hasPrefix("/")
    else { throw HermesGateway.GatewayError.malformedResponse }
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }
  func createSession(directory: String, idempotencyKey: String) async throws -> [String: Any] {
    try await client.request(
      HermesFeatureIDs.ID.sessionCreate.rawValue,
      params: scoped([
        "cwd": directory, "cwd_explicit": true, "source": "herm", "idempotency_key": idempotencyKey,
      ]))
  }
  private func query(_ values: [String: String]) -> String {
    var components = URLComponents()
    var values = values
    if let profileID { values["profile"] = profileID }
    components.queryItems = values.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    return components.percentEncodedQuery.map { "?" + $0 } ?? ""
  }
  func memoryEntries() async throws -> [WorkflowMemoryEntry] {
    let result = try await client.fetchHTTP("/api/learning/graph" + query([:]))
    guard let nodes = result["nodes"] as? [[String: Any]] else {
      throw HermesGateway.GatewayError.malformedResponse
    }
    return Array(
      nodes.compactMap { node -> WorkflowMemoryEntry? in
        guard node["kind"] as? String == "memory", let id = node["id"] as? String, validMemoryID(id)
        else { return nil }
        return WorkflowMemoryEntry(
          id: id, label: String((node["label"] as? String ?? id).prefix(120)))
      }.prefix(100))
  }
  private func validMemoryID(_ id: String) -> Bool {
    let parts = id.split(separator: ":")
    return parts.count == 4 && parts[0] == "memory"
      && ["memory", "profile"].contains(String(parts[1]))
      && Int(parts[2]) != nil && parts[3].count >= 8 && parts[3].allSatisfy(\.isHexDigit)
  }
  func memoryDetail(_ id: String) async throws -> String {
    guard validMemoryID(id) else {
      throw QuickDraftError.message("This runtime did not provide a stable memory-entry identity.")
    }
    let result: [String: Any]
    if profileID == nil {
      result = try await request(.learningDetail, ["id": id])
    } else {
      result = try await client.fetchHTTP("/api/learning/node" + query(["id": id]))
    }
    try acknowledged(result)
    guard result["id"] as? String == id, result["kind"] as? String == "memory",
      let content = result["content"] as? String,
      content.utf8.count <= 64_000
    else { throw HermesGateway.GatewayError.malformedResponse }
    return content
  }
  func correctMemory(_ id: String, content: String?) async throws {
    guard validMemoryID(id) else {
      throw QuickDraftError.message("Refresh memory entries before editing.")
    }
    var params: [String: Any] = ["id": id]
    if let content { params["content"] = content }
    let result: [String: Any]
    if profileID == nil {
      result = try await request(content == nil ? .learningDelete : .learningEdit, params)
    } else {
      result = try await client.sendHTTP(
        content == nil ? "DELETE" : "PUT", path: "/api/learning/node" + query([:]),
        body: scoped(params))
    }
    try acknowledged(result)
  }
  func liveSubagents(_ session: HermesSession) async throws -> (String, [WorkflowSubagent]) {
    let (runtime, _) = try await resumeOwned(session)
    let result = try await request(.subagentList, ["session_id": runtime])
    guard let rows = result["subagents"] as? [[String: Any]] else {
      throw HermesGateway.GatewayError.malformedResponse
    }
    return (
      runtime,
      rows.compactMap {
        guard let id = $0["subagent_id"] as? String, !id.isEmpty,
          ["running", "active"].contains($0["status"] as? String ?? "")
        else { return nil }
        return WorkflowSubagent(
          id: id, goal: String(($0["goal"] as? String ?? id).prefix(300)),
          accepting: $0["accepting_steer"] as? Bool == true)
      }
    )
  }
}
