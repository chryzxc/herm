import Foundation
import Testing

@testable import Herm

private struct LabelColorTransport: GitHubIssueTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let labels: [[String: Any]] = [
            ["node_id": "BUG", "name": "bug", "color": "d73a4a"], ["node_id": "FIX", "name": "fix", "color": "0E8A16"],
            ["name": "legacy"],
        ]
        let payload: Any = request.url!.path.hasSuffix("/labels") ? labels : ["labels": labels]
        return (
            try JSONSerialization.data(withJSONObject: payload),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
struct GitHubLabelColorTests {
    @Test func labelColorsSurviveDetailAndCatalogParsing() async throws {
        let service = GitHubMetadataService(client: GitHubClient(transport: LabelColorTransport()))
        let ref = GitHubItemReference(
            repository: GitHubReferenceParser.repository("owner/repo")!, number: 1, kind: .issue)
        let details = try await service.basic(ref)
        let choices = try await service.labels(ref)
        #expect(details.labels.map(\.color) == ["d73a4a", "0E8A16", nil])
        #expect(choices.map(\.color) == details.labels.map(\.color))
    }
    @Test(arguments: ["000000", "ffffff", "d73a4a", "0E8A16", "#fbca04", "808080", "5319e7"])
    func providerColorsHaveReadableInk(hex: String) throws {
        let color = try #require(DockMetadataPillColor(hex: hex))
        #expect(color.contrastRatio >= 4.5)
        if hex == "000000" { #expect(color.usesWhiteText) }
        if hex == "ffffff" { #expect(!color.usesWhiteText) }
    }
    @Test(arguments: ["", "fff", "#xyzxyz", "12345678", " 123456", "##ffffff"])
    func malformedColorsFallBackToTheTheme(hex: String) {
        #expect(DockMetadataPillColor(hex: hex) == nil)
    }
}
