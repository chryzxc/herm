import Foundation

struct TurnRepositoryBaseline: Equatable {
  let origin: QuickDestination
  let path: String
  let head: String?
  let clean: Bool
  let capturedAt: Date
  var attemptID = UUID()
  var acknowledged = false
  var started = false
  var completed = false
  var eligible: Bool { acknowledged && started && completed }
}

extension DeveloperWorkflowModel {
  func acknowledgeTurnBaseline(origin: QuickDestination, attemptID: UUID) {
    guard var baseline = turnBaselines[origin.sessionKey], baseline.attemptID == attemptID else {
      return
    }
    baseline.acknowledged = true
    turnBaselines[origin.sessionKey] = baseline
  }
  func observeTurnBaseline(
    origin: QuickDestination, started: Bool = false, completed: Bool = false, failed: Bool = false
  ) {
    guard var baseline = turnBaselines[origin.sessionKey] else { return }
    if failed || (started && baseline.completed) || (completed && !baseline.started) {
      turnBaselines.removeValue(forKey: origin.sessionKey)
      return
    }
    if started { baseline.started = true }
    if completed { baseline.completed = true }
    turnBaselines[origin.sessionKey] = baseline
  }
  func captureTurnBaseline(origin: QuickDestination, path: String, attemptID: UUID = UUID()) async {
    let snapshot = await RepositoryService.inspect(path: path)
    guard snapshot.isGitRepository else { return }
    turnBaselines[origin.sessionKey] = TurnRepositoryBaseline(
      origin: origin, path: snapshot.path,
      head: snapshot.headRevision, clean: snapshot.changedFiles == 0, capturedAt: .now,
      attemptID: attemptID)
    if turnBaselines.count > 50,
      let oldest = turnBaselines.min(by: { $0.value.capturedAt < $1.value.capturedAt })?.key
    {
      turnBaselines.removeValue(forKey: oldest)
    }
  }
}

struct IsolatedTaskSetup {
  let draft: QuickDraftRecord
  let error: String?
}

@MainActor
extension HermesWorkflowRPC {
  func createIsolatedSession(path: String, text: String, id: UUID) async -> IsolatedTaskSetup {
    var record = QuickDraftRecord(
      id: id,
      destination: QuickDestination(
        profileID: profileID, title: "New worktree task", projectPath: path), text: text)
    do {
      let result = try await createSession(directory: path, idempotencyKey: id.uuidString)
      guard let runtime = result["session_id"] as? String, !runtime.isEmpty else {
        throw HermesGateway.GatewayError.malformedResponse
      }
      record.destination.runtimeID = runtime
      record.destination.sessionID = result["stored_session_id"] as? String ?? runtime
      guard let session = record.destination.session else {
        throw HermesGateway.GatewayError.malformedResponse
      }
      let resumed = try await resumeOwned(session)
      guard resumed.0 == runtime, try await sessionDirectory(session) == path else {
        throw HermesGateway.GatewayError.malformedResponse
      }
      return IsolatedTaskSetup(draft: record, error: nil)
    } catch {
      record.delivery = .needsReview
      return IsolatedTaskSetup(
        draft: record,
        error:
          "The worktree is preserved at \(path). Session setup could not be confirmed. Review it in Herm before sending."
      )
    }
  }
}
