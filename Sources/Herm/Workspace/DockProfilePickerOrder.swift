import SwiftUI

@MainActor
final class DockProfilePickerOrder: ObservableObject {
    private let defaults: UserDefaults
    private let key = "herm.sidebar.profilePickerOrder"
    @Published private(set) var ids: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.ids = defaults.stringArray(forKey: key) ?? []
    }

    func ordered(_ bots: [BotSummary]) -> [BotSummary] {
        let visible = bots.filter { !$0.isHidden }
        let ranks = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return visible.enumerated().sorted {
            (ranks[$0.element.id] ?? ids.count + $0.offset) < (ranks[$1.element.id] ?? ids.count + $1.offset)
        }.map(\.element)
    }

    func move(_ id: String, by offset: Int, in bots: [BotSummary]) {
        let visible = ordered(bots)
        guard offset == -1 || offset == 1, let source = visible.firstIndex(where: { $0.id == id }),
            visible.indices.contains(source + offset)
        else { return }
        var moved = visible.map(\.id)
        moved.swapAt(source, source + offset)
        ids = moved + ids.filter { !moved.contains($0) }
        defaults.set(ids, forKey: key)
    }
}
