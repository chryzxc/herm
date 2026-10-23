import Foundation
import Testing

@testable import Herm

struct AttachmentPayloadTests {
    @Test func encodingPreservesBytesAndRevalidatesTheSizeOnEachRead() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data([0, 1, 2, 127, 128, 255])
        try data.write(to: url)
        let encoded = try await AttachmentPayload.encoded(at: url, maximumBytes: data.count)
        #expect(Data(base64Encoded: encoded) == data)
        try (data + Data([1])).write(to: url)
        await #expect(throws: HermesGateway.GatewayError.self) {
            try await AttachmentPayload.encoded(at: url, maximumBytes: data.count)
        }
        try FileManager.default.removeItem(at: url)
        await #expect(throws: (any Error).self) { try await AttachmentPayload.encoded(at: url) }
    }
}
