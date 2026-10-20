import Testing

@testable import Herm

struct LocalServerDiscoveryTests {
    @Test func processNamesAndIPv6DestinationsStayLocal() {
        let servers = LocalServerDiscovery.parse("p42\ncnode\nn[::1]:3000", owned: [42])
        #expect(servers.first?.processName == "node")
        #expect(servers.first?.url.absoluteString == "http://[::1]:3000")
    }
    @Test func onlyOwnedProcessesAndTheirDescendantsAreEligible() {
        let owned = LocalServerDiscovery.descendants(roots: [10], processTable: "10 1\n11 10\n12 11\n20 1")
        #expect(owned == [10, 11, 12])
        let servers = LocalServerDiscovery.parse(
            "p12\nn127.0.0.1:3000\nn127.0.0.1:3000\nn192.168.1.5:4000\np20\nn*:8000\np11\nn[::1]:5000", owned: owned)
        #expect(servers.map(\.port) == [3000, 5000])
    }
}
