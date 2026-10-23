import Foundation
import Testing

@testable import Herm

struct ConfigurationServiceTests {
    private let validJSON =
        #"{"schema":"hermes.configuration.health.v1","providers":[{"id":"openai","state":"ready"}],"models":[{"id":"gpt-5","state":"ready"}],"routing":{"state":"ready","fallbackCount":1},"credentials":[{"provider":"openai","present":true}]}"#

    @Test func parsesVerifiedRedactedJSONWithoutSecrets() throws {
        let result = try ConfigurationService.parseVerifiedJSON(validJSON)

        #expect(result.state == .ready)
        #expect(result.providers == [ProviderHealth(id: "openai", state: .ready)])
        #expect(result.models == [ModelAvailability(id: "gpt-5", state: .ready)])
        #expect(result.routing == RoutingHealth(state: .ready, fallbackCount: 1))
        #expect(result.credentials == [CredentialPresence(provider: "openai", present: true)])
        #expect(!String(describing: result).contains("api_key"))
    }

    @Test func malformedAndHumanOutputAreUnsupportedOrMalformedWithoutRawDiagnostics() {
        let malformed = ConfigurationService.parse("{\"schema\":", format: .json)
        let table = ConfigurationService.parse("Provider Model Status\nopenai gpt-5 ready", format: .humanTable)
        let yaml = ConfigurationService.parse("providers:\n  - id: openai", format: .yaml)

        #expect(malformed.state == .malformed)
        #expect(table.state == .unsupported)
        #expect(yaml.state == .unsupported)
        #expect(malformed.diagnostic == "Configuration health output was malformed.")
        #expect(!malformed.diagnostic.contains("schema"))
    }

    @Test func missingAndDeniedCapabilitiesAreUnavailable() {
        #expect(ConfigurationService.unavailable(capability: .missing).state == .unavailable)
        #expect(ConfigurationService.unavailable(capability: .denied).state == .unavailable)
        #expect(
            ConfigurationService.unavailable(capability: .missing).diagnostic
                == "Configuration health capability is unavailable.")
    }

    @Test func oldSnapshotIsStaleButRetainsSafeRedactedRows() throws {
        let result = try ConfigurationService.parseVerifiedJSON(
            validJSON,
            observedAt: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 120),
            maxAge: 10
        )

        #expect(result.state == .stale)
        #expect(result.providers.count == 1)
        #expect(result.credentials[0].present)
    }

    @Test func noLiveHermesAdapterIsClaimedForMutationRequests() {
        let result = ConfigurationService.mutationRequest(named: "set provider key")

        #expect(result == .unavailable)
    }

    @Test func secretBearingAndUnsafeFieldsNeverEnterModelsOrDiagnostics() {
        let json =
            #"{"schema":"hermes.configuration.health.v1","providers":[{"id":"https://user:token@example.com/key","state":"ready"}],"models":[{"id":"prompt: tell me a secret","state":"ready"}],"routing":{"state":"ready","fallbackCount":0},"credentials":[{"provider":"/Users/example/private","present":true}]}"#
        let result = ConfigurationService.parse(json, format: .json)
        let description = String(describing: result)

        #expect(result.state == .malformed)
        #expect(!description.contains("token"))
        #expect(!description.contains("example.com"))
        #expect(!description.contains("/Users"))
        #expect(!description.contains("prompt"))
    }

    @Test func rejectsURIAndPathSyntaxInEveryDurableIdentifierField() {
        let providerURI =
            #"{"schema":"hermes.configuration.health.v1","providers":[{"id":"provider:prod","state":"ready"}],"models":[{"id":"gpt-5","state":"ready"}],"routing":{"state":"ready","fallbackCount":0},"credentials":[{"provider":"openai","present":true}]}"#
        let modelPath =
            #"{"schema":"hermes.configuration.health.v1","providers":[{"id":"openai","state":"ready"}],"models":[{"id":"models/gpt-5","state":"ready"}],"routing":{"state":"ready","fallbackCount":0},"credentials":[{"provider":"openai","present":true}]}"#
        let credentialPath =
            #"{"schema":"hermes.configuration.health.v1","providers":[{"id":"openai","state":"ready"}],"models":[{"id":"gpt-5","state":"ready"}],"routing":{"state":"ready","fallbackCount":0},"credentials":[{"provider":"/private/provider","present":true}]}"#

        for json in [providerURI, modelPath, credentialPath] {
            let result = ConfigurationService.parse(json, format: .json)
            #expect(result.state == .malformed)
            #expect(result.providers.isEmpty)
            #expect(result.models.isEmpty)
            #expect(result.credentials.isEmpty)
        }
    }
}
