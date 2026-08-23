import Foundation

/// Owns the composer's draft text and prompt-history navigation. Kept separate
/// from DockModel so every keystroke re-renders only the composer view instead
/// of the whole popover (conversation, sidebar, and context panel observe
/// DockModel and would otherwise re-diff on each character).
@MainActor
final class ComposerText: ObservableObject {
    @Published var text = "" {
        didSet {
            guard !isUpdatingFromHistory else { return }
            historyIndex = nil
            restoreDraft = ""
        }
    }

    private var historyIndex: Int?
    private var restoreDraft = ""
    private var isUpdatingFromHistory = false

    /// Moves through the user prompts already present in the active session.
    /// Down past the newest prompt restores the draft that was present before
    /// history navigation began.
    func navigate(direction: Int, history: [String]) -> Bool {
        guard !history.isEmpty, direction != 0 else { return false }

        let nextIndex: Int?
        if direction < 0 {
            if let index = historyIndex {
                nextIndex = max(0, index - 1)
            } else {
                restoreDraft = text
                nextIndex = history.count - 1
            }
        } else {
            guard let index = historyIndex else { return false }
            if index + 1 < history.count {
                nextIndex = index + 1
            } else {
                setTextPreservingHistorySlot(restoreDraft)
                historyIndex = nil
                restoreDraft = ""
                return true
            }
        }

        guard let nextIndex else { return false }
        historyIndex = nextIndex
        setTextPreservingHistorySlot(history[nextIndex])
        return true
    }

    private func setTextPreservingHistorySlot(_ value: String) {
        isUpdatingFromHistory = true
        text = value
        isUpdatingFromHistory = false
    }
}
