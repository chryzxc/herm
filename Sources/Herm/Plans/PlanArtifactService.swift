import CryptoKit
import Foundation

struct PlanArtifactService {
    let plansRoot: URL
    let maxArtifactBytes: Int
    let fileManager: FileManager
    private let isoFormatter: ISO8601DateFormatter

    init(projectRoot: URL, maxArtifactBytes: Int = 512_000, fileManager: FileManager = .default) {
        self.plansRoot = projectRoot.appendingPathComponent(".hermes/plans", isDirectory: true).standardizedFileURL
        self.maxArtifactBytes = maxArtifactBytes
        self.fileManager = fileManager
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter
    }

    init(plansRoot: URL, maxArtifactBytes: Int = 512_000, fileManager: FileManager = .default) {
        self.plansRoot = plansRoot.standardizedFileURL
        self.maxArtifactBytes = maxArtifactBytes
        self.fileManager = fileManager
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter
    }

    static var defaultPlansRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/plans", isDirectory: true)
            .standardizedFileURL
    }

    func list() -> [PlanArtifactSummary] {
        guard fileManager.fileExists(atPath: plansRoot.path) else { return [] }
        let urls = (fileManager.subpaths(atPath: plansRoot.path) ?? [])
            .map { plansRoot.appendingPathComponent($0) }
            // Review files are persistence metadata for annotations, not plan artifacts.
            // Keeping them out of this projection prevents a comment from appearing as
            // a selectable document in the library.
            .filter { isMarkdown($0) && !isReviewArtifact($0) && isContained($0) && isRegularOrSafeSymlink($0) }
        return urls.compactMap { summary(for: $0) }.sorted {
            if $0.modifiedAt != $1.modifiedAt { return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    func load(relativePath: String) throws -> PlanArtifactDocument {
        let url = try safeURL(for: relativePath, allowReviews: false)
        guard fileManager.fileExists(atPath: url.path) else { throw PlanArtifactError.missingArtifact }
        guard isMarkdown(url), isRegularOrSafeSymlink(url) else { throw PlanArtifactError.unsupportedFile }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maxArtifactBytes else { throw PlanArtifactError.fileTooLarge }
        guard let contents = String(data: data, encoding: .utf8) else { throw PlanArtifactError.invalidUTF8 }
        let summary = summary(for: url, contents: contents) ?? PlanArtifactSummary(relativePath: relativePath, title: title(for: relativePath, contents: contents), modifiedAt: nil, byteCount: data.count, sha256: hash(data), state: .available)
        return PlanArtifactDocument(summary: summary, contents: contents)
    }

    func comments(for document: PlanArtifactDocument) throws -> [PlanReviewComment] {
        let reviewURL = try reviewURL(for: document.relativePath, create: false)
        guard fileManager.fileExists(atPath: reviewURL.path) else { return [] }
        guard isRegularOrSafeSymlink(reviewURL) else { throw PlanArtifactError.unsupportedFile }
        let text = try String(contentsOf: reviewURL, encoding: .utf8)
        return parseComments(text, planPath: document.relativePath, fallbackSHA: document.sha256 ?? "")
    }

    @discardableResult
    func saveComment(_ comment: PlanReviewComment) throws -> URL {
        let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !body.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else { throw PlanArtifactError.invalidComment }
        let review = try reviewURL(for: comment.planPath, create: true)
        var content = (try? String(contentsOf: review, encoding: .utf8)) ?? "# Plan review comments\n\n"
        if !content.hasSuffix("\n") { content.append("\n") }
        content += "## Comment \(comment.id.uuidString)\n"
        content += "- created: \(isoFormatter.string(from: comment.createdAt))\n"
        content += "- plan: \(comment.planPath)\n"
        content += "- sha256: \(comment.planSHA256)\n"
        if let anchor = comment.anchor, !anchor.isEmpty { content += "- anchor: \(anchor.replacingOccurrences(of: "\n", with: " "))\n" }
        content += "\n\(body)\n\n"
        do {
            try content.write(to: review, atomically: true, encoding: .utf8)
            return review
        } catch { throw PlanArtifactError.writeFailed(error.localizedDescription) }
    }

    func revisionDraft(for document: PlanArtifactDocument, now: Date = .now) -> PlanRevisionDraft {
        let timestamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
        let stem = URL(fileURLWithPath: document.relativePath).deletingPathExtension().lastPathComponent
        let path = "\(timestamp)-\(stem)-revision.md"
        let hash = document.sha256 ?? ""
        let contents = "---\nparent_plan: \(document.relativePath)\nparent_sha256: \(hash)\n---\n\n\(document.contents)"
        return PlanRevisionDraft(relativePath: path, parentPlan: document.relativePath, parentSHA256: hash, contents: contents)
    }

    @discardableResult
    func saveRevision(_ draft: PlanRevisionDraft) throws -> URL {
        guard !draft.parentPlan.isEmpty, !draft.parentSHA256.isEmpty else { throw PlanArtifactError.writeFailed("Missing parent provenance") }
        let target = try validatedLocalURL(try safeURL(for: draft.relativePath, allowReviews: false))
        guard target.pathExtension.lowercased() == "md" else { throw PlanArtifactError.unsupportedFile }
        guard !fileManager.fileExists(atPath: target.path) else { throw PlanArtifactError.writeFailed("Revision already exists") }
        do {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try draft.contents.write(to: target, atomically: true, encoding: .utf8)
            return target
        } catch { throw PlanArtifactError.writeFailed(error.localizedDescription) }
    }

    private func summary(for url: URL, contents: String? = nil) -> PlanArtifactSummary? {
        let relative = relativePath(for: url)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modified = attributes[.modificationDate] as? Date
        if byteCount > maxArtifactBytes { return PlanArtifactSummary(relativePath: relative, title: title(for: relative, contents: contents), modifiedAt: modified, byteCount: byteCount, sha256: nil, state: .unavailable(PlanArtifactError.fileTooLarge.localizedDescription)) }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), let text = contents ?? String(data: data, encoding: .utf8) else {
            return PlanArtifactSummary(relativePath: relative, title: title(for: relative, contents: contents), modifiedAt: modified, byteCount: byteCount, sha256: nil, state: .unavailable(PlanArtifactError.invalidUTF8.localizedDescription))
        }
        return PlanArtifactSummary(relativePath: relative, title: title(for: relative, contents: text), modifiedAt: modified, byteCount: byteCount, sha256: hash(data), state: .available)
    }

    private func safeURL(for relativePath: String, allowReviews: Bool) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\\") else { throw PlanArtifactError.invalidPath }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains("."), components.first != ".hermes", components.first != "plans" else { throw PlanArtifactError.invalidPath }
        if !allowReviews && components.contains("reviews") { throw PlanArtifactError.invalidPath }
        let url = plansRoot.appendingPathComponent(components.joined(separator: "/")).standardizedFileURL
        guard isContained(url) else { throw PlanArtifactError.outsidePlansDirectory }
        guard fileManager.fileExists(atPath: plansRoot.path) else { throw PlanArtifactError.missingPlansDirectory }
        return url
    }

    private func reviewURL(for planPath: String, create: Bool) throws -> URL {
        guard (try? safeURL(for: planPath, allowReviews: false)) != nil else { throw PlanArtifactError.invalidPath }
        let digest = planPath.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ".md", with: "")
        let review = plansRoot.appendingPathComponent("reviews/\(digest).md").standardizedFileURL
        let resolvedReview = try validatedLocalURL(review)
        if create { try fileManager.createDirectory(at: resolvedReview.deletingLastPathComponent(), withIntermediateDirectories: true) }
        return resolvedReview
    }

    private func validatedLocalURL(_ url: URL) throws -> URL {
        guard fileManager.fileExists(atPath: plansRoot.path) else {
            throw PlanArtifactError.missingPlansDirectory
        }

        let lexicalURL = url.standardizedFileURL
        guard isContained(lexicalURL) else { throw PlanArtifactError.outsidePlansDirectory }

        let canonicalRoot = plansRoot.resolvingSymlinksInPath().standardizedFileURL
        let canonicalURL = lexicalURL.resolvingSymlinksInPath().standardizedFileURL
        guard isContained(canonicalURL, within: canonicalRoot), canonicalURL == lexicalURL,
              !hasSymlinkInExistingPath(from: plansRoot, to: lexicalURL) else {
            throw PlanArtifactError.outsidePlansDirectory
        }
        return lexicalURL
    }

    private func hasSymlinkInExistingPath(from root: URL, to destination: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard destinationPath == rootPath || destinationPath.hasPrefix(rootPath + "/") else { return true }

        var currentPath = rootPath
        let suffix = String(destinationPath.dropFirst(rootPath.count)).split(separator: "/", omittingEmptySubsequences: true)
        for component in suffix {
            currentPath += "/" + component
            guard fileManager.fileExists(atPath: currentPath) else { break }
            if (try? fileManager.destinationOfSymbolicLink(atPath: currentPath)) != nil { return true }
        }
        return false
    }

    private func isContained(_ url: URL, within root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(rootPath)
    }

    private func isContained(_ url: URL) -> Bool { isContained(url, within: plansRoot) }

    private func isRegularOrSafeSymlink(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard isContained(resolved), let attributes = try? fileManager.attributesOfItem(atPath: resolved.path) else { return false }
        return (attributes[.type] as? FileAttributeType) == .typeRegular
    }

    private func isMarkdown(_ url: URL) -> Bool { ["md", "markdown"].contains(url.pathExtension.lowercased()) }
    private func isReviewArtifact(_ url: URL) -> Bool {
        relativePath(for: url).split(separator: "/").first == "reviews"
    }
    private func relativePath(for url: URL) -> String { String(url.path.dropFirst(plansRoot.path.count + 1)) }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func title(for relativePath: String, contents: String?) -> String {
        if let heading = contents?.split(separator: "\n").first(where: { $0.hasPrefix("# ") }) { return String(heading.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
    }

    private func parseComments(_ text: String, planPath: String, fallbackSHA: String) -> [PlanReviewComment] {
        let lines = text.components(separatedBy: .newlines)
        var result: [PlanReviewComment] = []
        var index = 0
        while index < lines.count {
            guard lines[index].hasPrefix("## Comment ") else { index += 1; continue }
            let id = UUID(uuidString: String(lines[index].dropFirst("## Comment ".count))) ?? UUID()
            var sha = fallbackSHA
            var anchor: String?
            var created = Date.distantPast
            index += 1
            while index < lines.count, !lines[index].hasPrefix("## Comment ") {
                let line = lines[index]
                if line.hasPrefix("- sha256: ") { sha = String(line.dropFirst("- sha256: ".count)) }
                if line.hasPrefix("- anchor: ") { anchor = String(line.dropFirst("- anchor: ".count)) }
                if line.hasPrefix("- created: "), let date = isoFormatter.date(from: String(line.dropFirst("- created: ".count))) { created = date }
                if line.isEmpty { break }
                index += 1
            }
            while index < lines.count, lines[index].isEmpty { index += 1 }
            var body: [String] = []
            while index < lines.count, !lines[index].hasPrefix("## Comment ") { body.append(lines[index]); index += 1 }
            while body.last?.isEmpty == true { body.removeLast() }
            result.append(PlanReviewComment(id: id, planPath: planPath, planSHA256: sha, anchor: anchor, body: body.joined(separator: "\n"), createdAt: created))
        }
        return result
    }
}
