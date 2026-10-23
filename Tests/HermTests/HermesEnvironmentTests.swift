import Foundation
import Testing

@testable import Herm

struct HermesEnvironmentTests {
    @Test func prependsCurrentUsersLocalBin() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let environment = HermesEnvironment.processEnvironment(
            basedOn: ["PATH": "/usr/bin:/bin", "EXISTING": "value"],
            homeDirectory: home
        )

        #expect(environment["PATH"] == "/Users/example/.local/bin:/usr/bin:/bin")
        #expect(environment["EXISTING"] == "value")
    }

    @Test func doesNotDuplicateLocalBin() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let environment = HermesEnvironment.processEnvironment(
            basedOn: ["PATH": "/opt/bin:/Users/example/.local/bin:/usr/bin"],
            homeDirectory: home
        )

        #expect(environment["PATH"] == "/opt/bin:/Users/example/.local/bin:/usr/bin")
    }

    @Test func suppliesAUsableDefaultPath() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let environment = HermesEnvironment.processEnvironment(basedOn: [:], homeDirectory: home)

        #expect(environment["PATH"] == "/Users/example/.local/bin:/usr/local/bin:/usr/bin:/bin")
    }
}
