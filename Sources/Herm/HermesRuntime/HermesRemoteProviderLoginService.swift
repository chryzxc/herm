import Combine
import Foundation

@MainActor
final class HermesRemoteProviderLoginService: ObservableObject {
    struct Start {
        let session: String
        let code: String
        let url: URL
        let expires: TimeInterval
        let interval: TimeInterval
    }

    @Published private(set) var startInfo: Start?
    @Published private(set) var message = "Start sign-in to check whether this backend supports device codes."
    @Published private(set) var approved = false
    @Published private(set) var busy = false
    @Published private(set) var cancellationInDoubt = false
    private var task: Task<Void, Never>?
    private var generation = 0
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void

    init(
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    static func path(_ components: [String], profile: String?) -> String {
        var url = URLComponents()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let segments = components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        url.percentEncodedPath = "/" + segments.joined(separator: "/")
        url.queryItems = [URLQueryItem(name: "profile", value: HermesRemoteProviderService.profileName(profile))]
        return url.string ?? ""
    }

    static func decodeStart(_ json: [String: Any]) throws -> Start {
        guard json["flow"] as? String == "device_code",
            let session = json["session_id"] as? String, !session.isEmpty, session.count <= 128,
            session.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
            let code = json["user_code"] as? String, !code.isEmpty, code.count <= 128,
            let rawURL = json["verification_url"] as? String, let parts = URLComponents(string: rawURL),
            parts.scheme?.lowercased() == "https", parts.host?.isEmpty == false,
            parts.user == nil, parts.password == nil, let url = parts.url,
            let expires = (json["expires_in"] as? NSNumber)?.doubleValue, expires.isFinite, expires > 0,
            let interval = (json["poll_interval"] as? NSNumber)?.doubleValue, interval.isFinite, interval > 0
        else { throw unavailable() }
        return Start(session: session, code: code, url: url, expires: min(expires, 3600), interval: max(interval, 1))
    }

    func begin(
        client: HermesRPCClientProtocol, profile: String?, provider: String, current: @escaping () -> Bool,
        onApproved: @escaping () -> Void
    ) {
        guard !busy, !cancellationInDoubt else { return }
        generation += 1
        let token = generation
        message = "Checking backend sign-in support…"
        approved = false
        busy = true
        task = Task {
            var session: String?
            var startRequested = false
            do {
                let base = ["api", "providers", "oauth"]
                let catalog = try await client.fetchHTTP(Self.path(base, profile: profile))
                guard token == generation, current(), !Task.isCancelled else { throw CancellationError() }
                guard let rows = catalog["providers"] as? [[String: Any]],
                    rows.contains(where: { $0["id"] as? String == provider && $0["flow"] as? String == "device_code" })
                else { throw Self.unavailable() }
                startRequested = true
                let requestedAt = now()
                let response = try await client.sendHTTP(
                    "POST", path: Self.path(base + [provider, "start"], profile: profile), body: [:])
                if let rawSession = response["session_id"] as? String { session = rawSession }
                let info = try Self.decodeStart(response)
                guard token == generation, current(), !Task.isCancelled else {
                    throw CancellationError()
                }
                startInfo = info
                message = "Open the verification page and enter this code."
                let deadline = requestedAt.addingTimeInterval(info.expires)
                while now() < deadline {
                    try await sleep(min(info.interval, max(0, deadline.timeIntervalSince(now()))))
                    guard token == generation, current(), !Task.isCancelled else { throw CancellationError() }
                    guard now() < deadline else { throw Self.unavailable() }
                    let pollPath = Self.path(base + [provider, "poll", info.session], profile: profile)
                    let remaining = deadline.timeIntervalSince(now())
                    guard remaining > 0 else { throw Self.unavailable() }
                    let status = try await client.fetchHTTP(pollPath, timeout: remaining)
                    guard token == generation, current(), !Task.isCancelled else { throw CancellationError() }
                    guard now() < deadline else { throw Self.unavailable() }
                    switch status["status"] as? String {
                    case "pending": continue
                    case "approved":
                        startInfo = nil
                        approved = true
                        busy = false
                        message = "Signed in on the Hermes backend."
                        onApproved()
                        return
                    case "expired", "cancelled", "error": throw Self.unavailable()
                    default: throw Self.unavailable()
                    }
                }
                throw Self.unavailable()
            } catch {
                if let session {
                    let deleted = await Task { await Self.delete(client: client, profile: profile, session: session) }
                        .value
                    if !deleted { cancellationInDoubt = true }
                } else if startRequested {
                    cancellationInDoubt = true
                }
                startInfo = nil
                busy = false
                message =
                    cancellationInDoubt
                    ? "Cancellation could not be confirmed. This sign-in may still complete on the original backend and profile."
                    : "Backend sign-in stopped. You can retry or sign in on the backend host."
            }
        }
    }

    func cancel() async -> Bool {
        generation += 1
        task?.cancel()
        await task?.value
        task = nil
        return !cancellationInDoubt
    }

    private static func delete(client: HermesRPCClientProtocol, profile: String?, session: String) async -> Bool {
        do {
            _ = try await client.sendHTTP(
                "DELETE", path: path(["api", "providers", "oauth", "sessions", session], profile: profile), body: [:])
            return true
        } catch { return false }
    }

    private static func unavailable() -> NSError { NSError(domain: "HermesRemoteLogin", code: 1) }
}
