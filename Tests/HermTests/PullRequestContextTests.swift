import Foundation
import Testing

@testable import Herm

actor ContextTransport: GitHubIssueTransport {
    enum Mode: Sendable { case normal, changed, mismatched }
    let mode: Mode
    private var reads = 0
    private var refs: [String] = []
    init(_ mode: Mode) { self.mode = mode }
    func references() -> [String] { refs }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        let payload: [String: Any]
        let head = String(repeating: "a", count: 40)
        let base = String(repeating: "b", count: 40)
        let merge = String(repeating: "c", count: 40)
        if path.hasSuffix("/pulls/1") {
            reads += 1
            payload = [
                "head": ["sha": mode == .changed && reads > 1 ? String(repeating: "d", count: 40) : head],
                "base": ["sha": base],
            ]
        } else if path.contains("/compare/") {
            payload = ["merge_base_commit": ["sha": merge]]
        } else {
            let reference =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first {
                    $0.name == "ref"
                }?.value ?? ""
            refs.append(reference)
            let text =
                path.hasSuffix("old.swift")
                ? (mode == .mismatched ? "before\nstale\nafter\n" : "before\nold\nafter\n") : "before\nnew\nafter\n"
            payload = [
                "type": "file", "size": text.utf8.count, "encoding": "base64",
                "content": Data(text.utf8).base64EncodedString(),
            ]
        }
        return (
            try JSONSerialization.data(withJSONObject: payload),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

struct PullRequestContextTests {
    private func record() -> PullRequestRecord {
        var record = PullRequestCenterAPI().parse(
            ["number": 1, "title": "Fixture", "head": ["sha": String(repeating: "a", count: 40)]],
            repository: GitHubReferenceParser.repository("owner/repo")!, localPath: "")!
        record.baseRevision = String(repeating: "b", count: 40)
        return record
    }
    private var file: PullRequestFile {
        PullRequestFile(
            path: "new.swift", status: "renamed", additions: 1, deletions: 1, patch: "@@ -2 +2 @@\n-old\n+new",
            webURL: nil, previousPath: "old.swift")
    }
    @Test func expansionReadsImmutableMergeBaseAndHead() async throws {
        let transport = ContextTransport(.normal)
        let result = try await PullRequestContextService(client: GitHubClient(transport: transport)).expand(
            record: record(), file: file, patch: file.patch!, lines: 23)
        #expect(result == "@@ -1,3 +1,3 @@\n before\n-old\n+new\n after")
        #expect(
            Set(await transport.references()) == [String(repeating: "a", count: 40), String(repeating: "c", count: 40)])
    }
    @Test(arguments: [ContextTransport.Mode.changed, .mismatched])
    func rejectsMovingHeadOrUnprovenSource(mode: ContextTransport.Mode) async {
        let service = PullRequestContextService(client: GitHubClient(transport: ContextTransport(mode)))
        await #expect(throws: (any Error).self) {
            try await service.expand(record: record(), file: file, patch: file.patch!, lines: 23)
        }
    }
}
