import Foundation

/// Only presentation coordinates; no task or conversation content is stored.
struct OfficePlacementStore {
    let defaults: UserDefaults
    private let key = "office.placements.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [String: OfficePreviewLayout.Node] {
        guard let data = defaults.data(forKey: key),
            let nodes = try? JSONDecoder().decode([String: OfficePreviewLayout.Node].self, from: data)
        else { return [:] }
        return nodes.filter { _, node in
            OfficePreviewLayout.locations.indices.contains(node.index)
                && node.slot >= -1 && node.slot < 10_000
                && (node.leisureIndex.map { $0 >= 0 } ?? true)
                && (node.connectorPosition.map { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } ?? true)
        }
    }

    func save(_ nodes: [String: OfficePreviewLayout.Node]) {
        guard let data = try? JSONEncoder().encode(nodes), data != defaults.data(forKey: key) else { return }
        defaults.set(data, forKey: key)
    }
}
