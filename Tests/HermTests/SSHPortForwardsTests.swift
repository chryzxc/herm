import Foundation
import Testing

@testable import Herm

struct SSHPortForwardsTests {
    @Test func onlySSHLoopbackURLsAreForwardedOnTheSamePort() {
        var backend = GatewayConnectionSettings()
        #expect(SSHPortForwards.remotePort(for: URL(string: "http://localhost:3000")!, backend: backend) == nil)
        backend.mode = .ssh
        backend.sshHost = "vps.example"
        let port = { SSHPortForwards.remotePort(for: URL(string: $0)!, backend: backend) }
        #expect(port("http://localhost:3000/app") == 3000)
        #expect(port("http://127.0.0.1:5173") == 5173)
        #expect(port("http://[::1]:8080") == 8080)
        #expect(port("http://app.localhost:4000") == 4000)
        #expect(port("http://localhost") == nil)
        #expect(port("https://example.com:3000") == nil)
    }

    @Test func tunnelHoldsItsSessionOnStdinAndFailsWhenThePortCannotBind() {
        var backend = GatewayConnectionSettings()
        backend.mode = .ssh
        backend.sshHost = "vps.example"
        backend.sshUser = "dev"
        let arguments = SSHPortForwards.arguments(port: 3000, backend: backend)
        #expect(arguments.starts(with: ["-T", "-o", "ExitOnForwardFailure=yes", "-L", "3000:localhost:3000"]))
        #expect(Array(arguments.suffix(3)) == ["--", "dev@vps.example", "cat"])
    }
}
