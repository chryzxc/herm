import AppKit
import SwiftUI

/// The editor displays attachments; drafts keep one-character stable references.
@MainActor
enum InlineContextCodec {
    static func nextToken(excluding text: String) -> String? {
        (0xE000...0xF8FF).compactMap(UnicodeScalar.init).map { String($0) }.first { !text.contains($0) }
    }
    static func render(_ text: String, contexts: [ChatContext]) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: DockSkinPresentation.nativeFont(size: 14), .foregroundColor: NSColor(Color.dockPrimaryText),
            ])
        for context in contexts {
            guard let token = context.inlineToken else { continue }
            let source = result.string as NSString
            let range = source.range(of: token)
            guard range.location != NSNotFound else { continue }
            let attachment = InlineContextAttachment(context: context, token: token)
            result.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment))
        }
        return result
    }
    static func serialize(_ text: NSAttributedString) -> String {
        let result = NSMutableString(string: text.string)
        var replacements: [(NSRange, String)] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let attachment = value as? InlineContextAttachment { replacements.append((range, attachment.token)) }
        }
        for (range, token) in replacements.reversed() { result.replaceCharacters(in: range, with: token) }
        return result as String
    }
}

final class InlineContextAttachment: NSTextAttachment {
    let token: String
    init(context: ChatContext, token: String) {
        self.token = token
        super.init(data: nil, ofType: nil)
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let title = String(context.title.prefix(30)) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(Color.dockPrimaryText),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        let size = NSSize(width: min(240, title.size(withAttributes: attributes).width + 28), height: 24)
        image = NSImage(size: size, flipped: false) { rect in
            NSColor(Color.dockControlSurface).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
            title.draw(in: NSRect(x: 20, y: 5, width: size.width - 24, height: 16), withAttributes: attributes)
            Ph.paperclip.appKitMenuImage(size: 12, color: NSColor(Color.dockSecondaryText)).draw(
                in: NSRect(x: 5, y: 6, width: 12, height: 12))
            return true
        }
        image?.accessibilityDescription = context.title
        bounds = NSRect(x: 0, y: -5, width: size.width, height: size.height)
    }
    required init?(coder: NSCoder) {
        token = coder.decodeObject(forKey: "hermContextToken") as? String ?? ""
        super.init(coder: coder)
    }
    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(token, forKey: "hermContextToken")
    }
}

extension DockModel {
    func embedInlineContexts(previous: [ChatContext], caret: Int? = nil) {
        var text = draft
        var contexts = attachedContexts
        for removed in previous where !contexts.contains(where: { $0.id == removed.id }) {
            if let token = removed.inlineToken, !contexts.contains(where: { $0.inlineToken == token }) {
                text = text.replacingOccurrences(of: token, with: "")
            }
        }
        var position = min(caret ?? (text as NSString).length, (text as NSString).length)
        for index in contexts.indices {
            if contexts[index].inlineToken == nil {
                contexts[index].inlineToken = InlineContextCodec.nextToken(excluding: text)
            }
            if let token = contexts[index].inlineToken, !text.contains(token),
                !previous.contains(where: { $0.id == contexts[index].id && $0.inlineToken != nil })
            {
                let value = NSMutableString(string: text)
                value.insert(token, at: position)
                text = value as String
                position += 1
            }
        }
        if contexts != attachedContexts { attachedContexts = contexts }
        if draft != text { draft = text }
    }
    func removeDeletedInlineContexts() {
        let contexts = attachedContexts.filter { context in context.inlineToken.map { draft.contains($0) } ?? true }
        if contexts != attachedContexts { attachedContexts = contexts }
    }
    func restoreCapturedText(_ text: String, contexts: [ChatContext]) {
        var used = draft
        var restored = contexts
        var tokens: [String: String] = [:]
        for index in restored.indices {
            if let old = restored[index].inlineToken, let replacement = InlineContextCodec.nextToken(excluding: used) {
                tokens[old] = replacement
                restored[index].inlineToken = replacement
                used += replacement
            }
        }
        stageDraft(text.map { tokens[String($0)] ?? String($0) }.joined())
        attachedContexts += restored
    }
}
