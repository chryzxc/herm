import Foundation

/// Uses the same revision-fenced sidebar mutation as Hermes Desktop.
@MainActor
final class HermesSessionPinService {
    enum Failure: LocalizedError {
        case unavailable, sessionNotFound

        var errorDescription: String? {
            switch self {
            case .unavailable: "Session pinning is unavailable. Refresh and try again."
            case .sessionNotFound: "This saved session no longer exists. Refresh the session list."
            }
        }
    }

    private struct Intent: Hashable {
        let sessionID: String
        let profileID: String?
        let pinned: Bool
    }

    private struct Snapshot: Decodable {
        let sessionID: String
        let exists: Bool
        let revision: Int
        let generation: Int?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case exists
            case revision = "runtime_revision"
            case generation = "runtime_generation"
        }
    }

    // A lost acknowledgement must retry the same receipt, not overwrite a newer edit.
    private var pending: [Intent: [String: Any]] = [:]
    private var cliSupportedClient: ObjectIdentifier?

    func setPinned(_ pinned: Bool, sessionID: String, profileID: String?, client: HermesRPCClientProtocol) async throws
    {
        guard !sessionID.isEmpty,
            let encoded = sessionID.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.")))
        else { throw Failure.unavailable }
        let intent = Intent(sessionID: sessionID, profileID: profileID, pinned: pinned)
        let path = "/api/sessions/\(encoded)"
        var body: [String: Any]
        if let prepared = pending[intent] {
            body = prepared
        } else {
            var snapshotPath = path + "/mutation-snapshot"
            if let profileID, !profileID.isEmpty,
                let profile = profileID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            {
                snapshotPath += "?profile=\(profile)"
            }
            let raw = try await client.fetchHTTP(snapshotPath)
            guard let data = try? JSONSerialization.data(withJSONObject: raw),
                let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                snapshot.sessionID == sessionID, snapshot.revision >= 0
            else { throw Failure.unavailable }
            guard snapshot.exists else { throw Failure.sessionNotFound }
            guard let generation = snapshot.generation, generation >= 0 else { throw Failure.unavailable }
            body = [
                "pinned": pinned, "request_id": UUID().uuidString,
                "expected_revision": snapshot.revision, "expected_generation": generation,
            ]
            if let profileID, !profileID.isEmpty { body["profile"] = profileID }
            pending[intent] = body
        }
        do {
            do {
                let result = try await client.sendHTTP("PATCH", path: path, body: body)
                guard result["ok"] as? Bool == true else { throw Failure.unavailable }
            } catch HermesGateway.GatewayError.httpRefused(404, "not_found") {
                // TUI history can exist without the HTTP route's execution-owner binding.
                try await setSavedSessionPinned(pinned, sessionID: sessionID, profileID: profileID, client: client)
            }
            pending = pending.filter { $0.key.sessionID != sessionID || $0.key.profileID != profileID }
        } catch {
            let status: Int?
            switch error {
            case HermesGateway.GatewayError.httpError(let code), HermesGateway.GatewayError.httpRefused(let code, _):
                status = code
            default: status = nil
            }
            if let status, (400..<500).contains(status), status != 408, status != 429 {
                pending[intent] = nil
            }
            throw error
        }
    }

    private func setSavedSessionPinned(
        _ pinned: Bool, sessionID: String, profileID: String?, client: HermesRPCClientProtocol
    ) async throws {
        let cli = HermesCLIAdapter(rpc: HermesControlRPC(client: client))
        if cliSupportedClient != ObjectIdentifier(client) {
            for pinned in [true, false] {
                let help = try await cli.sessionPinHelp(pinned: pinned)
                guard help.succeeded, help.stdout.contains("sessions \(pinned ? "pin" : "unpin")"),
                    help.stdout.contains("session_ids")
                else { throw Failure.unavailable }
            }
            cliSupportedClient = ObjectIdentifier(client)
        }
        let result = try await cli.setSessionPinned(pinned, sessionID: sessionID, profileID: profileID)
        guard result.succeeded else {
            throw HermesCLIError.failed(
                result.stderr.isEmpty
                    ? "Hermes could not update the saved session pin. Refresh and try again." : result.stderr)
        }
    }
}
