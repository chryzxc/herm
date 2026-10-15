import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct WorkflowPreviewRenderTests {
  @Test func renderFixedWorkflowBodies() async throws {
    guard let path = ProcessInfo.processInfo.environment["NOTCH_SNAPSHOT_DIR"] else { return }
    let name = "WorkflowPreviewRenderTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = CommandCenterPreferencesStore(defaults: defaults)
    let destination = QuickDestination(
      profileID: "research", sessionID: "brief", title: "Research brief")
    preferences.saveWorkingSet(name: "Research", destination: destination)
    let set = try #require(preferences.workingSets.first)
    let content = WorkflowContentStore()
    let drafts = QuickDraftStore()
    let savedDraft = QuickDraftRecord(destination: destination, text: "Referenced draft")
    drafts.save(savedDraft)
    try content.save(
      WorkingSetCheckpoint(
        workingSetID: set.id, note: "Compare the two sources before sending the correction.",
        destinationKey: destination.key, draftID: savedDraft.id))
    let savedCheckpoint = content.checkpoints.first
    let state = EdgeNotchState(store: drafts, content: content, preferences: preferences)
    state.restoreQuickDraft(
      QuickDraftRecord(destination: destination, text: "Different current draft"))
    let model = DockModel()
    defer { model.shutdown() }
    let old = EdgeResultContent(text: "First source\nOriginal conclusion", artifacts: [])
    let new = EdgeResultContent(
      text: "First source\nCorrected conclusion\nSecond source", artifacts: [])
    let views: [(String, AnyView)] = [
      (
        "saved-actions",
        AnyView(EdgeQuickActionsView(state: state, model: model, back: {}, activate: {}))
      ),
      (
        "checkpoint",
        AnyView(
          EdgeCheckpointView(setID: set.id, state: state, model: model, back: {}, activate: {}))
      ),
      (
        "checkpoint-missing",
        AnyView(
          EdgeCheckpointView(setID: UUID(), state: state, model: model, back: {}, activate: {}))
      ),
      (
        "result-comparison",
        AnyView(
          ScrollView {
            EdgeResultComparison(
              previous: old, current: new, comparison: .make(previous: old.text, current: new.text))
          }.padding(10))
      ),
    ]
    for (name, view) in views {
      let host = NSHostingView(
        rootView: view.frame(width: 352, height: 272).background(Color.dockCanvas))
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
      #expect(host.bounds.width == 352 && host.bounds.height == 272)
      let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      let png = try #require(rep.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("\(name).png"))
    }
    #expect(content.checkpoints.first == savedCheckpoint)
  }
}
