import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct LayoutRetentionTests {
    @Test func adaptivePanesRetainStateAcrossCollapseAndWidthChanges() async throws {
        let state = RetentionFixtureState()
        let primary = RetentionRecorder()
        let secondary = RetentionRecorder()
        let host = NSHostingView(
            rootView: RetentionSplitFixture(state: state, primary: primary, secondary: secondary))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        try await settle(host)
        #expect(primary.identities.count == 1)
        #expect(secondary.identities.count == 1)
        for width: CGFloat in [1200, 650, 1200] {
            window.setContentSize(NSSize(width: width, height: 600))
            for collapsed in [true, false] {
                state.collapsed = collapsed
                state.detail = collapsed
                try await settle(host)
            }
        }
        #expect(primary.identities.count == 1)
        #expect(secondary.identities.count == 1)
    }

    @Test func disclosureMountsLazilyAndRetainsNestedState() async throws {
        let state = RetentionFixtureState()
        let recorder = RetentionRecorder()
        let host = NSHostingView(rootView: RetentionDisclosureFixture(state: state, recorder: recorder))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await settle(host)
        #expect(recorder.identities.isEmpty)
        for _ in 0..<3 {
            state.detail = true
            try await settle(host)
            state.detail = false
            try await settle(host)
        }
        #expect(recorder.identities.count == 1)
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class RetentionFixtureState: ObservableObject {
    @Published var collapsed = false
    @Published var detail = false
}

@MainActor
private final class RetentionRecorder {
    var identities: Set<UUID> = []
}

private struct RetentionSplitFixture: View {
    @ObservedObject var state: RetentionFixtureState
    let primary: RetentionRecorder
    let secondary: RetentionRecorder

    var body: some View {
        AdaptiveSplit(
            primaryMinWidth: 300, secondaryMinWidth: 360, alwaysSplitWhenWide: true,
            hidesPrimary: state.collapsed, showsSecondary: state.detail
        ) {
            RetentionProbe(recorder: primary)
        } secondary: {
            RetentionProbe(recorder: secondary)
        }
    }
}

private struct RetentionDisclosureFixture: View {
    @ObservedObject var state: RetentionFixtureState
    let recorder: RetentionRecorder

    var body: some View {
        DisclosureGroup("Section", isExpanded: $state.detail) {
            RetentionProbe(recorder: recorder)
        }
        .disclosureGroupStyle(DockDisclosureGroupStyle())
    }
}

private struct RetentionProbe: View {
    let recorder: RetentionRecorder
    @State private var identity = UUID()

    var body: some View {
        RetentionNativeProbe(identity: identity, recorder: recorder)
    }
}

private struct RetentionNativeProbe: NSViewRepresentable {
    let identity: UUID
    let recorder: RetentionRecorder

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        recorder.identities.insert(identity)
    }
}
