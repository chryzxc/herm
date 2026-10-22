import SwiftUI

/// Client-side reply: Hermes has no reply-to field, so the quote travels as a
/// leading `> ↩ Author: snippet` line of the message text. It is persisted with
/// the text, so history rehydrates it with no extra state.
struct ReplyQuote: Equatable {
    let author: String
    let snippet: String

    private static let marker = "> ↩ "
    private static let snippetLimit = 140

    init(author: String, text: String) {
        self.author = author
        let flat = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        self.snippet = flat.count > Self.snippetLimit ? String(flat.prefix(Self.snippetLimit)) + "…" : flat
    }

    private init(author: String, snippet: String) {
        self.author = author
        self.snippet = snippet
    }

    func composing(_ body: String) -> String { "\(Self.marker)\(author): \(snippet)\n\n\(body)" }

    /// The quote and remaining body when `text` starts with a reply line.
    static func split(_ text: String) -> (quote: ReplyQuote, body: String)? {
        guard text.hasPrefix(marker), let lineEnd = text.firstIndex(of: "\n") else { return nil }
        let line = text[text.index(text.startIndex, offsetBy: marker.count)..<lineEnd]
        guard let colon = line.range(of: ": ") else { return nil }
        let body = text[lineEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (ReplyQuote(author: String(line[..<colon.lowerBound]), snippet: String(line[colon.upperBound...])), body)
    }
}

/// The quoted message: an accent bar, author and snippet; `onDismiss` adds the composer's close button.
struct ReplyQuoteChip: View {
    let quote: ReplyQuote
    var showsAuthor = true
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.dockAccent).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                if showsAuthor { Text(quote.author).dockFont(size: 11, weight: .semibold).foregroundStyle(Color.dockAccent) }
                Text(quote.snippet).dockFont(size: 12).foregroundStyle(Color.dockSecondaryText).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    DockIcon(.x, size: 11, color: .dockSecondaryText).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                    .help("Cancel reply")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
