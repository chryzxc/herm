import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct HermesCapabilityServiceTests {
    @Test func shellAvailabilityRequiresSuccessfulExitCode() {
        #expect(HermesCapabilityService.shellResultSucceeded(["code": 0, "stdout": "memo 1.0"]) == true)
        #expect(HermesCapabilityService.shellResultSucceeded(["code": 127, "stderr": "command not found"]) == false)
        #expect(HermesCapabilityService.shellResultSucceeded(nil) == false)
    }
}
