import Combine
import Foundation

struct SessionSimulatorLaunch: Decodable, Equatable {
    let schema: String
    let status: String
    let platform: String
    let deviceID: String
    let deviceName: String
    let host: String

    enum CodingKeys: String, CodingKey {
        case schema, status, platform, host
        case deviceID = "device_id"
        case deviceName = "device_name"
    }

    var target: SessionSimulatorPlatform? { SessionSimulatorPlatform(rawValue: platform) }

    static func receipt(tool: String, result: String, isError: Bool, localHost: String) -> Self? {
        guard tool == "herm_simulator", !isError, result.utf8.count < 16_384,
            let data = result.data(using: .utf8), let value = try? JSONDecoder().decode(Self.self, from: data),
            value.schema == "herm.simulator.v1", value.status == "ready", value.target != nil,
            !value.deviceID.isEmpty, value.deviceID.count <= 128,
            !value.deviceName.isEmpty, value.deviceName.count <= 256,
            value.host.caseInsensitiveCompare(localHost) == .orderedSame
        else { return nil }
        return value
    }

}

@MainActor
final class SessionSimulatorLaunchStore: ObservableObject {
    static let shared = SessionSimulatorLaunchStore()
    struct Request {
        let session: String
        let callID: String
        let receipt: SessionSimulatorLaunch
    }
    struct Connection: Identifiable {
        let id: UUID
        let session: String
        let platform: SessionSimulatorPlatform
        let deviceID: String
    }
    @Published private(set) var connections: [UUID: Connection] = [:]
    @Published private(set) var latest: Request?
    private var requests: [String: Request] = [:]

    func request(for session: String, platform: SessionSimulatorPlatform) -> Request? {
        requests[session + ":" + platform.rawValue]
    }

    func setConnected(
        _ connected: Bool, owner: UUID, session: String, platform: SessionSimulatorPlatform, deviceID: String
    ) {
        if connected {
            if let existing = connections[owner], existing.session == session,
                existing.platform == platform, existing.deviceID == deviceID
            {
                return
            }
            connections[owner] = Connection(id: owner, session: session, platform: platform, deviceID: deviceID)
        } else if connections[owner] != nil {
            connections.removeValue(forKey: owner)
        }
    }

    /// A launch receipt alone is not evidence of a connected display.
    func connectedLaunches(for session: String) -> [Request] {
        SessionSimulatorPlatform.allCases.compactMap { platform in
            guard let request = request(for: session, platform: platform),
                connections.values.contains(where: {
                    $0.session == session && $0.platform == platform && $0.deviceID == request.receipt.deviceID
                })
            else { return nil }
            return request
        }
    }

    func present(_ receipt: SessionSimulatorLaunch, session: String, callID: String) {
        let key = session + ":" + receipt.platform
        guard requests[key]?.callID != callID else { return }
        if requests.count >= 64 { requests.removeAll() }
        let request = Request(session: session, callID: callID, receipt: receipt)
        requests[key] = request
        latest = request
    }
}
