import Testing

@testable import Herm

@MainActor
struct HermCommandRouterTests {
    private final class Owner {}

    private func handlers(_ label: String, into log: Log) -> HermCommandHandlers {
        let record = { log.entries.append(label) }
        return HermCommandHandlers(
            openSettings: record, openCommandPalette: record, goBack: record, goForward: record,
            newChat: record, stopGeneration: record, closeSession: record, toggleSidebar: record,
            toggleInspector: record, showShortcutList: record)
    }

    private final class Log { var entries: [String] = [] }

    @Test func dispatchesToTheWorkspaceInTheKeyWindow() {
        let first = Owner()
        let second = Owner()
        let log = Log()
        var key: AnyObject? = first
        let router = HermCommandRouter(keyOwner: { key })
        router.register(handlers("first", into: log), for: first)
        router.register(handlers("second", into: log), for: second)

        #expect(router.perform(.newChat))
        key = second
        #expect(router.perform(.newChat))
        #expect(log.entries == ["first", "second"])
    }

    @Test func fallsBackToTheNewestWorkspaceWhenTheKeyWindowHasNone() {
        let workspace = Owner()
        let settings = Owner()
        let log = Log()
        let router = HermCommandRouter(keyOwner: { settings })
        router.register(handlers("workspace", into: log), for: workspace)

        #expect(router.perform(.showShortcutList))
        #expect(log.entries == ["workspace"])
    }

    @Test func dropsWindowsThatWereUnregisteredOrReleased() {
        let log = Log()
        let router = HermCommandRouter(keyOwner: { nil })
        var released: Owner? = Owner()
        let closed = Owner()
        router.register(handlers("released", into: log), for: released!)
        router.register(handlers("closed", into: log), for: closed)
        router.unregister(closed)
        released = nil

        #expect(!router.perform(.commandPalette))
        #expect(log.entries.isEmpty)
    }
}
