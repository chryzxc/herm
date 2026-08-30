import Foundation

/// Bounded appearance parity surface. The fixture schema is Dock-owned until
/// Hermes publishes a verified structured appearance contract.
public struct AppearanceService: Sendable {
    public static let fixtureSchema = "hermes.appearance.inventory.fixture.v1"
    private static let maxFixtureBytes = 64 * 1024

    public init() {}

    public func parseFixture(_ input: String) throws -> AppearanceInventory {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{", trimmed.last == "}" else { throw AppearanceParseError.unsupportedInput }
        guard let data = trimmed.data(using: .utf8), data.count <= Self.maxFixtureBytes else { throw AppearanceParseError.malformedFixture }
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else {
            throw AppearanceParseError.malformedFixture
        }
        if containsForbiddenData(root) { throw AppearanceParseError.unsupportedInput }
        let allowed = Set(["schema", "state", "activeSkinID", "skins", "pets", "desktopPlugins"])
        guard Set(root.keys).isSubset(of: allowed) else { throw AppearanceParseError.malformedFixture }
        do {
            let decoder = JSONDecoder()
            let inventory = try decoder.decode(AppearanceContract.self, from: data).inventory
            guard inventory.activeSkinID.map(safeLabel) ?? true else { throw AppearanceParseError.unsupportedInput }
            return inventory
        } catch AppearanceParseError.unsupportedInput { throw AppearanceParseError.unsupportedInput }
        catch { throw AppearanceParseError.malformedFixture }
    }

    public func operation(_ operation: AppearanceOperation, identifier: String, confirmed: Bool) -> AppearanceOperationResult {
        guard confirmed else { return .unavailable(.confirmationRequired) }
        guard !identifier.isEmpty, identifier.utf8.count <= 128 else { return .unavailable(.denied) }
        switch operation {
        case .reloadDesktopPlugin: return .unavailable(.unsupportedCommand)
        case .selectSkin, .selectPet, .enableDesktopPlugin, .disableDesktopPlugin:
            return .unavailable(.unverifiedContract)
        }
    }

    private func containsForbiddenData(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            let forbidden = Set(["token", "secret", "password", "authorization", "credential", "url", "command", "args", "env", "payload"])
            if !forbidden.isDisjoint(with: dictionary.keys.map { $0.lowercased() }) { return true }
            return dictionary.values.contains { containsForbiddenData($0) }
        }
        if let array = value as? [Any] { return array.contains { containsForbiddenData($0) } }
        if let string = value as? String {
            let lower = string.lowercased()
            return lower.contains("http://") || lower.contains("https://") || lower.contains("bearer ") || lower.contains("api_key") || lower.contains("password=") || lower.contains("secret=")
        }
        return false
    }

    private struct AppearanceContract: Decodable {
        let schema: String
        let state: AppearanceInventoryState
        let activeSkinID: String?
        let skins: [AppearanceSkinContract]
        let pets: [AppearancePetContract]
        let desktopPlugins: [DesktopPluginContract]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            guard container.allKeys.count == Keys.allCases.count else { throw AppearanceParseError.malformedFixture }
            schema = try container.decode(String.self, forKey: .schema)
            guard schema == AppearanceService.fixtureSchema else { throw AppearanceParseError.unsupportedInput }
            state = try container.decode(AppearanceInventoryState.self, forKey: .state)
            activeSkinID = try container.decodeIfPresent(String.self, forKey: .activeSkinID)
            skins = try container.decode([AppearanceSkinContract].self, forKey: .skins)
            pets = try container.decode([AppearancePetContract].self, forKey: .pets)
            desktopPlugins = try container.decode([DesktopPluginContract].self, forKey: .desktopPlugins)
        }

        var inventory: AppearanceInventory {
            AppearanceInventory(state: state, activeSkinID: activeSkinID, skins: skins.map(\.value), pets: pets.map(\.value), desktopPlugins: desktopPlugins.map(\.value))
        }

        enum Keys: String, CodingKey, CaseIterable { case schema, state, activeSkinID, skins, pets, desktopPlugins }
    }

    private struct AppearanceSkinContract: Decodable {
        let value: AppearanceSkin
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            guard Set(c.allKeys.map(\.stringValue)) == Set(Keys.allCases.map(\.stringValue)) else { throw AppearanceParseError.malformedFixture }
            let id = try c.decode(String.self, forKey: AnyCodingKey("id")); let name = try c.decode(String.self, forKey: AnyCodingKey("name"))
            guard safeLabel(id), safeLabel(name) else { throw AppearanceParseError.unsupportedInput }
            value = AppearanceSkin(id: id, name: name, isActive: try c.decode(Bool.self, forKey: AnyCodingKey("active")))
        }
        enum Keys: String, CodingKey, CaseIterable { case id, name, active }
    }

    private struct AppearancePetContract: Decodable {
        let value: AppearancePet
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            guard Set(c.allKeys.map(\.stringValue)) == Set(Keys.allCases.map(\.stringValue)) else { throw AppearanceParseError.malformedFixture }
            let id = try c.decode(String.self, forKey: AnyCodingKey("id")); let name = try c.decode(String.self, forKey: AnyCodingKey("name"))
            guard safeLabel(id), safeLabel(name) else { throw AppearanceParseError.unsupportedInput }
            value = AppearancePet(id: id, name: name, isActive: try c.decode(Bool.self, forKey: AnyCodingKey("active")))
        }
        enum Keys: String, CodingKey, CaseIterable { case id, name, active }
    }

    private struct DesktopPluginContract: Decodable {
        let value: DesktopPluginInventory
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            guard Set(c.allKeys.map(\.stringValue)) == Set(Keys.allCases.map(\.stringValue)) else { throw AppearanceParseError.malformedFixture }
            let id = try c.decode(String.self, forKey: AnyCodingKey("id")); let name = try c.decode(String.self, forKey: AnyCodingKey("name"))
            guard safeLabel(id), safeLabel(name) else { throw AppearanceParseError.unsupportedInput }
            value = DesktopPluginInventory(id: id, name: name, mode: try c.decode(DesktopPluginMode.self, forKey: AnyCodingKey("mode")), status: try c.decode(DesktopPluginStatus.self, forKey: AnyCodingKey("status")))
        }
        enum Keys: String, CodingKey, CaseIterable { case id, name, mode, status }
    }
}

private struct AnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}

private func safeLabel(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) && !["password=", "secret=", "token=", "api_key="].contains(where: value.lowercased().contains)
}
