import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct WorkflowPreviewRenderTests {
  @Test func renderFixedWorkflowBodies() async throws {
    guard let path = ProcessInfo.processInfo.environment["NOTCH_SNAPSHOT_DIR"] else { return }
    let old = EdgeResultContent(text: "First source\nOriginal conclusion", artifacts: [])
    let new = EdgeResultContent(
      text: "First source\nCorrected conclusion\nSecond source", artifacts: [])
    let views: [(String, AnyView)] = [
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
  }
}
