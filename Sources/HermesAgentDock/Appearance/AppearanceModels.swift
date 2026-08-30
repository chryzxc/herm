import Foundation

public enum AppearanceInventoryState: String, Codable, CaseIterable, Equatable, Sendable {
    case ready, unavailable, unsupported, malformed, stale
}

public struct AppearanceSkin: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isActive: Bool

    public init(id: String, name: String, isActive: Bool) {
        self.id = id; self.name = name; self.isActive = isActive
    }
}

public struct AppearancePet: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isActive: Bool

    public init(id: String, name: String, isActive: Bool) {
        self.id = id; self.name = name; self.isActive = isActive
    }
}

public enum DesktopPluginMode: String, Codable, CaseIterable, Equatable, Sendable {
    case standalone, unified
}

public enum DesktopPluginStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case enabled, disabled, error, unavailable
}

public struct DesktopPluginInventory: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let mode: DesktopPluginMode
    public let status: DesktopPluginStatus

    public init(id: String, name: String, mode: DesktopPluginMode, status: DesktopPluginStatus) {
        self.id = id; self.name = name; self.mode = mode; self.status = status
    }
}

public struct AppearanceInventory: Codable, Equatable, Sendable {
    public let state: AppearanceInventoryState
    public let activeSkinID: String?
    public let skins: [AppearanceSkin]
    public let pets: [AppearancePet]
    public let desktopPlugins: [DesktopPluginInventory]

    public init(state: AppearanceInventoryState, activeSkinID: String?, skins: [AppearanceSkin], pets: [AppearancePet], desktopPlugins: [DesktopPluginInventory]) {
        self.state = state; self.activeSkinID = activeSkinID; self.skins = skins; self.pets = pets; self.desktopPlugins = desktopPlugins
    }
}

public enum AppearanceOperation: CaseIterable, Sendable {
    case selectSkin, selectPet, enableDesktopPlugin, disableDesktopPlugin, reloadDesktopPlugin
}

public enum AppearanceUnavailableReason: Equatable, Sendable {
    case confirmationRequired, unverifiedContract, unsupportedCommand, denied
}

public enum AppearanceOperationResult: Equatable, Sendable {
    case unavailable(AppearanceUnavailableReason)
}

public enum AppearanceParseError: Error, Equatable, Sendable {
    case unsupportedInput
    case malformedFixture
}
