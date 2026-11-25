import Combine
import Foundation

/// Keep the latest console output for Send Console Errors. Only the count affects layout.
@MainActor
final class BrowserConsoleBuffer: ObservableObject {
    @Published private(set) var count = 0
    private(set) var lines: [String] = []
    private var visibleHosts = Set<UUID>()
    private var pendingUpdate: Task<Void, Never>?

    func append(_ line: String) {
        if lines.count == 50 { lines.removeFirst() }
        lines.append(String(line.prefix(2000)))
        scheduleUpdate()
    }

    func clear() {
        guard !lines.isEmpty else { return }
        lines.removeAll(keepingCapacity: true)
        scheduleUpdate()
    }

    func setVisible(_ host: UUID, _ visible: Bool) {
        if visible {
            let wasHidden = visibleHosts.isEmpty
            visibleHosts.insert(host)
            if wasHidden { publishCount() }
        } else {
            visibleHosts.remove(host)
            if visibleHosts.isEmpty {
                pendingUpdate?.cancel()
                pendingUpdate = nil
            }
        }
    }

    private func scheduleUpdate() {
        guard !visibleHosts.isEmpty, count != lines.count, pendingUpdate == nil else { return }
        pendingUpdate = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            self?.pendingUpdate = nil
            self?.publishCount()
        }
    }

    private func publishCount() {
        if count != lines.count { count = lines.count }
    }
}
