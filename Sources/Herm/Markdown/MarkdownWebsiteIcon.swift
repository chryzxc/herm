import AppKit

@MainActor
enum MarkdownWebsiteIcon {
    static let didLoad = Notification.Name("herm.markdownWebsiteIconLoaded")

    final class PendingAttachment: NSTextAttachment {
        private(set) var isLoading = true

        @MainActor func complete(with image: NSImage?) {
            isLoading = false
            guard let image else { return }
            self.image = image
            NotificationCenter.default.post(name: MarkdownWebsiteIcon.didLoad, object: self)
        }
    }

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()
    private final class Load {
        let task: Task<NSImage?, Never>
        init(_ task: Task<NSImage?, Never>) { self.task = task }
    }
    private static let loads: NSCache<NSString, Load> = {
        let cache = NSCache<NSString, Load>()
        cache.countLimit = 256
        return cache
    }()
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    static func host(for url: URL) -> String? {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        return host
    }

    static func label(_ text: String, for url: URL) -> String {
        guard host(for: url) == "github.com", text == url.absoluteString else { return text }
        let parts = url.path.split(separator: "/")
        guard parts.count == 4, parts[3].allSatisfy(\.isNumber), !parts[3].isEmpty else { return text }
        switch parts[2] {
        case "pull": return "PR #\(parts[3])"
        case "issues": return "Issue #\(parts[3])"
        default: return text
        }
    }

    static func attachment(for url: URL, size: CGFloat, color: NSColor) -> NSTextAttachment? {
        guard let host = host(for: url) else { return nil }
        let faviconURL = host == "github.com" ? nil : faviconURL(for: url)
        let cached = faviconURL.flatMap { _ in cache.object(forKey: host as NSString) }
        let attachment: NSTextAttachment = faviconURL != nil && cached == nil ? PendingAttachment() : NSTextAttachment()
        attachment.bounds = CGRect(x: 0, y: -2, width: size, height: size)
        // GitHub's bundled mark is crisp and follows the active theme, even offline.
        attachment.image =
            cached
            ?? (host == "github.com" ? Ph.githubLogo : Ph.globe).appKitMenuImage(size: size, color: color)
        guard let faviconURL, let pending = attachment as? PendingAttachment else { return attachment }
        let task: Task<NSImage?, Never>
        if let existing = loads.object(forKey: host as NSString) {
            task = existing.task
        } else {
            task = Task {
                var request = URLRequest(url: faviconURL)
                request.timeoutInterval = 5
                request.httpShouldHandleCookies = false
                guard let (bytes, response) = try? await session.bytes(for: request),
                    (response as? HTTPURLResponse)?.statusCode == 200
                else { return nil }
                var data = Data()
                do {
                    for try await byte in bytes {
                        guard data.count < 256 * 1024 else { return nil }
                        data.append(byte)
                    }
                } catch { return nil }
                guard let image = NSImage(data: data) else { return nil }
                cache.setObject(image, forKey: host as NSString)
                return image
            }
            loads.setObject(Load(task), forKey: host as NSString)
        }
        Task { [weak pending] in
            let image = await task.value
            pending?.complete(with: image)
        }
        return attachment
    }

    static func faviconURL(for url: URL) -> URL? {
        // shortcut: Use /favicon.ico; add HTML icon discovery when alternate icon paths are needed.
        guard let host = host(for: url), host.contains("."),
            !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
            !host.hasSuffix(".internal"),
            host.split(separator: ".").last?.contains(where: \.isLetter) == true,
            host.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0)
            })
        else { return nil }
        // Only the origin is sent; private paths, query strings and credentials stay local.
        return URL(string: "https://\(host)/favicon.ico")
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

@MainActor
extension NSTextView {
    func setMarkdownText(_ text: NSAttributedString) {
        let center = NotificationCenter.default
        center.removeObserver(self, name: MarkdownWebsiteIcon.didLoad, object: nil)
        textStorage?.setAttributedString(text)
        var observed: Set<ObjectIdentifier> = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let icon = value as? MarkdownWebsiteIcon.PendingAttachment, icon.isLoading,
                observed.insert(ObjectIdentifier(icon)).inserted
            else { return }
            center.addObserver(
                self, selector: #selector(markdownWebsiteIconDidLoad(_:)), name: MarkdownWebsiteIcon.didLoad,
                object: icon)
        }
    }

    @objc private func markdownWebsiteIconDidLoad(_ notification: Notification) {
        guard let icon = notification.object as? MarkdownWebsiteIcon.PendingAttachment, let textStorage else {
            return
        }
        NotificationCenter.default.removeObserver(self, name: MarkdownWebsiteIcon.didLoad, object: icon)
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) {
            value, range, _ in
            if value as? MarkdownWebsiteIcon.PendingAttachment === icon {
                layoutManager?.invalidateDisplay(forCharacterRange: range)
            }
        }
    }
}
