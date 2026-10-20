import CryptoKit
import Foundation

/// Bounded presentation cache; canonical messages remain in Hermes.
actor RichDocumentCache {
    static let shared = RichDocumentCache()
    private var documents: [String: RichDocument] = [:]
    private var order: [String] = []

    func document(_ text: String, identity: String, streaming: Bool) -> RichDocument {
        let revision = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = identity + ":" + revision
        if !streaming, let cached = documents[key] { return cached }
        let parsed = RichDocument(text, streaming: streaming)
        if !streaming, text.utf8.count <= 2 * RichDocument.maximumBytes {
            documents[key] = parsed
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > 8 { documents[order.removeFirst()] = nil }
        }
        return parsed
    }
}
