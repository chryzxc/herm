import Foundation

/// One question of a batch `clarify` server request.
struct ClarifyQuestion: Equatable {
    let id: String
    let question: String
    let choices: [String]
    let multiSelect: Bool

    /// Hermes' `questions` list; questions without a `qid` cannot be locked and are dropped.
    static func batch(from payload: [String: Any]) -> [ClarifyQuestion] {
        (payload["questions"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["qid"] as? String, !id.isEmpty,
                let question = item["question"] as? String
            else { return nil }
            let raw =
                ["choices", "options", "suggested_responses"].lazy
                .compactMap { (item[$0] as? [Any])?.compactMap { $0 as? String } }
                .first { !$0.isEmpty } ?? []
            let choices = raw.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return ClarifyQuestion(
                id: id, question: question, choices: choices,
                multiSelect: item["multi_select"] as? Bool == true && !choices.isEmpty)
        }
    }

    /// Hermes' clarify tool reads a multi-select answer as a JSON array.
    static func multiSelectAnswer(_ selection: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: selection)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// A one-string server request (sudo, secret, vault prompts). Hermes waits for
/// `{value}`; an empty value means skipped.
struct ValuePrompt: Equatable {
    static let methods: Set<String> = ["sudo", "secret", "vault.unlock_prompt", "vault.save_login", "vault.code"]

    let requestID: String
    let title: String
    let message: String
    let fieldLabel: String
    let isSecret: Bool
    /// `vault.save_login` answers with JSON `{identifier, password}`.
    let asksForLogin: Bool

    /// `payload` is the request params plus the `request_id` and `method` the gateway adds.
    static func from(payload: [String: Any]) -> ValuePrompt? {
        guard let requestID = payload["request_id"] as? String, !requestID.isEmpty,
            let method = payload["method"] as? String
        else { return nil }
        func text(_ key: String) -> String? {
            (payload[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        switch method {
        case "sudo":
            let command = text("command").map { "\n\($0)" } ?? ""
            return ValuePrompt(
                requestID: requestID, title: "Administrator password",
                message: "Hermes needs your sudo password to run:\(command)",
                fieldLabel: "Password", isSecret: true, asksForLogin: false)
        case "secret":
            let envVar = text("env_var") ?? "a secret"
            return ValuePrompt(
                requestID: requestID, title: "Secret needed: \(envVar)",
                message: text("prompt") ?? "Hermes needs a value for \(envVar).",
                fieldLabel: envVar, isSecret: true, asksForLogin: false)
        case "vault.unlock_prompt":
            let name = text("display_name") ?? text("backend") ?? "your password manager"
            return ValuePrompt(
                requestID: requestID, title: "Unlock \(name)",
                message: "Enter the master password to unlock \(name) for this session.",
                fieldLabel: "Master password", isSecret: true, asksForLogin: false)
        case "vault.save_login":
            let site = text("site") ?? text("origin") ?? "this site"
            return ValuePrompt(
                requestID: requestID, title: "Save login",
                message: "Hermes is about to sign in to \(text("origin") ?? site). Enter the login to save.",
                fieldLabel: "Password", isSecret: true, asksForLogin: true)
        case "vault.code":
            let site = text("site").map { " for \($0)" } ?? ""
            return ValuePrompt(
                requestID: requestID, title: "Verification code\(site)",
                message: text("hint") ?? "Enter the one-time code from your device.",
                fieldLabel: "Code", isSecret: false, asksForLogin: false)
        default:
            return nil
        }
    }

    func answer(value: String, identifier: String) -> String {
        guard asksForLogin else { return value }
        let data =
            (try? JSONSerialization.data(withJSONObject: ["identifier": identifier, "password": value])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
