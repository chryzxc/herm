import Foundation

enum QuotaHTTPFailure: Error {
    case network
    case status(Int)
    case invalidResponse
}

/// Shared GET + JSON fetch for provider quota endpoints. Callers map failures
/// to their own provider-specific error messages.
enum QuotaHTTP {
    static func getJSON(url: URL, headers: [String: String]) async -> Result<[String: Any], QuotaHTTPFailure> {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
            guard (200..<300).contains(http.statusCode) else { return .failure(.status(http.statusCode)) }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.invalidResponse)
            }
            return .success(object)
        } catch {
            return .failure(.network)
        }
    }
}
