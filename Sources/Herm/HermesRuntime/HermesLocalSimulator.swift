import Foundation

enum HermesLocalSimulator {
    static func bootedName() async -> String? {
        guard
            let result = try? await HermesLocalProcess.capture(
                "/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "booted", "-j"], timeout: 5
            ), result.code == 0
        else { return nil }
        return parseBootedName(result.data)
    }

    static func parseBootedName(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let runtimes = root["devices"] as? [String: [[String: Any]]]
        else { return nil }
        return runtimes.values.flatMap(\.self).first { $0["state"] as? String == "Booted" }?["name"] as? String
    }
}
