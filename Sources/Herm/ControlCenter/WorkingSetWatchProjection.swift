import Combine
import Foundation

/// A bounded projection of explicitly referenced sessions, driven by reads and existing events.
@MainActor
final class WorkingSetWatchProjection: ObservableObject {
  struct Profile: Hashable { let id: String? }
  struct Record: Equatable {
    let destination: QuickDestination
    var session: HermesSession?
    var working: Bool?
    var completed = false
    var stale = true
    var readAt: Date?
    var eventID: String?
    var activityAt: Date?
    var unavailable = false
  }
  @Published private(set) var records: [ProfileScopedID: Record] = [:]
  @Published private(set) var refreshing = false
  private(set) var selectedSet: WorkingSet?
  var read: ((String?) async throws -> [HermesSession])?
  private var generation = UUID()
  private var pending = Set<Profile>()
  private var inFlight: [Profile: Task<Void, Never>] = [:]
  private var connected = true

  func select(_ set: WorkingSet?) {
    guard selectedSet != set else { return }
    invalidate()
    selectedSet = set
    var next: [ProfileScopedID: Record] = [:]
    for destination in set?.destinations ?? [] {
      guard let id = destination.sessionID else { continue }
      let key = ProfileScopedID(profileID: destination.profileID, resourceID: id)
      if next[key] == nil { next[key] = Record(destination: destination) }
    }
    records = next
    refresh()
  }

  func invalidate() {
    generation = UUID()
    inFlight.values.forEach { $0.cancel() }
    inFlight = [:]
    pending = []
    refreshing = false
    records = records.mapValues { value in
      var value = value
      value.stale = true
      value.working = nil
      value.eventID = nil
      return value
    }
  }

  func connectionChanged(_ value: Bool) {
    guard connected != value else { return }
    connected = value
    if value { refresh() } else { invalidate() }
  }

  func refresh(profiles: Set<Profile>? = nil) {
    guard connected, selectedSet != nil, read != nil else { return }
    pending.formUnion(profiles ?? Set(records.keys.map { Profile(id: $0.profileID) }))
    startPending()
  }

  private func startPending() {
    guard let read else { return }
    while inFlight.count < 2, let profile = pending.first(where: { inFlight[$0] == nil }) {
      pending.remove(profile)
      let capturedGeneration = generation
      refreshing = true
      inFlight[profile] = Task { [weak self] in
        do {
          let sessions = try await read(profile.id)
          guard let self, !Task.isCancelled, self.generation == capturedGeneration else { return }
          guard sessions.allSatisfy({ $0.profileID == profile.id }) else {
            throw HermesGateway.GatewayError.malformedResponse
          }
          var next = self.records
          for key in next.keys where key.profileID == profile.id {
            guard var record = next[key] else { continue }
            record.session = sessions.first { $0.id == key.resourceID }
            record.unavailable = record.session == nil
            record.readAt = .now
            record.stale = !self.connected || record.working == nil
            next[key] = record
          }
          self.records = next
        } catch {
          guard let self, !Task.isCancelled, self.generation == capturedGeneration else { return }
          self.records = self.records.mapValues { record in
            var record = record
            if record.destination.profileID == profile.id { record.stale = true }
            return record
          }
        }
        guard let self, self.generation == capturedGeneration else { return }
        self.inFlight[profile] = nil
        self.refreshing = !self.inFlight.isEmpty
        self.startPending()
      }
    }
  }

  func ingest(_ type: String, params: [String: Any], origin: QuickDestination?) {
    guard selectedSet != nil else { return }
    if type == "sessions.changed" {
      refresh()
      return
    }
    guard ["message.start", "message.complete", "message.error", "error"].contains(type) else {
      return
    }
    let payload = params["payload"] as? [String: Any] ?? [:]
    guard let origin, let id = origin.sessionID else {
      let raw = params["session_id"] as? String ?? payload["session_id"] as? String
      let affected = Set(
        records.keys.filter { $0.resourceID == raw }.map { Profile(id: $0.profileID) })
      if affected.isEmpty {
        records = records.mapValues { value in
          var value = value
          value.stale = true
          return value
        }
      }
      if !affected.isEmpty {
        records = records.mapValues { value in
          var value = value
          if value.destination.sessionID == raw { value.stale = true }
          return value
        }
        refresh(profiles: affected)
      }
      return
    }
    let key = ProfileScopedID(profileID: origin.profileID, resourceID: id)
    guard var record = records[key] else { return }
    let event = (params["seq"] as? NSNumber)?.stringValue
    if let event, record.eventID == event { return }
    record.eventID = event
    record.activityAt = .now
    if type == "message.start" {
      record.working = true
      record.completed = false
    } else {
      record.working = false
      record.completed =
        type == "message.complete" && DockModel.messageCompletionError(from: payload) == nil
    }
    record.stale = !connected
    records[key] = record
    if type != "message.start" { refresh(profiles: [Profile(id: origin.profileID)]) }
  }

  func review(_ session: HermesSession) {
    let key = session.scopedID
    guard var record = records[key] else { return }
    record.completed = false
    records[key] = record
  }

  var rows: [EdgeNotchTask] {
    records.values.map { record in
      let session = record.session ?? record.destination.session
      let phase: EdgeNotchTask.Phase =
        record.working == true ? .working : record.completed ? .finished : .pending
      let label =
        record.unavailable
        ? "Not in recent inventory"
        : record.stale
          ? "Status not current"
          : record.working == true
            ? "Working"
            : record.completed ? "Finished" : "Latest saved activity"
      return EdgeNotchTask(
        id: record.destination.sessionID ?? "",
        title: session?.displayTitle ?? record.destination.title,
        phase: phase, statusLabel: label,
        detail: record.unavailable
          ? "Refresh or open this saved session to check its reference"
          : record.session?.displayPreview,
        updatedAt: record.activityAt ?? record.session?.startedAt, isCurrent: false,
        isStatusCurrent: !record.stale,
        session: session)
    }
  }
}
