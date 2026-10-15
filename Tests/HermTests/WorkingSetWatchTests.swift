import Foundation
import Testing

@testable import Herm

@MainActor
struct WorkingSetWatchTests {
  @Test func structuredCompletionFailureIsNotAnUnreadResult() {
    let watch = WorkingSetWatchProjection()
    let origin = QuickDestination(profileID: "coding", sessionID: "one")
    watch.select(WorkingSet(name: "Owner", destinations: [origin]))
    watch.ingest(
      "message.complete", params: ["payload": ["error": ["message": "Turn failed"]]], origin: origin
    )
    let key = ProfileScopedID(profileID: "coding", resourceID: "one")
    #expect(watch.records[key]?.working == false)
    #expect(watch.records[key]?.completed == false)
    #expect(!watch.rows.contains { $0.phase == .finished })
  }
  private func settle(_ watch: WorkingSetWatchProjection) async throws {
    for _ in 0..<100 {
      if !watch.refreshing { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Watch read did not settle")
  }
  private func session(_ profile: String?, _ id: String) -> HermesSession {
    HermesSession(
      id: id, profileID: profile, title: id, preview: "Saved reply", startedAt: nil,
      messageCount: 2, source: "herm")
  }
  @Test func identicalSessionIDsStayScopedAndUnknownStateStaysStale() async throws {
    let watch = WorkingSetWatchProjection()
    watch.read = { profile in [session(profile, "same")] }
    watch.select(
      WorkingSet(
        name: "Two owners",
        destinations: [
          QuickDestination(profileID: "coding", sessionID: "same"),
          QuickDestination(profileID: "research", sessionID: "same"),
        ]))
    try await settle(watch)
    #expect(watch.records.count == 2)
    #expect(watch.records.values.allSatisfy { $0.stale && $0.working == nil })
    watch.ingest(
      "message.start", params: ["session_id": "same", "seq": 1],
      origin: QuickDestination(profileID: "coding", sessionID: "same"))
    #expect(
      watch.records[ProfileScopedID(profileID: "coding", resourceID: "same")]?.working == true)
    #expect(
      watch.records[ProfileScopedID(profileID: "research", resourceID: "same")]?.working == nil)
    watch.connectionChanged(false)
    #expect(watch.records.values.allSatisfy { $0.stale && $0.working == nil })
  }
  @Test func wrongProfileReadCannotReplaceCapturedReferences() async throws {
    let watch = WorkingSetWatchProjection()
    watch.read = { _ in [session("other", "same")] }
    watch.select(
      WorkingSet(
        name: "Owner", destinations: [QuickDestination(profileID: "coding", sessionID: "same")]))
    try await settle(watch)
    #expect(watch.records.values.allSatisfy { $0.session == nil && $0.stale })
    #expect(watch.rows.first?.session?.profileID == "coding")
  }
  @Test func profileReadsAreBoundedAndDoNotPollAfterSettling() async throws {
    let watch = WorkingSetWatchProjection()
    var active = 0
    var maximum = 0
    var reads = 0
    watch.read = { profile in
      active += 1
      reads += 1
      maximum = max(maximum, active)
      defer { active -= 1 }
      try await Task.sleep(for: .milliseconds(20))
      return [session(profile, "one")]
    }
    watch.select(
      WorkingSet(
        name: "Three",
        destinations: ["a", "b", "c"].map { QuickDestination(profileID: $0, sessionID: "one") }))
    try await settle(watch)
    #expect(maximum <= 2)
    #expect(reads == 3)
    try await Task.sleep(for: .milliseconds(50))
    #expect(reads == 3)
    watch.select(nil)
    #expect(watch.rows.isEmpty)
  }
  @Test func lateCancelledReadsCannotRepopulateAnotherSet() async throws {
    let watch = WorkingSetWatchProjection()
    watch.read = { profile in
      try? await Task.sleep(for: .milliseconds(30))
      return [session(profile, "old")]
    }
    watch.select(
      WorkingSet(name: "Old", destinations: [QuickDestination(profileID: "a", sessionID: "old")]))
    await Task.yield()
    watch.select(nil)
    try await Task.sleep(for: .milliseconds(60))
    #expect(watch.records.isEmpty)
    #expect(!watch.refreshing)
  }
  @Test func watchPreferenceSurvivesRestartAndRemovalEndsIt() throws {
    let name = "WorkingSetWatchTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = CommandCenterPreferencesStore(defaults: defaults)
    preferences.saveWorkingSet(
      name: "Work", destination: QuickDestination(profileID: "a", sessionID: "one"))
    let id = try #require(preferences.workingSets.first?.id)
    preferences.watchWorkingSet(id)
    #expect(CommandCenterPreferencesStore(defaults: defaults).watchedWorkingSetID == id)
    preferences.removeWorkingSet(id)
    #expect(preferences.watchedWorkingSetID == nil)
  }
}
