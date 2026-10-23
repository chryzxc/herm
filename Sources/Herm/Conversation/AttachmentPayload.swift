import Foundation

enum AttachmentPayload {
    static func encoded(at url: URL, maximumBytes: Int? = nil) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let maximumBytes,
               let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumBytes {
                throw HermesGateway.GatewayError.imageAttachFailed("The attachment exceeds its size limit (\(maximumBytes) bytes).")
            }
            let data = try Data(contentsOf: url)
            if let maximumBytes, data.count > maximumBytes {
                throw HermesGateway.GatewayError.imageAttachFailed("The attachment exceeds its size limit (\(maximumBytes) bytes).")
            }
            return data.base64EncodedString()
        }.value
    }
}
