#!/usr/bin/env swift
import CryptoKit
import Foundation
import Security

// The private key stays in Keychain locally and in an Actions secret on GitHub.
let signingService = "io.github.chryzxc.Herm.update-signing"
let signingQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: signingService,
    kSecAttrAccount as String: "ed25519",
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func storedKey() throws -> Curve25519.Signing.PrivateKey {
    var query = signingQuery
    query[kSecReturnData as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data {
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }
    guard status == errSecItemNotFound else { fail("Could not read update signing key from Keychain (\(status)).") }
    let key = Curve25519.Signing.PrivateKey()
    var item = signingQuery
    item[kSecValueData as String] = key.rawRepresentation
    let added = SecItemAdd(item as CFDictionary, nil)
    guard added == errSecSuccess else { fail("Could not save update signing key to Keychain (\(added)).") }
    return key
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "setup", arguments.count == 2 {
        let key = try storedKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        if let pinned = NSDictionary(contentsOfFile: "Sources/Herm/Info.plist")?["HermUpdatePublicKey"] as? String,
            pinned != publicKey
        {
            fail("This Keychain has a different signing key. Refusing to replace the release secret.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "secret", "set", "HERM_UPDATE_PRIVATE_KEY", "--repo", arguments[1]]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(key.rawRepresentation.base64EncodedString().utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { fail("Could not configure the GitHub signing secret.") }
        print("Public key: \(publicKey)")
    } else if arguments.first == "sign", arguments.count == 2 {
        guard let encoded = ProcessInfo.processInfo.environment["HERM_UPDATE_PRIVATE_KEY"],
            let raw = Data(base64Encoded: encoded)
        else { fail("HERM_UPDATE_PRIVATE_KEY is missing or invalid; refusing to publish an unsigned update.") }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        let plist = NSDictionary(contentsOfFile: "Sources/Herm/Info.plist")
        guard key.publicKey.rawRepresentation.base64EncodedString() == plist?["HermUpdatePublicKey"] as? String else {
            fail("The signing secret does not match Herm's pinned update key.")
        }
        let url = URL(fileURLWithPath: arguments[1])
        let signature = try key.signature(for: Data(contentsOf: url, options: .mappedIfSafe))
        try Data(signature.base64EncodedString().utf8).write(to: url.appendingPathExtension("sig"))
        print("Signed \(url.lastPathComponent).")
    } else {
        fail("Usage: swift Scripts/sign-update.swift setup OWNER/REPO | sign PATH_TO_DMG")
    }
} catch {
    // Do not print external error payloads from signing or credential operations.
    fail("Update signing failed. Check the key configuration and file permissions.")
}
