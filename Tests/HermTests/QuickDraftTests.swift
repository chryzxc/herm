import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
private final class CaptureRPC: HermesRPCClientProtocol {
  var onEvent: ((String, [String: Any]) -> Void)?
  var calls: [(String, [String: Any])] = []
  var busy = false
  var exclusive = true
  var failMethod: String?
  var failure: Error = NSError(
    domain: "Hermes", code: 1, userInfo: [NSLocalizedDescriptionKey: "Rejected"])
  var submitStatus = "streaming"
  var returnedOwner: String?
  var returnedProfile: String?
  func connect() async throws {}
  func close() {}
  func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
    calls.append((method, params))
    if method == failMethod { throw failure }
    switch method {
    case "gateway.capabilities": return ["per_session_exclusive_submit": exclusive]
    case "session.create": return ["session_id": "runtime", "stored_session_id": "created"]
    case "session.resume":
      return [
        "session_id": "runtime",
        "stored_session_id": returnedOwner ?? params["session_id"] as? String ?? "created",
        "running": busy, "message_count": 0,
        "info": [
          "profile_name": returnedProfile ?? params["profile"] as? String ?? "default",
          "cwd": "/tmp/project",
        ],
      ]
    case "image.attach_bytes":
      return ["attached": true, "path": "/queued/\(params["filename"] ?? "image")"]
    case "pdf.attach": return ["attached": true, "pages": [["path": "/queued/pdf-page.png"]]]
    case "file.attach": return ["attached": true, "ref_text": "@file:docs/sample.txt"]
    case "image.detach": return ["detached": true]
    case "prompt.submit": return ["status": submitStatus]
    default: return [:]
    }
  }
}

@MainActor
struct QuickDraftTests {
  @Test func deliveredAnswersUseTheirCapturedOwnerAndRequireImmediateAcknowledgment() async throws {
    let question = EdgeDeliveryQuestion(
      taskID: "task", sessionID: "owner", profileID: "research",
      question: "Continue?", choices: ["Yes"], file: URL(fileURLWithPath: "/tmp/question.json"))
    for status in ["streaming", "queued", "rejected", ""] {
      let rpc = CaptureRPC()
      rpc.submitStatus = status
      let draft = try question.answerDraft("Yes")
      #expect(draft.destination.profileID == "research")
      #expect(draft.destination.sessionID == "owner")
      do {
        _ = try await QuickDraftSubmission.send(draft, client: rpc, progress: { _ in })
        #expect(status == "streaming")
      } catch let failure as QuickSubmissionFailure {
        #expect(status != "streaming")
        #expect(failure.uncertain)
      }
      let prompts = rpc.calls.filter { $0.0 == "prompt.submit" }
      #expect(prompts.count == 1)
      #expect(prompts.first?.1["profile"] as? String == "research")
      #expect(prompts.first?.1["text"] as? String == "ANSWER task: Yes")
    }
    var launchQuestion = question
    launchQuestion.profileID = nil
    let rpc = CaptureRPC()
    _ = try await QuickDraftSubmission.send(
      launchQuestion.answerDraft("Yes"), client: rpc, progress: { _ in })
    #expect(rpc.calls.allSatisfy { $0.1["profile"] == nil })
  }

  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private func file(_ root: URL, name: String) async throws -> QuickDraftFile {
    let url = root.appendingPathComponent(name)
    try Data("captured material".utf8).write(to: url)
    return try await QuickDraftFile.capture(url)
  }
  private func record(files: [QuickDraftFile] = []) -> QuickDraftRecord {
    var draft = QuickDraftRecord(
      destination: QuickDestination(profileID: "research", sessionID: "owner", title: "Research"))
    draft.text = "Review this"
    draft.files = files
    return draft
  }

  @Test func restartRetainsDestinationAndMarksInterruptedWorkForReview() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = QuickDraftStore(directory: root)
    var draft = record()
    draft.delivery = .submitting
    store.save(draft)
    store.flush()
    let recovered = QuickDraftStore(directory: root)
    #expect(recovered.records.first?.destination == draft.destination)
    #expect(recovered.records.first?.text == "Review this")
    #expect(recovered.records.first?.delivery == .needsReview)
    let mode =
      try FileManager.default.attributesOfItem(
        atPath: root.appendingPathComponent("drafts-v1.json").path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
  }

  @Test func deliveryStateDoesNotTurnAnEmptyDraftIntoAMessage() async throws {
    let rpc = CaptureRPC()
    var draft = record()
    draft.text = "   "
    draft.delivery = .submitting
    do {
      _ = try await QuickDraftSubmission.send(draft, client: rpc, progress: { _ in })
      Issue.record("Empty draft was submitted")
    } catch {}
    #expect(rpc.calls.isEmpty)
  }

  @Test func cleanupChecksProfileAndOnlyDetachesAcknowledgedPaths() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let rpc = CaptureRPC()
    var draft = record(files: [try await file(root, name: "capture.png")])
    draft.destination.runtimeID = "runtime"
    draft.uploadMessageCount = 0
    draft.uploadDirectory = "/tmp/project"
    draft.files[0].uploaded = true
    draft.files[0].uploadedPaths = ["/queued/capture.png"]
    rpc.returnedProfile = "coding"
    do {
      try await QuickDraftSubmission.detach(draft, client: rpc)
      Issue.record("Wrong-profile cleanup succeeded")
    } catch {}
    #expect(!rpc.calls.contains { $0.0 == "image.detach" })
    rpc.returnedProfile = nil
    try await QuickDraftSubmission.detach(draft, client: rpc)
    let call = try #require(rpc.calls.first { $0.0 == "image.detach" })
    #expect(call.1["profile"] as? String == "research")
    #expect(call.1["session_id"] as? String == "runtime")
    #expect(call.1["path"] as? String == "/queued/capture.png")
  }

  @Test func corruptRecoveryFileIsNotOverwritten() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("drafts-v1.json")
    let original = Data("not a recovery file".utf8)
    try original.write(to: path)
    let store = QuickDraftStore(directory: root)
    #expect(store.error != nil)
    store.save(record())
    store.flush()
    #expect(try Data(contentsOf: path) == original)
  }

  @Test func emptyCaptureIdentityIsStableAndDraftsStayWithTheirOwners() {
    let state = EdgeNotchState()
    state.switchQuickProfile("research")
    let first = state.captureRecord().id
    #expect(state.captureRecord().id == first)
    state.quickDraft = "Unsent research"
    state.switchQuickProfile("builder")
    state.quickDraft = "Unsent code"
    state.switchQuickProfile("research")
    state.selectQuickTarget(nil)
    #expect(state.quickDraft == "Unsent research")
    #expect(state.captureRecord().destination.profileID == "research")
    #expect(state.draftStore.records.count == 2)
  }

  @Test func mixedFilesUseNamedContractsAndCapturedOwner() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try await [
      file(root, name: "sample.png"), file(root, name: "sample.pdf"),
      file(root, name: "sample.txt"),
    ]
    let rpc = CaptureRPC()
    let submitted = try await QuickDraftSubmission.send(
      record(files: files), client: rpc, progress: { _ in })
    #expect(submitted.files.allSatisfy { $0.uploaded })
    let uploads = rpc.calls.filter {
      ["image.attach_bytes", "pdf.attach", "file.attach", "prompt.submit"].contains($0.0)
    }
    #expect(
      uploads.map(\.0) == ["image.attach_bytes", "pdf.attach", "file.attach", "prompt.submit"])
    #expect(
      uploads.allSatisfy {
        $0.1["session_id"] as? String == "runtime" && $0.1["profile"] as? String == "research"
      })
    #expect(rpc.calls.last?.1["text"] as? String == "Review this\n\n@file:docs/sample.txt")
  }

  @Test func partialUploadRetriesOnlyUnacknowledgedFiles() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    var latest = try await record(files: [
      file(root, name: "image.png"), file(root, name: "sample.txt"),
    ])
    let rpc = CaptureRPC()
    rpc.failMethod = "file.attach"
    do {
      _ = try await QuickDraftSubmission.send(latest, client: rpc, progress: { latest = $0 })
    } catch { #expect((error as? QuickSubmissionFailure)?.uncertain == false) }
    #expect(latest.files[0].uploaded)
    #expect(!latest.files[1].uploaded)
    rpc.failMethod = nil
    _ = try await QuickDraftSubmission.send(latest, client: rpc, progress: { latest = $0 })
    #expect(rpc.calls.filter { $0.0 == "image.attach_bytes" }.count == 1)
    #expect(rpc.calls.filter { $0.0 == "file.attach" }.count == 2)
  }

  @Test func lostAcknowledgmentAndQueuedResultRequireReview() async throws {
    for queued in [false, true] {
      let rpc = CaptureRPC()
      if queued {
        rpc.submitStatus = "queued"
      } else {
        rpc.failMethod = "prompt.submit"
        rpc.failure = HermesGateway.GatewayError.disconnected
      }
      do {
        _ = try await QuickDraftSubmission.send(record(), client: rpc, progress: { _ in })
        Issue.record("An ambiguous submission must not succeed")
      } catch { #expect((error as? QuickSubmissionFailure)?.uncertain == true) }
    }
  }

  @Test func busyAndWrongOwnersNeverReceiveUploads() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let draft = try await record(files: [file(root, name: "image.png")])
    for wrong in [false, true] {
      let rpc = CaptureRPC()
      rpc.busy = !wrong
      if wrong { rpc.returnedOwner = "different" }
      do {
        _ = try await QuickDraftSubmission.send(draft, client: rpc, progress: { _ in })
        Issue.record("Invalid destination was accepted")
      } catch { #expect((error as? QuickSubmissionFailure)?.uncertain == false) }
      #expect(!rpc.calls.contains { $0.0 == "image.attach_bytes" || $0.0 == "prompt.submit" })
    }
  }

  @Test func failedCreationRetainsReturnedIdentityForRetry() async throws {
    var draft = record()
    draft.destination.sessionID = nil
    let rpc = CaptureRPC()
    rpc.failMethod = "prompt.submit"
    do {
      _ = try await QuickDraftSubmission.send(draft, client: rpc, progress: { draft = $0 })
    } catch {}
    #expect(draft.destination.sessionID == "created")
    rpc.failMethod = nil
    _ = try await QuickDraftSubmission.send(draft, client: rpc, progress: { draft = $0 })
    #expect(rpc.calls.filter { $0.0 == "session.create" }.count == 1)
    #expect(
      rpc.calls.first { $0.0 == "session.create" }?.1["idempotency_key"] as? String
        == draft.id.uuidString)
  }

  @Test func changedMissingFolderAndOversizedPDFAreRejected() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let captured = try await file(root, name: "sample.txt")
    try Data("changed".utf8).write(to: captured.fallbackURL)
    do {
      _ = try await captured.encoded()
      Issue.record("Changed file was accepted")
    } catch {}
    try FileManager.default.removeItem(at: captured.fallbackURL)
    do {
      _ = try await captured.encoded()
      Issue.record("Missing file was accepted")
    } catch {}
    do {
      _ = try await QuickDraftFile.capture(root)
      Issue.record("Folder was accepted")
    } catch {}
    let pdf = root.appendingPathComponent("oversized.pdf")
    try Data(count: 25 * 1024 * 1024 + 1).write(to: pdf)
    do {
      _ = try await QuickDraftFile.capture(pdf)
      Issue.record("Oversized PDF was accepted")
    } catch {}
  }

  @Test func unsupportedProtectedSubmissionNeverCreatesOrUploads() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    var draft = try await record(files: [file(root, name: "sample.txt")])
    draft.destination.sessionID = nil
    let rpc = CaptureRPC()
    rpc.exclusive = false
    do {
      _ = try await QuickDraftSubmission.send(draft, client: rpc, progress: { _ in })
      Issue.record("Unsupported attachment submission succeeded")
    } catch { #expect((error as? QuickSubmissionFailure)?.uncertain == false) }
    #expect(rpc.calls.map(\.0) == ["gateway.capabilities"])
  }

  @Test func captureDoesNotModifyWorkspaceAndRestoredUploadsStayBlocked() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let rpc = CaptureRPC()
    let model = DockModel(
      sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
      defaults: UserDefaults(suiteName: UUID().uuidString)!, initialSessionID: "workspace",
      botActivityFileURL: root.appendingPathComponent("bots.json"), rpcClient: rpc)
    model.draft = "Workspace text"
    let submitted = try await model.submitQuickDraft(record(), progress: { _ in })
    #expect(submitted.destination.sessionID == "owner")
    #expect(model.sessionID == "workspace")
    #expect(model.draft == "Workspace text")
    model.receiveGatewayEvent(
      "approval.request",
      params: [
        "session_id": "runtime", "request_id": "server-request",
        "payload": ["request_id": "approval-1", "command": "Run checks"],
      ])
    let attention = try #require(model.sessionAttention["owner"]?.responseTarget)
    #expect(attention.profileID == "research")
    #expect(attention.sessionID == "runtime")
    let interruptions = HermInterruptionCoordinator()
    model.interruptionCoordinator = interruptions
    interruptions.start()
    model.receiveGatewayEvent(
      "message.complete", params: ["session_id": "runtime", "payload": [:]])
    #expect(interruptions.entries.first?.sourceID == "owner")
    #expect(interruptions.entries.first?.profileID == "research")
    var blocked = record()
    blocked.delivery = .needsReview
    let before = rpc.calls.count
    do {
      _ = try await QuickDraftSubmission.send(blocked, client: rpc, progress: { _ in })
      Issue.record("Interrupted draft was resent")
    } catch {}
    #expect(rpc.calls.count == before)
  }

  @Test func renderCapturedDraft() async throws {
    guard let output = ProcessInfo.processInfo.environment["NOTCH_SNAPSHOT_DIR"] else { return }
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = QuickDraftStore(directory: root.appendingPathComponent("drafts"))
    var draft = try await record(files: [
      file(root, name: "research-notes.txt"), file(root, name: "brief.pdf"),
    ])
    draft.sources = ["https://example.com/source"]
    store.save(draft)
    let state = EdgeNotchState(store: store)
    state.restoreQuickDraft(draft)
    state.composing = true
    let model = DockModel(
      sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
      defaults: UserDefaults(suiteName: UUID().uuidString)!, initialSessionID: "workspace",
      botActivityFileURL: root.appendingPathComponent("bots.json"), rpcClient: CaptureRPC())
    let view = EdgeQuickMessageView(model: model, control: ControlCenterModel(), state: state, close: {}, openDock: {})
      .frame(width: 352, height: 272).background(Color.dockCanvas)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 352, height: 272)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    for _ in 0..<3 {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
    }
    let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: image)
    let png = try #require(image.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("captured-draft.png"))
    state.draftStore.flush()
  }

  @Test func discardNeverDeletesUserFilesOrUnownedPaths() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let selected = try await file(root, name: "user.txt")
    let store = QuickDraftStore(directory: root.appendingPathComponent("recovery"))
    var draft = record(files: [selected])
    draft.files[0] = QuickDraftFile(
      name: selected.name, bookmark: selected.bookmark,
      fallbackURL: selected.fallbackURL, kind: selected.kind, digest: selected.digest, owned: true)
    store.save(draft)
    store.remove(draft)
    store.flush()
    #expect(FileManager.default.fileExists(atPath: selected.fallbackURL.path))
  }
}
