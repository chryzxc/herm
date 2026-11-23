import SwiftUI

struct StatusBarHoverPreview<Preview: View>: ViewModifier {
    @Binding var selection: UUID?
    @Binding var isPinned: Bool
    let allowsHover: Bool
    @ViewBuilder let preview: () -> Preview
    @Environment(\.isEnabled) private var isEnabled
    @State private var anchorID = UUID()
    @State private var overAnchor = false
    @State private var overPreview = false
    @State private var transition: Task<Void, Never>?

    init(
        selection: Binding<UUID?>, isPinned: Binding<Bool> = .constant(false), allowsHover: Bool = true,
        @ViewBuilder preview: @escaping () -> Preview
    ) {
        _selection = selection
        _isPinned = isPinned
        self.allowsHover = allowsHover
        self.preview = preview
    }

    func body(content: Content) -> some View {
        content
            .onHover { isInside in
                overAnchor = isInside
                updatePresentation()
            }
            .dockPopover(isPresented: presentation, arrowEdge: .bottom) {
                preview().onHover { isInside in
                    overPreview = isInside
                    updatePresentation()
                }
            }
            .onChange(of: selection) { _, selected in
                if selected != anchorID { overPreview = false }
            }
            .onChange(of: isPinned) { _, pinned in
                if pinned { clearHover() }
            }
            .onChange(of: allowsHover) { _, allowed in
                if !allowed { clearHover() }
            }
            .onDisappear { clearHover() }
    }

    private var presentation: Binding<Bool> {
        Binding(
            get: { isPinned || (allowsHover && isEnabled && selection == anchorID) },
            set: { visible in
                if !visible {
                    if isPinned { isPinned = false }
                    clearHover()
                }
            })
    }

    private func updatePresentation() {
        transition?.cancel()
        guard isEnabled, allowsHover, !isPinned else { return }
        let shouldOpen = overAnchor || overPreview
        if shouldOpen == (selection == anchorID) { return }
        transition = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(shouldOpen ? 400 : 300)) } catch { return }
            if shouldOpen, isEnabled, allowsHover, !isPinned {
                selection = anchorID
            } else if !shouldOpen, selection == anchorID {
                selection = nil
            }
        }
    }

    private func clearHover() {
        transition?.cancel()
        overPreview = false
        if selection == anchorID { selection = nil }
    }
}
