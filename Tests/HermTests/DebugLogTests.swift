import Testing
@testable import Herm

@MainActor
struct DebugLogTests {
    @Test func durableCategoriesNeverUseFreeFormMessages() {
        #expect(DebugLog.persistentEventName(for: "model: prompt=do not persist") == "model")
        #expect(DebugLog.persistentEventName(for: "unexpected secret=token") == "diagnostic")
    }

}
