import Foundation

/// Captured when the request arrives, so aliases and navigation cannot redirect an answer.
struct AttentionRequest: Hashable {
    let sessionID: String
    let profileID: String?
    let requestID: String
}

enum AttentionAnswerState: Equatable {
    case sending(String)
    case checking(String)
    case failed(String, String)
    case uncertain(String, String)
    case answered(String, String)

    var choice: String {
        switch self {
        case .sending(let choice), .checking(let choice), .failed(let choice, _),
            .uncertain(let choice, _),
            .answered(let choice, _):
            choice
        }
    }

    var blocksSubmission: Bool {
        switch self {
        case .sending, .checking, .uncertain, .answered: true
        case .failed: false
        }
    }

    var message: String {
        switch self {
        case .sending: "Sending answer…"
        case .checking: "Checking pending request…"
        case .failed(_, let message): message
        case .answered(_, let message): message
        case .uncertain: "Answer delivery is uncertain. Open the session before trying again."
        }
    }

    static func failure(_ error: Error, choice: String) -> Self {
        let diagnostic = HermesDiagnosticsService.safeSummary(error.localizedDescription)
        let error = error as NSError
        // The gateway reports a received JSON-RPC refusal with this domain/code.
        if error.domain == "Hermes", error.code == 1 {
            return .failed(choice, diagnostic)
        }
        return .uncertain(choice, diagnostic)
    }
}
