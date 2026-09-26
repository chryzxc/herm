import Foundation
import Testing
@testable import Herm

struct MCPExtensionServiceTests {
    @Test func parsesOnlyTheDeclaredInventoryFixture() throws {
        let service = MCPExtensionService()
        let inventory = try service.parseFixture(#"{"schema":"hermes.extensions.inventory.fixture.v1","state":"ready","servers":[{"id":"time","name":"Time","status":"connected","capabilities":["tools"]}],"plugins":[{"id":"demo","name":"Demo","status":"enabled","capabilities":["commands"]}]}"#)

        #expect(inventory.state == .ready)
        #expect(inventory.servers.count == 1)
        #expect(inventory.servers[0].connection == .connected)
        #expect(inventory.plugins[0].status == .enabled)
        #expect(inventory.servers[0].capabilities == [.tools])
    }

    @Test func rejectsHumanTablesRawURLsCommandsHeadersEnvironmentSecretsAndToolPayloads() {
        let service = MCPExtensionService()
        let inputs = [
            "Name │ Status\ntime │ connected",
            "https://example.com/mcp",
            "npx -y server",
            #"{"schema":"hermes.extensions.inventory.fixture.v1","state":"ready","headers":{"Authorization":"Bearer secret"}}"#,
            #"{"schema":"hermes.extensions.inventory.fixture.v1","state":"ready","env":{"API_KEY":"secret"}}"#,
            #"{"schema":"hermes.extensions.inventory.fixture.v1","state":"ready","tool":{"name":"read_file","arguments":{"path":"/tmp/x"}}}"#
        ]

        for input in inputs {
            #expect(throws: MCPExtensionParseError.unsupportedInput) {
                try service.parseFixture(input)
            }
        }
    }

    @Test func rejectsMalformedAndUnknownFixtureFieldsWithoutRetainingInput() {
        let service = MCPExtensionService()
        #expect(throws: MCPExtensionParseError.malformedFixture) {
            try service.parseFixture(#"{"schema":"hermes.extensions.inventory.fixture.v1","state":"ready","servers":[{"id":"x","name":"X","status":"connected","unexpected":"secret"}],"plugins":[]}"#)
        }
        #expect(throws: MCPExtensionParseError.malformedFixture) {
            try service.parseFixture(#"{"schema":"hermes.extensions.inventory.fixture.v1","state":"ready","servers":[],"plugins":[{"id":"p","name":"P","status":"enabled","capabilities":["unknown"]}]}"#)
        }
    }

    @Test func rejectsMissingAndWrongFixtureSchema() {
        let service = MCPExtensionService()
        #expect(throws: MCPExtensionParseError.malformedFixture) {
            try service.parseFixture(#"{"schema":"hermes.extensions.inventory.fixture.v1","servers":[],"plugins":[]}"#)
        }
        #expect(throws: MCPExtensionParseError.unsupportedInput) {
            try service.parseFixture(#"{"schema":"hermes.extensions.inventory.v0","state":"ready","servers":[],"plugins":[]}"#)
        }
    }

    @Test func parsesEveryDeclaredInventoryState() throws {
        let service = MCPExtensionService()
        for state in MCPExtensionInventoryState.allCases {
            let input = "{\"schema\":\"hermes.extensions.inventory.fixture.v1\",\"state\":\"\(state.rawValue)\",\"servers\":[],\"plugins\":[]}"
            #expect(try service.parseFixture(input).state == state)
        }
    }

    @Test func rejectsUnsafeIdentifierAndLabelValuesInEveryRowKind() {
        let service = MCPExtensionService()
        let server = #"{"schema":"hermes.extensions.inventory.fixture.v1","state":"ready","servers":[{"id":"safe","name":"Safe","status":"connected","capabilities":[]}],"plugins":[]}"#
        let plugin = #"{"schema":"hermes.extensions.inventory.fixture.v1","state":"ready","servers":[],"plugins":[{"id":"safe","name":"Safe","status":"enabled","capabilities":[]}] }"#
        for value in [#""api_key=sk-live-secret""#, #""password=hunter2""#] {
            #expect(throws: MCPExtensionParseError.unsupportedInput) { try service.parseFixture(server.replacingOccurrences(of: #""id":"safe""#, with: #""id":\#(value)"#)) }
            #expect(throws: MCPExtensionParseError.unsupportedInput) { try service.parseFixture(server.replacingOccurrences(of: #""name":"Safe""#, with: #""name":\#(value)"#)) }
            #expect(throws: MCPExtensionParseError.unsupportedInput) { try service.parseFixture(plugin.replacingOccurrences(of: #""id":"safe""#, with: #""id":\#(value)"#)) }
            #expect(throws: MCPExtensionParseError.unsupportedInput) { try service.parseFixture(plugin.replacingOccurrences(of: #""name":"Safe""#, with: #""name":\#(value)"#)) }
        }
    }

    @Test func rejectsDuplicateKeysAtRootAndInRows() {
        let service = MCPExtensionService()
        #expect(throws: MCPExtensionParseError.malformedFixture) {
            try service.parseFixture(#"{"schema":"hermes.extensions.inventory.fixture.v1","state":"ready","state":"stale","servers":[],"plugins":[]}"#)
        }
        #expect(throws: MCPExtensionParseError.malformedFixture) {
            try service.parseFixture(#"{"schema":"hermes.extensions.inventory.fixture.v1","state":"ready","servers":[{"id":"x","name":"X","status":"connected","status":"failed","capabilities":[]}],"plugins":[]}"#)
        }
        #expect(throws: MCPExtensionParseError.malformedFixture) {
            try service.parseFixture(#"{"schema":"hermes.extensions.inventory.fixture.v1","state":"ready","st\u0061te":"stale","servers":[],"plugins":[]}"#)
        }
    }

    @Test func explicitUnavailableStatesCoverDeniedAndUnsupportedOperations() {
        let service = MCPExtensionService()
        #expect(service.operation(.addServer, name: "x") == .unavailable(.unverifiedContract))
        #expect(service.operation(.editServer, name: "x") == .unavailable(.unverifiedContract))
        #expect(service.operation(.removeServer, name: "x") == .unavailable(.unverifiedContract))
        #expect(service.operation(.enablePlugin, name: "p") == .unavailable(.unverifiedContract))
        #expect(service.operation(.disablePlugin, name: "p") == .unavailable(.unverifiedContract))
        #expect(service.operation(.reload, name: "x") == .unavailable(.unsupportedCommand))
        #expect(service.operation(.testConnection, name: "x") == .unavailable(.unverifiedContract))
    }

    @Test func unsupportedPluginValidationAndThirdPartyInvocationRemainUnavailable() {
        let service = MCPExtensionService()
        #expect(service.operation(.validatePlugin, name: "p") == .unavailable(.unverifiedContract))
        #expect(service.operation(.invokeThirdPartyTool, name: "read_file") == .unavailable(.upstreamBlocked))
    }

    @Test func operationAvailabilityIsExplicitlyReadOnlyUntilHermesContractExists() {
        let service = MCPExtensionService()
        for operation in MCPExtensionOperation.allCases {
            let result = service.operation(operation, name: "safe")
            switch operation {
            case .reload:
                #expect(result == .unavailable(.unsupportedCommand))
            case .invokeThirdPartyTool:
                #expect(result == .unavailable(.upstreamBlocked))
            default:
                #expect(result == .unavailable(.unverifiedContract))
            }
        }
    }

    @Test func confirmationCancellationDoesNotAttemptUnsupportedOperations() {
        let service = MCPExtensionService()
        #expect(service.operation(.addServer, name: "server", confirmed: false) == .unavailable(.confirmationRequired))
        #expect(service.operation(.invokeThirdPartyTool, name: "tool", confirmed: false) == .unavailable(.confirmationRequired))
    }

    @Test func inventorySummaryContainsOnlyBoundedSafeMetadata() throws {
        let service = MCPExtensionService()
        let inventory = try service.parseFixture(#"{"schema":"hermes.extensions.inventory.fixture.v1","state":"stale","servers":[{"id":"s","name":"Server","status":"failed","capabilities":["tools","platform"]}],"plugins":[{"id":"p","name":"Plugin","status":"disabled","capabilities":["commands"]}]}"#)
        #expect(inventory.safeSummary == "1 server · 1 plugin · stale")
        #expect(!inventory.safeSummary.contains("http"))
    }

    @Test func fixtureModelNeverRetainsSecretShapedValues() throws {
        let service = MCPExtensionService()
        let inventory = try service.parseFixture(#"{"schema":"hermes.extensions.inventory.fixture.v1","state":"ready","servers":[{"id":"safe","name":"Safe","status":"failed","capabilities":[]}],"plugins":[]}"#)
        #expect(inventory.servers.map(\.id) == ["safe"])
        #expect(!String(describing: inventory).contains("secret"))
        #expect(inventory.servers[0].connection == .failed)

        let denied = try service.parseFixture(#"{"schema":"hermes.extensions.inventory.fixture.v1","state":"ready","servers":[{"id":"denied","name":"Denied","status":"denied","capabilities":[]}],"plugins":[{"id":"blocked","name":"Blocked","status":"denied","capabilities":[]}] }"#)
        #expect(denied.servers[0].connection == .denied)
        #expect(denied.plugins[0].status == .denied)
    }
}
