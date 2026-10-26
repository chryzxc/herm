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
    @Published private(set) var latest: Request?
    private var requests: [String: Request] = [:]

    func request(for session: String, platform: SessionSimulatorPlatform) -> Request? {
        requests[session + ":" + platform.rawValue]
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
