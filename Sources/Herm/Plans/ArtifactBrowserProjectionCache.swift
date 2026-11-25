import Foundation

/// Query and layout data derived from one immutable, session-scoped index.
@MainActor
final class ArtifactBrowserProjectionCache {
    struct Request: Equatable, Sendable {
        let index: RichArtifactIndex.Snapshot
        let query: String
        let kind: ArtifactKind?
        let savedOnly: Bool
        let bookmarks: [RichArtifactBookmark]
        let resources: [ArtifactResourceBookmark]
        let day: Date

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.sameMetadata(as: rhs) && lhs.query == rhs.query && lhs.kind == rhs.kind
                && lhs.savedOnly == rhs.savedOnly
        }

        func sameMetadata(as other: Self) -> Bool {
            index === other.index && day == other.day && bookmarks == other.bookmarks && resources == other.resources
        }
    }

    struct Counts: Sendable {
        var total = 0
        var archiveTotal = 0
        var sessions = 0
        var images = 0
        var files = 0
        var links = 0
        var interactive = 0
        var saved = 0
    }

    struct Projection: Sendable {
        var visible: [ArtifactRecord] = []
        var visibleIDs: [String] = []
        var sections: [ArtifactDaySection] = []
        var imageRecords: [ArtifactRecord] = []
        var fileRecords: [ArtifactRecord] = []
        var inspectorFileRecords: [ArtifactRecord] = []
        var generatedRecords: [ArtifactRecord] = []
        var unavailableRecords: [ArtifactRecord] = []
        var counts = Counts()
    }

    private struct Entry: Sendable {
        let record: ArtifactRecord
        let id: String
        let kind: ArtifactKind
        let dayTitle: String
        let label: String
        let title: String

        func matches(_ query: String, kind: ArtifactKind?) -> Bool {
            (kind == nil || self.kind == kind)
                && (query.isEmpty || label.contains(query) || title.contains(query)
                    || record.value.lowercased().contains(query))
        }
    }

    private struct Metadata: Sendable {
        let latest: [Entry]
        let saved: [Entry]
        let counts: Counts

        init(_ request: Request) throws {
            let calendar = Calendar.current
            let bookmarks = Dictionary(grouping: request.bookmarks) { $0.reference.sessionID }
            let resourceIDs = Set(request.resources.map(\.id))
            var entries: [String: Entry] = [:]
            var titles: [Date: String] = [:]
            func entry(_ record: ArtifactRecord, id: String) -> Entry {
                if let found = entries[id] { return found }
                let date = calendar.startOfDay(for: record.timestamp)
                let dayTitle = titles[date] ?? ArtifactDaySection.title(for: date, now: request.day, calendar: calendar)
                titles[date] = dayTitle
                let found = Entry(
                    record: record, id: id, kind: record.kind, dayTitle: dayTitle,
                    label: record.label.lowercased(), title: record.sessionTitle.lowercased())
                entries[id] = found
                return found
            }
            var saved: [Entry] = []
            var savedIDs = Set<String>()
            if !bookmarks.isEmpty || !resourceIDs.isEmpty {
                for record in request.index.records {
                    try Task.checkCancellation()
                    let id = record.id
                    let isSaved: Bool
                    if let reference = record.generated?.reference ?? record.unavailableBookmark?.reference {
                        isSaved = bookmarks[reference.sessionID]?.contains { $0.reference.matches(reference) } == true
                    } else {
                        isSaved = resourceIDs.contains(id)
                    }
                    if isSaved {
                        saved.append(entry(record, id: id))
                        savedIDs.insert(id)
                    }
                }
            }
            var latest: [Entry] = []
            var counts = Counts()
            for record in request.index.latest {
                try Task.checkCancellation()
                let id = record.id
                guard record.unavailableBookmark == nil || savedIDs.contains(id) else { continue }
                let item = entry(record, id: id)
                latest.append(item)
                switch item.kind {
                case .image: counts.images += 1
                case .file: counts.files += 1
                case .link: counts.links += 1
                case .interactive: counts.interactive += 1
                }
            }
            counts.total = latest.count
            counts.archiveTotal = request.index.records.count
            counts.sessions = Set(request.index.records.lazy.map(\.scopedSessionID)).count
            counts.saved = saved.count
            self.latest = latest
            self.saved = saved
            self.counts = counts
        }

        func project(_ request: Request) throws -> Projection {
            let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var projection = Projection(counts: counts)
            var order: [String] = []
            var byDay: [String: [ArtifactRecord]] = [:]
            for entry in request.savedOnly ? saved : latest {
                try Task.checkCancellation()
                guard entry.matches(query, kind: request.kind) else { continue }
                let record = entry.record
                projection.visible.append(record)
                projection.visibleIDs.append(entry.id)
                if byDay[entry.dayTitle] == nil { order.append(entry.dayTitle) }
                byDay[entry.dayTitle, default: []].append(record)
                if entry.kind == .image {
                    projection.imageRecords.append(record)
                } else {
                    projection.fileRecords.append(record)
                    if entry.kind != .interactive { projection.inspectorFileRecords.append(record) }
                }
                if record.generated != nil { projection.generatedRecords.append(record) }
                if record.unavailableBookmark != nil { projection.unavailableRecords.append(record) }
            }
            projection.sections = order.map { ArtifactDaySection(title: $0, records: byDay[$0] ?? []) }
            return projection
        }
    }

    private var lastRequest: Request?
    private var metadata: Metadata?
    private var value: Projection?
    private var generation = 0
    private(set) var buildCount = 0
    private(set) var metadataBuildCount = 0

    func project(_ request: Request) async -> Projection? {
        guard !Task.isCancelled else { return nil }
        generation &+= 1
        let ticket = generation
        if lastRequest == request, let value { return value }
        let previous = lastRequest?.sameMetadata(as: request) == true ? metadata : nil
        let worker = Task.detached(priority: .userInitiated) {
            let metadata = try previous ?? Metadata(request)
            return (metadata, try metadata.project(request))
        }
        let result = await withTaskCancellationHandler {
            try? await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, ticket == generation, let (metadata, projection) = result else { return nil }
        lastRequest = request
        self.metadata = metadata
        value = projection
        buildCount += 1
        if previous == nil { metadataBuildCount += 1 }
        return projection
    }
}
