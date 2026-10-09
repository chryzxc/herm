import Foundation

/// One review note on a previewed file. A nil quote is a general note.
struct FileAnnotation: Identifiable, Codable, Equatable {
    var id = UUID()
    var quote: String?
    /// UTF-16 offset of the quote in the rendered document when it was made;
    /// picks the right occurrence when the quote appears more than once.
    var location: Int?
    /// Free-form: "add X here", "remove this", "say Y instead".
    var note: String
    /// nil while a draft; drafts are what the next send includes.
    var sentAt: Date?
    /// Set when a rewrite removed the quoted text — likely addressed.
    var resolved = false
}

struct FileReview: Codable, Equatable {
    var annotations: [FileAnnotation] = []
    /// File contents at the last send, so the pane can show what changed.
    var baseline: String?
}

/// The previewed file plus per-file review notes. Shared because chat
/// attachment cards have no handle on the view that owns the panel.
@MainActor
final class FilePreviewCenter: ObservableObject {
    static let shared = FilePreviewCenter()

    @Published var url: URL?
    /// Session the preview was opened from; revision requests go back there.
    @Published var sessionID: String?
    @Published private(set) var reviews: [String: FileReview] {
        didSet { save() }
    }

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.fileURL = fileURL ?? supportRoot.appendingPathComponent("Herm/file-reviews.json")
        self.reviews = (try? Data(contentsOf: self.fileURL))
            .flatMap { try? JSONDecoder().decode([String: FileReview].self, from: $0) } ?? [:]
    }

    func review(_ path: String) -> FileReview { reviews[path] ?? FileReview() }

    func add(_ annotation: FileAnnotation, to path: String) {
        reviews[path, default: FileReview()].annotations.append(annotation)
    }

    func update(_ annotation: FileAnnotation, in path: String) {
        guard let index = reviews[path]?.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        reviews[path]?.annotations[index] = annotation
    }

    func remove(_ id: UUID, from path: String) {
        reviews[path]?.annotations.removeAll { $0.id == id }
        dropIfEmpty(path)
    }

    func markSent(_ path: String, baseline: String) {
        guard var review = reviews[path] else { return }
        for index in review.annotations.indices where review.annotations[index].sentAt == nil {
            review.annotations[index].sentAt = .now
        }
        review.baseline = baseline
        reviews[path] = review
    }

    /// After the file changes, sent notes whose quote is gone count as addressed.
    func reconcile(_ path: String, contents: String) {
        guard var review = reviews[path] else { return }
        for index in review.annotations.indices where review.annotations[index].sentAt != nil {
            if let quote = review.annotations[index].quote {
                review.annotations[index].resolved = !FileAnnotationText.contains(contents, quote)
            }
        }
        if review != reviews[path] { reviews[path] = review }
    }

    func clearSent(_ path: String) {
        reviews[path]?.annotations.removeAll { $0.sentAt != nil }
        reviews[path]?.baseline = nil
        dropIfEmpty(path)
    }

    private func dropIfEmpty(_ path: String) {
        if let review = reviews[path], review.annotations.isEmpty, review.baseline == nil { reviews[path] = nil }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(reviews) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum FileAnnotationText {
    /// Lowercased alphanumerics with single spaces, so rendered selections
    /// (which have lost `**`, backticks, link syntax) match the raw Markdown.
    static func normalized(_ text: String) -> String {
        let mapped = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    static func contains(_ document: String, _ quote: String) -> Bool {
        let needle = normalized(quote)
        return !needle.isEmpty && normalized(document).contains(needle)
    }

    /// The occurrence of `quote` in `rendered` nearest to `hint`.
    static func range(of quote: String, in rendered: String, near hint: Int?) -> NSRange? {
        let haystack = rendered as NSString
        var best: NSRange?
        var search = NSRange(location: 0, length: haystack.length)
        while true {
            let found = haystack.range(of: quote, options: [], range: search)
            guard found.location != NSNotFound else { break }
            if best == nil || abs(found.location - (hint ?? 0)) < abs(best!.location - (hint ?? 0)) { best = found }
            let next = found.location + max(found.length, 1)
            guard next < haystack.length else { break }
            search = NSRange(location: next, length: haystack.length - next)
        }
        return best
    }

    static func prompt(path: String, annotations: [FileAnnotation]) -> String {
        var lines = ["Please revise `\(path)` in place based on my review notes. Leave everything I didn't comment on unchanged."]
        for (index, annotation) in annotations.enumerated() {
            let quote = annotation.quote.map { "\"\($0.replacingOccurrences(of: "\n", with: " "))\"" }
            let line = quote.map { "\($0) → \(annotation.note)" } ?? "[General] \(annotation.note)"
            lines.append("\(index + 1). \(line)")
        }
        return lines.joined(separator: "\n")
    }

    struct DiffLine: Equatable {
        let sign: Character
        let text: String
    }

    /// Removed (-) then inserted (+) lines, each in document order.
    static func lineDiff(old: String, new: String) -> [DiffLine] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let diff = newLines.difference(from: oldLines)
        func lines(_ changes: [CollectionDifference<String>.Change], sign: Character) -> [DiffLine] {
            changes.map { change -> (Int, String) in
                switch change {
                case .remove(let offset, let line, _), .insert(let offset, let line, _): (offset, line)
                }
            }
            .sorted { $0.0 < $1.0 }
            .map { DiffLine(sign: sign, text: $0.1) }
        }
        return lines(diff.removals, sign: "-") + lines(diff.insertions, sign: "+")
    }
}
