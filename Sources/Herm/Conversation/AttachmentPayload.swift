import Foundation

enum AttachmentPayload {
    static func encoded(at url: URL, maximumBytes: Int? = nil) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            if let maximumBytes, data.count > maximumBytes {
                throw HermesGateway.GatewayError.imageAttachFailed("PDF attachments are limited to 25 MB.")
            }
            return data.base64EncodedString()
        }.value
    }
}
