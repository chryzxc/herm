import CryptoKit
import Foundation
import Security

enum HermUpdateTrust {
    private struct Failure: LocalizedError { let errorDescription: String? }
    static func publisherRequirement(team: String) throws -> SecRequirement {
        guard team.count == 10, team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
            throw Failure(errorDescription: "Automatic updates require a Developer ID signed Herm release.")
        }
        let expression =
            "anchor apple generic and identifier \"io.github.chryzxc.Herm\" and "
            + "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else { throw CocoaError(.coderInvalidValue) }
        return requirement
    }

    /// Only an ad-hoc signature may use the pinned archive key as its sole publisher check.
    static func updatePublisher(of app: URL) throws -> SecRequirement? {
        let code = try staticCode(app)
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess
        else {
            throw Failure(
                errorDescription:
                    "The installed Herm signature could not be read. Install a trusted release manually."
            )
        }
        let values = information as? [String: Any]
        if values?[kSecCodeInfoCertificates as String] == nil,
            (values?[kSecCodeInfoCMS as String] as? Data)?.isEmpty != false
        {
            try verify(code, requirement: nil)
            return nil
        }
        guard let team = values?[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw Failure(errorDescription: "The installed Herm publisher could not be verified.")
        }
        let requirement = try publisherRequirement(team: team)
        try verify(code, requirement: requirement)
        return requirement
    }

    static func verify(_ app: URL, requirement: SecRequirement?) throws {
        try verify(staticCode(app), requirement: requirement)
    }

    private static func staticCode(_ app: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return code
    }

    private static func verify(_ code: SecStaticCode, requirement: SecRequirement?) throws {
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw Failure(
                errorDescription:
                    "The update's signature does not match this Herm publisher. Install a trusted release manually.")
        }
    }

    static func verifyArchive(_ data: Data, signature: Data, publicKey: String) throws {
        guard let rawKey = Data(base64Encoded: publicKey),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
            let rawSignature = Data(base64Encoded: signature),
            key.isValidSignature(rawSignature, for: data)
        else { throw Failure(errorDescription: "The update's signing-key signature is missing or invalid.") }
    }

    static func expectedDigest(_ digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let value = String(digest.dropFirst(7)).lowercased()
        return value.count == 64 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            ? value : nil
    }
}
