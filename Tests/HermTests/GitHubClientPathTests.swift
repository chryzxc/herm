import Foundation
import Testing

@testable import Herm

struct GitHubClientPathTests {
    @Test(arguments: ["/repos/owner/repo/compare/aaaa...bbbb", "/repos/owner/repo/contents/file..swift"])
    func acceptsDotPunctuation(path: String) async throws {
        let transport = PathTransport()
        _ = try await GitHubClient(transport: transport).request(path)
        #expect(await transport.requests == 1)
    }

    @Test(arguments: [
        "/repos/owner/repo/../other", "/repos/owner/repo/%2e%2e/other", "/repos/owner/repo/%2E/other",
        "/repos/owner/repo/%5c..%5cother", "//other.example/path", "/repos/owner/repo?override=1",
        "/repos/owner/repo#fragment",
    ])
    func rejectsTraversalAndURLComponents(path: String) async {
        let transport = PathTransport()
        await #expect(throws: GitHubRequestError.malformed) {
            _ = try await GitHubClient(transport: transport).request(path)
        }
        #expect(await transport.requests == 0)
    }
}

private actor PathTransport: GitHubIssueTransport {
    private(set) var requests = 0
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        return (
            Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
