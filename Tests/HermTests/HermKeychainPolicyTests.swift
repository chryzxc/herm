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
}
