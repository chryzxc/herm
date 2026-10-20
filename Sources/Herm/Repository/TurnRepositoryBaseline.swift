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
  var concurrent = false
  var completionRowID: Int?
  var eligible: Bool { acknowledged && started && completed }
}

extension DeveloperWorkflowModel {
  func acknowledgeTurnBaseline(origin: QuickDestination, attemptID: UUID) {
    guard var baseline = turnBaselines[origin.sessionKey], baseline.attemptID == attemptID else {
      return
    }
    baseline.acknowledged = true
    turnBaselines[origin.sessionKey] = baseline
    if baseline.eligible { ObservedRequestChanges.shared.capture(baseline, concurrent: baseline.concurrent) }
  }
  func observeTurnBaseline(
    origin: QuickDestination, started: Bool = false, completed: Bool = false, failed: Bool = false, completionRowID: Int? = nil
  ) {
    guard var baseline = turnBaselines[origin.sessionKey] else { return }
    if failed || (started && baseline.completed) || (completed && !baseline.started) {
      turnBaselines.removeValue(forKey: origin.sessionKey)
      ObservedRequestChanges.shared.invalidate(origin)
      return
    }
    if started {
      baseline.started = true
      for (key, var other) in turnBaselines where key != origin.sessionKey && other.path == baseline.path && other.started && !other.completed {
        other.concurrent = true; turnBaselines[key] = other; baseline.concurrent = true
      }
    }
    if completed { baseline.completed = true; baseline.completionRowID = completionRowID }
    turnBaselines[origin.sessionKey] = baseline
    if completed {
      let overlapping = turnBaselines.values.contains { $0.origin.sessionKey != origin.sessionKey && $0.path == baseline.path && $0.started && !$0.completed }
      ObservedRequestChanges.shared.capture(baseline, concurrent: overlapping || baseline.concurrent)
    }
  }
  func captureTurnBaseline(origin: QuickDestination, path: String, attemptID: UUID = UUID()) async {
    ObservedRequestChanges.shared.invalidate(origin)
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
