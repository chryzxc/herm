import Foundation

/// Bounded presentation cache; canonical messages remain in Hermes.
actor RichDocumentCache {
    static let shared = RichDocumentCache()
    private var documents: [String: RichDocument] = [:]
    private var order: [String] = []
    private var latestStream: (text: String, document: RichDocument)?
    private var closedSurfaces: [String: RichDocument.Segment] = [:]
    private var closedOrder: [String] = []

    func document(_ text: String, streaming: Bool) -> RichDocument {
        guard !Task.isCancelled else { return .preparing }
        if streaming, let latestStream, latestStream.text == text { return latestStream.document }
        if !streaming, let cached = documents[text] { return cached }

        let parsed = RichDocument(text, streaming: streaming, decodeClosedSurface: decodeSurface)
        if text.utf8.count <= 2 * RichDocument.maximumBytes {
            if streaming {
                latestStream = (text, parsed)
            } else {
                documents[text] = parsed
                order.append(text)
                while order.count > 8 { documents[order.removeFirst()] = nil }
            }
        }
        return parsed
    }

    /// Later prose can change the document without changing any already closed JSON.
    private func decodeSurface(_ source: String) -> RichDocument.Segment {
        if let cached = closedSurfaces[source] { return cached }
        let segment = RichDocument.decode(source)
        if case .surface = segment {
            closedSurfaces[source] = segment
            closedOrder.append(source)
            while closedOrder.count > 8 { closedSurfaces[closedOrder.removeFirst()] = nil }
        }
        return segment
    }
}
