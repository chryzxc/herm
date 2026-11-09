import SwiftUI

/// Keeps image loading local to GitHub descriptions; code fences remain literal Markdown.
enum PullRequestDescriptionContent {
    enum Part: Equatable {
        case markdown(String)
        case image(URL, alt: String)
        case task(checked: Bool, text: String)
        case divider
    }

    /// GitHub renders private attachments into `body_html` with signed URLs; swap them in by position.
    static func resolvingImages(_ source: String, html: String?) -> String {
        guard let html,
            let sourceRegex = try? NSRegularExpression(
                pattern: #"!\[[^\]]*\]\(\s*<?(https?://[^\s)>]+)|<img\b[^>]*\bsrc=[\"'](https?://[^\"']+)"#,
                options: .caseInsensitive),
            let htmlRegex = try? NSRegularExpression(
                pattern: #"<img\b[^>]*\bsrc="(https?://[^"]+)""#, options: .caseInsensitive)
        else { return source }
        let ns = source as NSString
        let found = sourceRegex.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { match in
            match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
        }
        let htmlNS = html as NSString
        let signed = htmlRegex.matches(in: html, range: NSRange(location: 0, length: htmlNS.length)).map {
            htmlNS.substring(with: $0.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
        }
        // Positional pairing is only safe when both sides saw the same images.
        guard !found.isEmpty, found.count == signed.count else { return source }
        var result = source
        for (range, url) in zip(found, signed).reversed() {
            result = (result as NSString).replacingCharacters(in: range, with: url)
        }
        return result
    }

    static func parts(_ source: String) -> [Part] {
        let pattern =
            #"^\s*(?:!\[([^\]]*)\]\(\s*<?(https?://[^\s)>]+)>?(?:\s+\"[^\"]*\")?\s*\)"#
            + #"|<img\b[^>]*\bsrc=[\"'](https?://[^\"']+)[\"'][^>]*?/?>)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return [.markdown(source)]
        }
        var parts: [Part] = []
        var text: [String] = []
        var fence: MarkdownFence?
        func flush() {
            if !text.isEmpty {
                parts.append(.markdown(text.joined(separator: "\n")))
                text.removeAll()
            }
        }
        for line in source.components(separatedBy: "\n") {
            if let active = fence {
                text.append(line)
                if active.isClosed(by: line) { fence = nil }
                continue
            }
            if let opening = MarkdownFence(opening: line) {
                fence = opening
                text.append(line)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if ["---", "***", "___"].contains(trimmed) {
                flush()
                parts.append(.divider)
                continue
            }
            if trimmed.count >= 6,
                ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] "].contains(where: { trimmed.hasPrefix($0) })
            {
                flush()
                parts.append(
                    .task(
                        checked: trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)] != " ",
                        text: String(trimmed.dropFirst(6))))
                continue
            }
            let nsLine = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else {
                text.append(line)
                continue
            }
            let urlRange = match.range(at: match.range(at: 2).location == NSNotFound ? 3 : 2)
            guard let url = URL(string: nsLine.substring(with: urlRange)), url.host != nil else {
                text.append(line)
                continue
            }
            let altRange = match.range(at: 1)
            let alt = altRange.location == NSNotFound ? "Image" : nsLine.substring(with: altRange)
            flush()
            parts.append(.image(url, alt: alt.isEmpty ? "Image" : alt))
        }
        flush()
        return parts
    }
}

struct PullRequestDescription: View {
    let markdown: String
    var html: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(
                Array(
                    PullRequestDescriptionContent.parts(
                        PullRequestDescriptionContent.resolvingImages(markdown, html: html)
                    ).enumerated()), id: \.offset
            ) { _, part in
                switch part {
                case .markdown(let text):
                    MarkdownMessageView(markdown: text)
                case .task(let checked, let text):
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .accessibilityLabel(checked ? "Completed" : "Not completed")
                        MarkdownMessageView(markdown: text)
                    }
                case .divider:
                    Color.dockBorderLight.frame(height: DockLayout.hairline)
                case .image(let url, let alt):
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit().accessibilityLabel(alt)
                        } else if phase.error != nil {
                            Link("Image unavailable: \(alt)", destination: url).buttonStyle(.dockLink)
                        } else {
                            ProgressView().accessibilityLabel("Loading \(alt)")
                        }
                    }
                }
            }
        }
    }
}
