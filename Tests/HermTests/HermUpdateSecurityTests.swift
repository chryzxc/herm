import CryptoKit
import Foundation
import Security
import Testing

@testable import Herm

struct HermUpdateSecurityTests {
    @Test func archiveSignatureRejectsTamperingAndWrongPublishers() throws {
        let key = Curve25519.Signing.PrivateKey()
        let archive = Data("Herm update fixture".utf8)
        let signature = try key.signature(for: archive).base64EncodedData()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        try HermUpdateTrust.verifyArchive(archive, signature: signature, publicKey: publicKey)
        #expect(throws: (any Error).self) {
            try HermUpdateTrust.verifyArchive(archive + Data([0]), signature: signature, publicKey: publicKey)
        }
        #expect(throws: (any Error).self) {
            try HermUpdateTrust.verifyArchive(
                archive, signature: signature,
                publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())
        }
        for invalid in [Data(), Data("invalid".utf8), Data(repeating: 0, count: 88)] {
            #expect(throws: (any Error).self) {
                try HermUpdateTrust.verifyArchive(archive, signature: invalid, publicKey: publicKey)
            }
        }
        #expect(throws: (any Error).self) {
            try HermUpdateTrust.verifyArchive(archive, signature: signature, publicKey: "invalid")
        }
    }

    @Test func fallbackRequiresAnIntactAdHocCodeSignature() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("Herm")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", "--identifier", "io.github.chryzxc.Herm", executable.path]
        signer.standardError = FileHandle.nullDevice
        try signer.run()
        signer.waitUntilExit()
        #expect(signer.terminationStatus == 0)
        #expect(try HermUpdateTrust.updatePublisher(of: executable) == nil)
        try Data("corrupted".utf8).write(to: executable)
        #expect(throws: (any Error).self) { try HermUpdateTrust.updatePublisher(of: executable) }
    }

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
