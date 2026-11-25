import Darwin
import Foundation
import os

struct PlanFileRevision: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let bytes: Int64
    let modifiedAt: Date
    let changeSeconds: Int
    let changeNanoseconds: Int

    init?(_ file: URL) {
        var info = stat()
        guard
            file.withUnsafeFileSystemRepresentation({ path in
                guard let path else { return false }
                return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            })
        else { return nil }
        device = info.st_dev
        inode = info.st_ino
        bytes = info.st_size
        modifiedAt = Date(
            timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        changeSeconds = info.st_ctimespec.tv_sec
        changeNanoseconds = info.st_ctimespec.tv_nsec
    }
}

/// Shared by visible Plan rails and Markdown previews. Call off the main actor.
final class PlanFileCache: Sendable {
    static let shared = PlanFileCache()
    static let maximumPlanBytes = 1_000_000

    struct Preview: Sendable {
        let revision: PlanFileRevision?
        let content: ArtifactTextPreview.Content
        let map: SpecMap?
    }

    private struct Parsed {
        let fallback: String
        let map: SpecMap
        let usesFallbackTitle: Bool
    }

    private enum Use: Hashable {
        case rail, linked, preview, truncatedPreview
    }

    private final class Entry {
        let revision: PlanFileRevision
        let data: Data
        lazy var fullText = String(data: data, encoding: .utf8)
        lazy var previewContent = ArtifactTextPreview.Content.decode(data)
        var maps: [Use: Parsed] = [:]

        init(revision: PlanFileRevision, data: Data) {
            self.revision = revision
            self.data = data
        }

        func map(text: String, use: Use, fallback: () -> String) -> SpecMap {
            if let match = maps[use] { return match.map }
            // A heading-supplied title makes fallback names irrelevant. A truncated
            // preview has different source text and keeps its own projection.
            if use != .truncatedPreview,
                let shared = maps.first(where: {
                    $0.key != .truncatedPreview && !$0.value.usesFallbackTitle
                })
            {
                maps[use] = shared.value
                return shared.value.map
            }
            let title = fallback()
            if use != .truncatedPreview,
                let shared = maps.first(where: { $0.key != .truncatedPreview && $0.value.fallback == title })
            {
                maps[use] = shared.value
                return shared.value.map
            }
            let (map, usesFallbackTitle) = SpecMapParser.parseWithTitleSource(text, fallbackTitle: title)
            maps[use] = Parsed(fallback: title, map: map, usesFallbackTitle: usesFallbackTitle)
            return map
        }
    }

    private let files = OSAllocatedUnfairLock(
        uncheckedState: {
            let entries = NSCache<NSString, Entry>()
            entries.countLimit = 64
            entries.totalCostLimit = 16_000_000
            return entries
        }())
    private let inventories = OSAllocatedUnfairLock(
        initialState: [URL: (expiresAt: TimeInterval, files: [URL])]())

    func candidates(in service: PlanArtifactService, maxAge: TimeInterval) -> [URL] {
        guard maxAge > 0 else { return service.planFileCandidates() }
        return inventories.withLockUnchecked { inventories in
            let now = ProcessInfo.processInfo.systemUptime
            if let cached = inventories[service.plansRoot], cached.expiresAt > now { return cached.files }
            let files = service.planFileCandidates()
            inventories = inventories.filter { $0.value.expiresAt > now }
            if inventories.count >= 16,
                let oldest = inventories.min(by: {
                    $0.value.expiresAt < $1.value.expiresAt
                })
            {
                inventories.removeValue(forKey: oldest.key)
            }
            inventories[service.plansRoot] = (ProcessInfo.processInfo.systemUptime + maxAge, files)
            return files
        }
    }

    func plan(at file: URL, maxBytes: Int, linked: Bool, title: (String) -> String) -> (PlanFileRevision, SpecMap)? {
        guard let revision = PlanFileRevision(file), revision.bytes <= maxBytes,
            FileManager.default.isReadableFile(atPath: file.path)
        else { return nil }
        return files.withLockUnchecked { entries in
            guard let entry = entry(at: file, revision: revision, entries: entries),
                entry.data.count <= maxBytes, let text = entry.fullText
            else { return nil }
            return (revision, entry.map(text: text, use: linked ? .linked : .rail) { title(text) })
        }
    }

    func preview(at file: URL, markdown: Bool, after previous: PlanFileRevision?) -> Preview? {
        let revision = PlanFileRevision(file)
        if let previous, revision == previous { return nil }
        guard let revision else { return Preview(revision: nil, content: .missing, map: nil) }
        if !markdown {
            return Preview(revision: revision, content: ArtifactTextPreview.Content.load(file), map: nil)
        }
        return files.withLockUnchecked { entries in
            guard let entry = entry(at: file, revision: revision, entries: entries) else {
                return Preview(revision: nil, content: .missing, map: nil)
            }
            let content = entry.previewContent
            let map: SpecMap?
            if case .text(let text, let truncated) = content {
                map = entry.map(text: text, use: truncated ? .truncatedPreview : .preview) { file.lastPathComponent }
            } else {
                map = nil
            }
            return Preview(revision: revision, content: content, map: map)
        }
    }

    private func entry(at file: URL, revision: PlanFileRevision, entries: NSCache<NSString, Entry>) -> Entry? {
        let key = file.standardizedFileURL.path as NSString
        if let cached = entries.object(forKey: key), cached.revision == revision { return cached }
        guard !Task.isCancelled, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let limit =
            revision.bytes <= Self.maximumPlanBytes
            ? Self.maximumPlanBytes : ArtifactTextPreview.Content.limit
        guard let data = try? handle.read(upToCount: limit + 1) ?? Data(),
            PlanFileRevision(file) == revision
        else { return nil }
        let entry = Entry(revision: revision, data: data)
        entries.setObject(entry, forKey: key, cost: data.count * 3)
        return entry
    }
}
