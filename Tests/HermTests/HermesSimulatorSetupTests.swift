import Foundation
import Testing

@testable import Herm

@MainActor
struct HermesSimulatorSetupTests {
    @Test func setupOrderingAndFailure() async {
        let python = URL(fileURLWithPath: "/fixture/bin/python3")
        let root = URL(fileURLWithPath: "/fixture")
        let lock = URL(fileURLWithPath: "/fixture/requirements.lock")
        for (executable, results, expected, count) in [
            (false, [false], false, 1),
            (false, [true, true], true, 2),
            (true, [false, false], false, 2),
            (true, [false, true], true, 2),
        ] {
            var calls: [[String]] = []
            let success = await HermesSimulatorSetup.prepare(
                python: python, root: root, lock: lock, executable: executable
            ) { _, arguments, _ in
                calls.append(arguments)
                return results[calls.count - 1]
            }
            #expect(success == expected)
            #expect(calls.count == count)
            if calls.last?.contains("pip") == true {
                #expect(
                    calls.last == [
                        "-m", "pip", "--isolated", "install", "-q", "--disable-pip-version-check",
                        "--require-hashes", "--only-binary=:all:", "--index-url", "https://pypi.org/simple", "-r",
                        lock.path,
                    ])
            }
        }
    }
}
