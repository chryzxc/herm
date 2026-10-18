import AppKit
import Vision

/// On-device OCR, so a screenshot's text can be sent to models that cannot see images.
enum ImageTextRecognizer {
    static func text(in image: NSImage) async -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            guard (try? VNImageRequestHandler(cgImage: cgImage).perform([request])) != nil else { return nil }
            return join(request.results?.compactMap { $0.topCandidates(1).first?.string } ?? [])
        }.value
    }

    /// Observations arrive top to bottom; one per line, blanks dropped, nil when nothing was read.
    static func join(_ lines: [String]) -> String? {
        let text = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
