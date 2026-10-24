import AppKit
import SwiftUI
import Testing

@testable import Herm

struct MessageNavigatorSearchTests {
    private func item(_ ordinal: Int, text: String, storedRowID: Int? = nil) -> MessageNavigatorItem {
        MessageNavigatorItem(
            target: .init(sessionID: "owner", messageID: UUID()), ordinal: ordinal,
            roleLabel: ordinal.isMultiple(of: 2) ? "You" : "Hermes", preview: "Bounded preview",
            contentRevision: ordinal, hasImages: false, searchText: text, storedRowID: storedRowID)
    }

    @MainActor @Test func backgroundSearchPreservesFullTextUnicodeOrderAndStoredTargets() async throws {
        let body = String(repeating: "Ordinary history with **Markdown** and `code`.\n", count: 256)
        let items = (0..<500).map { index in
            item(
                index, text: body + (index.isMultiple(of: 7) ? "Café needle at the end" : "No match"),
                storedRowID: index < 10 ? index : nil)
        }
        let results = try await MessageNavigator.searchInBackground(items: items, query: "  CAFE NEEDLE  ")
        #expect(results == items.filter { $0.ordinal.isMultiple(of: 7) })
        #expect(results.first?.storedRowID == 0)
        #expect(try await MessageNavigator.searchInBackground(items: items, query: "  ") == items)
        #expect(
            try await MessageNavigator.searchInBackground(items: items, query: "you")
                == items.filter { $0.roleLabel == "You" })
    }

    @Test func cancelledSearchCannotReturnResults() async {
        let items = [item(1, text: "Needle")]
        let task = Task { try await MessageNavigator.searchInBackground(items: items, query: "needle") }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled search returned results")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func returnUsesCompletedResultsOrWaitsForTheSameRequest() {
        let match = item(1, text: "Needle")
        let request = MessageNavigatorSearchRequest(
            snapshot: .init(items: [match]), sessionID: "owner", query: "needle")
        var state = MessageNavigatorSearchState()
        #expect(!state.isComplete(for: request))
        #expect(state.submit(request) == nil)
        #expect(state.complete([match], for: request, current: request) == match)
        #expect(state.isComplete(for: request))
        #expect(state.results(for: request) == [match])
        #expect(state.submit(request) == match)
    }

    @Test func editsAndSessionChangesHideOldResultsAndRejectQueuedReturn() {
        let match = item(1, text: "Needle")
        let snapshot = MessageNavigatorSnapshot(items: [match])
        let first = MessageNavigatorSearchRequest(snapshot: snapshot, sessionID: "owner", query: "needle")
        let replacements = [
            MessageNavigatorSearchRequest(snapshot: snapshot, sessionID: "owner", query: "another query"),
            MessageNavigatorSearchRequest(snapshot: snapshot, sessionID: "another session", query: "needle"),
            MessageNavigatorSearchRequest(snapshot: .init(items: [match]), sessionID: "owner", query: "needle"),
        ]
        for next in replacements {
            var state = MessageNavigatorSearchState()
            #expect(state.complete([match], for: first, current: first) == nil)
            #expect(state.results(for: next).isEmpty)
            #expect(!state.isComplete(for: next))
            #expect(state.submit(next) == nil)
            #expect(state.complete([match], for: first, current: next) == nil)
            #expect(state.results(for: next).isEmpty)
            #expect(state.complete([match], for: next, current: next) == match)
        }
    }

    @Test func closingOrChangingQueryCancelsPendingSelectionEvenIfTheQueryReturns() {
        let match = item(1, text: "Needle")
        let request = MessageNavigatorSearchRequest(
            snapshot: .init(items: [match]), sessionID: "owner", query: "needle")
        let changed = MessageNavigatorSearchRequest(snapshot: request.snapshot, sessionID: "owner", query: "other")
        for next in [nil, changed] {
            var state = MessageNavigatorSearchState()
            #expect(state.submit(request) == nil)
            state.invalidateSelection(for: next)
            #expect(state.complete([match], for: request, current: request) == nil)
            #expect(state.results(for: nil).isEmpty)
            #expect(!state.isComplete(for: nil))
        }
    }

    @Test func noMatchesCompletesWithoutSelectingAnythingAndRequestEqualityUsesSnapshotIdentity() {
        let snapshot = MessageNavigatorSnapshot(items: [])
        let request = MessageNavigatorSearchRequest(snapshot: snapshot, sessionID: "owner", query: "absent")
        #expect(request == .init(snapshot: snapshot, sessionID: "owner", query: "absent"))
        var state = MessageNavigatorSearchState()
        #expect(state.submit(request) == nil)
        #expect(state.complete([], for: request, current: request) == nil)
        #expect(state.isComplete(for: request))
        #expect(state.results(for: request).isEmpty)
        #expect(state.submit(request) == nil)
    }

    @MainActor @Test func nativeFindReturnWaitsForTheTypedQueryAndNavigatesToItsMessage() async throws {
        _ = NSApplication.shared
        let first = item(1, text: "A different reply")
        let match = item(2, text: "The searchable needle")
        var presented = true
        var selection: MessageNavigatorItem?
        let host = NSHostingView(
            rootView: MessageNavigatorView(
                snapshot: .init(items: [first, match]), sessionID: "owner", visibleTargets: [],
                isSearchPresented: Binding(get: { presented }, set: { presented = $0 }), showsMap: false,
                onSelect: { selection = $0 }))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 360)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let field = try #require(fields(host).first { $0.isEditable })
        field.stringValue = "needle"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        host.layoutSubtreeIfNeeded()
        // Submit before the debounce finishes: Return must use this query rather than older matches.
        _ = field.sendAction(field.action, to: field.target)
        let deadline = Date().addingTimeInterval(5)
        while selection == nil && Date() < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(selection == match)
        #expect(!presented)
    }
}
