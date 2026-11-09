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

    /// GitHub renders inline HTML (Dependabot release notes are almost all `<details>`, `<p>`, `<ul>`);
    /// the Markdown view does not, so the common tags become Markdown and the rest are dropped.
    /// `<img>` is kept for `parts`. Fenced code is left untouched.
    /// ponytail: regex rewrite, no nesting (nested lists flatten, blockquotes lose their bar);
    /// swap for a real HTML parser if bodies need tables or nested structure.
    static func markdownFromHTML(_ source: String) -> String {
        var output: [String] = []
        var segment: [String] = []
        var fence: MarkdownFence?
        func convert() {
            guard !segment.isEmpty else { return }
            var text = segment.joined(separator: "\n")
            segment.removeAll()
            func replace(_ pattern: String, _ template: String) {
                text = text.replacingOccurrences(
                    of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
            }
            replace(#"<pre[^>]*>\s*(?:<code[^>]*>)?([\s\S]*?)(?:</code>)?\s*</pre>"#, "\n```\n$1\n```\n")
            replace(#"<summary[^>]*>([\s\S]*?)</summary>"#, "\n**$1**\n")
            for level in 1...6 {
                replace(
                    #"<h\#(level)[^>]*>([\s\S]*?)</h\#(level)>"#, "\n" + String(repeating: "#", count: level) + " $1\n")
            }
            replace(#"<(strong|b)>([\s\S]*?)</\1>"#, "**$2**")
            replace(#"<(em|i)>([\s\S]*?)</\1>"#, "*$2*")
            replace(#"<code>([\s\S]*?)</code>"#, "`$1`")
            replace(#"<a\b[^>]*?href=["']([^"']+)["'][^>]*>((?:(?!<img)[\s\S])*?)</a>"#, "[$2]($1)")
            replace(#"<li[^>]*>\s*"#, "\n- ")
            replace(#"<br\s*/?>"#, "  \n")
            replace(#"<hr\s*/?>"#, "\n---\n")
            replace(#"</p>"#, "\n\n")
            replace(
                #"</?(?:p|div|span|details|blockquote|ul|ol|li|table|thead|tbody|tr|td|th|sup|sub|picture|source|kbd)\b[^>]*>"#,
                "")
            for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")]
            {
                text = text.replacingOccurrences(of: entity, with: character)
            }
            replace(#"\n[ \t]*\n(?:[ \t]*\n)+"#, "\n\n")
            output.append(text)
        }
        for line in source.components(separatedBy: "\n") {
            if let active = fence {
                output.append(line)
                if active.isClosed(by: line) { fence = nil }
            } else if let opening = MarkdownFence(opening: line) {
                convert()
                fence = opening
                output.append(line)
            } else {
                segment.append(line)
            }
        }
        convert()
        return output.joined(separator: "\n")
    }

    static func parts(_ source: String) -> [Part] {
        // Images anywhere in a line (badges, `<a><img></a>`, several per line), not only whole-line ones.
        let url = #"<?(https?://[^\s)>]+)>?"#
        let mdImage = #"!\[([^\]]*)\]\(\s*"# + url + #"(?:\s+\"[^\"]*\")?\s*\)"#
        let htmlImage = #"<img\b[^>]*?\bsrc=[\"'](https?://[^\"']+)[\"'][^>]*?/?>"#
        let pattern =
            #"(?:\["# + mdImage + #"\]\([^)]*\)|<a\b[^>]*>\s*"# + htmlImage + #"\s*</a>|"# + mdImage + "|" + htmlImage
            + ")"
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
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            var cursor = 0
            var images: [(NSRange, URL, String)] = []
            for match in matches {
                // Groups: linked md (1,2) | linked html (3) | md (4,5) | html (6).
                let groups = [(1, 2), (4, 5)].compactMap { alt, url -> (Int, Int)? in
                    match.range(at: url).location == NSNotFound ? nil : (alt, url)
                }
                let urlRange: NSRange
                var alt = "Image"
                if let (altGroup, urlGroup) = groups.first {
                    urlRange = match.range(at: urlGroup)
                    let range = match.range(at: altGroup)
                    if range.length > 0 { alt = nsLine.substring(with: range) }
                } else {
                    urlRange = match.range(at: match.range(at: 3).location == NSNotFound ? 6 : 3)
                }
                guard urlRange.location != NSNotFound, let url = URL(string: nsLine.substring(with: urlRange)),
                    url.host != nil
                else { continue }
                images.append((match.range, url, alt))
            }
            if images.isEmpty {
                text.append(line)
                continue
            }
            for (range, url, alt) in images {
                let before = nsLine.substring(with: NSRange(location: cursor, length: range.location - cursor))
                if !before.trimmingCharacters(in: .whitespaces).isEmpty { text.append(before) }
                flush()
                parts.append(.image(url, alt: alt))
                cursor = range.location + range.length
            }
            let rest = nsLine.substring(from: cursor)
            if !rest.trimmingCharacters(in: .whitespaces).isEmpty { text.append(rest) }
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
                        PullRequestDescriptionContent.markdownFromHTML(
                            PullRequestDescriptionContent.resolvingImages(markdown, html: html))
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
