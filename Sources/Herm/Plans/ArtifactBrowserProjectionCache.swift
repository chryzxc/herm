import Foundation

/// One disposable result for the current filter; unrelated model publications reuse it.
@MainActor
final class ArtifactBrowserProjectionCache {
    struct Projection {
        let visible: [ArtifactRecord]
        let sections: [ArtifactDaySection]
        let total: Int
        let images: Int
        let files: Int
        let links: Int
        let interactive: Int
        let saved: Int
    }

    private struct Key: Equatable {
        let index: ObjectIdentifier
        let query: String
        let kind: ArtifactKind?
        let savedOnly: Bool
        let bookmarks: [RichArtifactBookmark]
        let resources: [ArtifactResourceBookmark]
        let day: Date
    }
    private var key: Key?
    private var index: RichArtifactIndex.Snapshot?
    private var value: Projection?
    private(set) var buildCount = 0

    func project(
        index: RichArtifactIndex.Snapshot, query: String, kind: ArtifactKind?, savedOnly: Bool,
        bookmarks: [RichArtifactBookmark], resources: [ArtifactResourceBookmark],
        isSaved: (ArtifactRecord) -> Bool
    ) -> Projection {
        let next = Key(
            index: ObjectIdentifier(index), query: query, kind: kind, savedOnly: savedOnly,
            bookmarks: bookmarks, resources: resources, day: Calendar.current.startOfDay(for: .now))
        if key == next, let value { return value }
        let saved = index.records.filter(isSaved)
        let savedIDs = Set(saved.map(\.id))
        let latest = index.latest.filter { $0.unavailableBookmark == nil || savedIDs.contains($0.id) }
        let visible = ArtifactService.filter(savedOnly ? saved : latest, query: query, kind: kind)
        let projected = Projection(
            visible: visible, sections: ArtifactDaySection.group(visible), total: latest.count,
            images: latest.filter { $0.kind == .image }.count,
            files: latest.filter { $0.kind == .file }.count,
            links: latest.filter { $0.kind == .link }.count,
            interactive: latest.filter { $0.kind == .interactive }.count, saved: saved.count)
        self.index = index
        key = next
        value = projected
        buildCount += 1
        return projected
    }
}
