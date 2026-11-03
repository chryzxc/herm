import Foundation
import Security
import Testing

@testable import Herm

struct HermKeychainPolicyTests {
    @Test func credentialPolicyTrustsThisApplicationRatherThanASharedHelper() throws {
        let migration = HermKeychain.serviceItems("io.github.chryzxc.Herm.gateway")
        #expect(migration[kSecAttrService as String] as? String == "io.github.chryzxc.Herm.gateway")
        #expect(migration[kSecAttrAccount as String] == nil)
        let access = try HermKeychain.access("Herm policy test")
        let acls = try #require(SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL])
        #expect(!acls.isEmpty)
        for acl in acls {
            var applications: CFArray?
            var label: CFString?
            var prompt = SecKeychainPromptSelector(rawValue: 0)
            #expect(SecACLCopyContents(acl, &applications, &label, &prompt) == errSecSuccess)
            let trusted = try #require(applications as? [SecTrustedApplication])
            #expect(trusted.count == 1)
            for application in trusted {
                var data: CFData?
                #expect(SecTrustedApplicationCopyData(application, &data) == errSecSuccess)
                let identity = String(decoding: try #require(data as Data?), as: UTF8.self)
                #expect(!identity.contains("/usr/bin/security"))
            }
        }
    }

    /// Only legacy helper-trusted items get their access rewritten; rewriting asks for the login password.
    @Test func onlyHelperTrustedAccessNeedsMigration() throws {
        var helper: SecTrustedApplication?
        #expect(SecTrustedApplicationCreateFromPath("/usr/bin/security", &helper) == errSecSuccess)
        var legacy: SecAccess?
        #expect(SecAccessCreate("Herm policy test" as CFString, [try #require(helper)] as CFArray, &legacy) == errSecSuccess)
        #expect(HermKeychain.trustedPaths(try #require(legacy)).contains { $0.contains("/usr/bin/security") })
        #expect(!HermKeychain.trustedPaths(try HermKeychain.access("Herm policy test")).contains { $0.contains("/usr/bin/security") })
    }
}
