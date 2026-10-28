import Foundation
import Security
import Testing

@testable import Herm

struct HermUpdateSecurityTests {
    @Test func updatesRequireACompleteDigestAndAPublisherBoundRequirement() throws {
        for value in [
            nil, "", "sha256:abc", "sha512:" + String(repeating: "a", count: 64),
            "sha256:" + String(repeating: "z", count: 64),
        ] {
            #expect(HermUpdateTrust.expectedDigest(value) == nil)
        }
        let digest = String(repeating: "AB", count: 32)
        #expect(HermUpdateTrust.expectedDigest("sha256:" + digest) == digest.lowercased())
        #expect(throws: (any Error).self) { try HermUpdateTrust.publisherRequirement(team: "") }
        #expect(throws: (any Error).self) { try HermUpdateTrust.publisherRequirement(team: "bad\" or true") }
        let requirement = try HermUpdateTrust.publisherRequirement(team: "ABC1234567")
        var expression: CFString?
        #expect(SecRequirementCopyString(requirement, [], &expression) == errSecSuccess)
        let text = try #require(expression as String?)
        #expect(text.contains("anchor apple generic"))
        #expect(text.contains("ABC1234567") && text.contains("io.github.chryzxc.Herm"))
        // Apple's own executable is signed, but is neither Herm nor this publisher.
        #expect(throws: (any Error).self) {
            try HermUpdateTrust.verify(URL(fileURLWithPath: "/usr/bin/true"), requirement: requirement)
        }
    }
}
