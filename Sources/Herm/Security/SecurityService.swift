import Foundation

public enum SecurityService {
    private static let schema = "hermes.security.control-plane.v1"
    private static let unavailableText = "Security control-plane capability is unavailable."

    // No mutation adapter currently exists, so advertise no actions and fail closed.
    public static let availableActions: Set<SecurityAction> = []

    public static func snapshot(from output: String, format: SecurityOutputFormat = .json) -> SecuritySnapshot {
        parse(output, format: format)
    }

    public static func parse(_ output: String, format: SecurityOutputFormat) -> SecuritySnapshot {
        guard format == .json else { return unavailable(state: .unsupported) }
        do { return try parseVerifiedJSON(output) }
        catch { return unavailable(state: .malformed) }
    }

    public static func parseVerifiedJSON(_ output: String) throws -> SecuritySnapshot {
        guard !containsSensitiveMaterial(output) else { throw ParseError.unsafe }
        let data = Data(output.utf8)
        let value = try JSONDecoder().decode(Contract.self, from: data)
        guard value.schema == schema,
              value.approvals.pending >= 0,
              value.checkpoints.count >= 0,
              value.secretSources.sources.allSatisfy({ safeIdentifier($0.id) && safeIdentifier($0.kind) }),
              value.egress.allowlistedHosts >= 0,
              value.doctor.checks >= 0, value.doctor.failures >= 0, value.doctor.failures <= value.doctor.checks,
              [value.approvals.state, value.safeMode.state, value.checkpoints.state, value.secretSources.state, value.egress.state, value.doctor.state, value.security.state, value.logs.state].allSatisfy(safeIdentifier),
              safeIdentifier(value.egress.network), safeIdentifier(value.security.score), safeText(value.safeMode.reason)
        else { throw ParseError.invalidContract }
        return SecuritySnapshot(state: .ready, approvals: value.approvals, safeMode: value.safeMode, checkpoints: value.checkpoints, secretSources: value.secretSources, egress: value.egress, doctor: value.doctor, security: value.security, logs: value.logs)
    }

    public static func unavailable() -> SecuritySnapshot { unavailable(state: .unavailable) }

    public static func perform(_ action: SecurityAction, confirmed: Bool) -> SecurityActionResult {
        guard availableActions.contains(action) else { return .unavailable }
        guard confirmed else { return .confirmationRequired }
        return .performed
    }

    private static func unavailable(state: SecurityProjectionState) -> SecuritySnapshot {
        SecuritySnapshot(state: state, safeMode: .init(state: "unavailable", reason: unavailableText))
    }

    private static func safeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }

    private static func safeText(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 160, !containsSensitiveMaterial(value) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar == " " || scalar == "." || scalar == "_" || scalar == "-" || scalar.properties.isAlphabetic || (scalar.value >= 48 && scalar.value <= 57)
        }
    }

    private static func containsSensitiveMaterial(_ value: String) -> Bool {
        let lower = value.lowercased()
        let markers = ["token=", "token:", "password=", "passwd=", "secret=", "api_key=", "api-key=", "bearer ", "ghp_", "sk-", "xoxb-", "akia", "/users/", "/private/", "/home/", "~/", "../", ":\\\\"]
        return markers.contains { lower.contains($0) }
    }

    private enum ParseError: Error { case unsafe, invalidContract }

    private struct Contract: Decodable {
        let schema: String; let approvals: SecurityApprovals; let safeMode: SecuritySafeMode; let checkpoints: SecurityCheckpoints; let secretSources: SecuritySecretSources; let egress: SecurityEgress; let doctor: SecurityDoctor; let security: SecurityStatus; let logs: SecurityLogStatus
        enum CodingKeys: String, CodingKey, CaseIterable { case schema, approvals, safeMode = "safeMode", checkpoints, secretSources = "secretSources", egress, doctor, security, logs }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schema = try c.decode(String.self, forKey: .schema); approvals = try c.decode(SecurityApprovals.self, forKey: .approvals); safeMode = try c.decode(SecuritySafeMode.self, forKey: .safeMode); checkpoints = try c.decode(SecurityCheckpoints.self, forKey: .checkpoints); secretSources = try c.decode(SecuritySecretSources.self, forKey: .secretSources); egress = try c.decode(SecurityEgress.self, forKey: .egress); doctor = try c.decode(SecurityDoctor.self, forKey: .doctor); security = try c.decode(SecurityStatus.self, forKey: .security); logs = try c.decode(SecurityLogStatus.self, forKey: .logs)
            guard Set(c.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.stringValue)) else { throw ParseError.invalidContract }
        }
    }
}
