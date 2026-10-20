import SwiftUI

private struct RichReplyStateKey: EnvironmentKey {
  static let defaultValue: RichReplyState? = nil
}
private struct RichReplyContextKey: EnvironmentKey {
  static let defaultValue: RichReplyContext? = nil
}
extension EnvironmentValues {
  var richReplyState: RichReplyState? {
    get { self[RichReplyStateKey.self] }
    set { self[RichReplyStateKey.self] = newValue }
  }
  var richReplyContext: RichReplyContext? {
    get { self[RichReplyContextKey.self] }
    set { self[RichReplyContextKey.self] = newValue }
  }
}

@MainActor
final class RichReplyState: ObservableObject {
  private var forms: [String: RichFormDraft] = [:]
  private var sourceAliases: [String: String] = [:]

  func sourceKey(session: String, message: ChatMessage, reference: StoredMessageReference?)
    -> String
  {
    let transient = "\(session):message:\(message.id)"
    let stored = reference.map { "\(session):row:\($0.rowID)" }
    let key =
      sourceAliases[transient] ?? stored.flatMap { sourceAliases[$0] } ?? stored ?? transient
    sourceAliases[transient] = key
    if let stored { sourceAliases[stored] = key }
    return key
  }

  func form(key: String) -> RichFormDraft {
    if let draft = forms[key] { return draft }
    let draft = RichFormDraft()
    forms[key] = draft
    return draft
  }
}

@MainActor
final class RichFormDraft: ObservableObject {
  @Published var values: [String: [String]] = [:]
  @Published var pending = false
  @Published var error: String?
  @Published var sent = false
  var submission: QuickDraftRecord?

  func answer(fields: [RichField]) throws -> String {
    try fields.map { field in
      let selected = values[field.id] ?? (field.type == .boolean ? ["No"] : [])
      let value = selected.joined(separator: ", ").trimmingCharacters(in: .whitespacesAndNewlines)
      if field.required == true && value.isEmpty {
        throw QuickDraftError.message("Enter \(field.label).")
      }
      if field.type == .number, !value.isEmpty, Double(value)?.isFinite != true {
        throw QuickDraftError.message("Enter a number for \(field.label).")
      }
      if let options = field.options, selected.contains(where: { !options.contains($0) }) {
        throw QuickDraftError.message("Choose an available option for \(field.label).")
      }
      return "\(field.label): \(value.isEmpty ? "Not specified" : value)"
    }.joined(separator: "\n")
  }
}

@MainActor
final class RichReplyContext {
  weak var model: DockModel?
  let destination: QuickDestination
  let messageID: UUID
  let revision: Int
  let sourceKey: String

  convenience init(model: DockModel, message: ChatMessage, state: RichReplyState) {
    self.init(
      model: model, message: message, destination: Self.destination(for: model),
      reference: model.storedMessageReferences[message.id], state: state)
  }

  init(
    model: DockModel, message: ChatMessage, destination: QuickDestination,
    reference: StoredMessageReference?, state: RichReplyState
  ) {
    self.model = model
    self.destination = destination
    messageID = message.id
    revision = message.contentRevision
    sourceKey = state.sourceKey(session: destination.sessionKey, message: message, reference: reference)
  }

  @MainActor static func destination(for model: DockModel) -> QuickDestination {
    QuickDestination(
      profileID: model.sessionProfileID ?? model.profileScopeID,
      sessionID: model.navigationSessionID, title: model.currentSessionTitle ?? "Session")
  }

  var isCurrent: Bool {
    guard let model, destination.sessionID != nil,
      model.navigationSessionID == destination.sessionID,
      (model.sessionProfileID ?? model.profileScopeID) == destination.profileID
    else { return false }
    return model.messages.contains { $0.id == messageID && $0.contentRevision == revision }
  }

  func submit(
    _ draft: RichFormDraft, surface: RichSurface, fields: [RichField],
    store: QuickDraftStore = .shared
  ) async {
    guard !draft.pending, !draft.sent, isCurrent, let model else { return }
    if draft.submission?.delivery == .needsReview {
      draft.error =
        "Submission is uncertain. Review the destination conversation before sending again."
      return
    }
    draft.pending = true
    draft.error = nil
    defer { draft.pending = false }
    do {
      let answer = try draft.answer(fields: fields)
      var record = draft.submission ?? QuickDraftRecord(destination: destination, text: "")
      record.requestsVisualReply = false
      record.text = "Answer to \(surface.title) (surface \(surface.id)):\n\(answer)"
      record.delivery = .submitting
      draft.submission = record
      store.save(record)
      store.flush()
      if let error = store.error { throw QuickDraftError.message(error) }
      let submitted = try await model.submitQuickDraft(record) {
        draft.submission = $0
        store.save($0)
        store.flush()
        if let error = store.error { throw QuickDraftError.message(error) }
      }
      draft.submission = submitted
      draft.sent = true
      store.remove(submitted)
      store.flush()
    } catch {
      draft.error = RichContentRedaction.text(error.localizedDescription, limit: 512)
      if var record = draft.submission {
        record.delivery =
          (error as? QuickSubmissionFailure)?.uncertain == true ? .needsReview : .editing
        draft.submission = record
        store.save(record)
        store.flush()
      }
    }
  }
}
