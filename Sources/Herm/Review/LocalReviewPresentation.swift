import Foundation

enum LocalReviewPresentation {
    static func selection(
        _ selected: String?, visible: [String], hasComparison: Bool, pending: Bool = false
    ) -> String? {
        guard hasComparison else { return selected }
        if let selected, visible.contains(selected) { return selected }
        if pending, selected != nil { return selected }
        return visible.first
    }

    static func matchIndex(previous: [DiffSearchMatch], index: Int, current: [DiffSearchMatch]) -> Int {
        guard !current.isEmpty else { return 0 }
        if previous.indices.contains(index), let retained = current.firstIndex(of: previous[index]) { return retained }
        return min(max(index, 0), current.count - 1)
    }
}
