import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct KanbanRenderingTests {
    private final class Fixture: ObservableObject {
        @Published var selection: String?
        @Published var pending: Set<String> = []
        @Published var tasks = (0..<1_000).map { index in
            KanbanTaskSummary(
                id: "task-\(index)", title: "Task \(index)", status: "todo",
                detail: "TASK_ID: task-\(index)\nOBJECTIVE: Keep this board responsive\n"
                    + String(repeating: "Task context. ", count: 100),
                priority: "50", assignee: nil)
        }
    }

    private struct Board: View {
        @ObservedObject var fixture: Fixture

        var body: some View {
            KanbanBoardView(
                tasks: fixture.tasks, bots: [], visibleBots: [], avatarImages: [:],
                selectedTaskID: fixture.selection,
                actions: KanbanCardActionAvailability(complete: true, block: true, move: true),
                pendingActionIDs: fixture.pending, loadingDetailTaskID: nil,
                onSelect: { fixture.selection = $0.id }, onAction: { _, _ in },
                onDrop: { _, _ in }, onAssign: { _, _ in }
            )
            .equatable()
        }
    }

    @Test func largeBoardUpdatesOnlyAffectedCards() async throws {
        #if DEBUG
            let fixture = Fixture()
            let evaluations = KanbanCardEvaluations()
            let host = NSHostingView(
                rootView: Board(fixture: fixture)
                    .environment(\.kanbanCardEvaluations, evaluations))
            host.sizingOptions = []
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.orderOut(nil) }

            func settle() async throws {
                for _ in 0..<4 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(30))
                }
            }

            try await settle()
            #expect(!evaluations.counts.isEmpty)
            #expect(evaluations.counts.count < 100)

            evaluations.counts = [:]
            fixture.tasks = fixture.tasks.map { $0 }
            try await settle()
            #expect(evaluations.counts.isEmpty)

            evaluations.counts = [:]
            fixture.selection = "task-0"
            try await settle()
            #expect(Set(evaluations.counts.keys) == ["task-0"])

            evaluations.counts = [:]
            fixture.pending = ["kanban.complete:task-1"]
            try await settle()
            #expect(Set(evaluations.counts.keys) == ["task-1"])

            evaluations.counts = [:]
            fixture.tasks[2].assignee = "forge"
            try await settle()
            #expect(Set(evaluations.counts.keys) == ["task-2"])

            evaluations.counts = [:]
            fixture.selection = "task-1"
            try await settle()
            #expect(Set(evaluations.counts.keys) == ["task-0", "task-1"])
        #endif
    }
}
