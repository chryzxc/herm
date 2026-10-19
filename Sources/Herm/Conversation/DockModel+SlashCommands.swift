import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    func loadSlashCatalogIfNeeded() async {
        guard !hasLoadedSlashCatalog else { return }
        var params: [String: Any] = [:]
        if let sessionID { params["session_id"] = sessionID }
        guard let catalog = try? await sessionRPCClient.request(HermesFeatureIDs.ID.commandsCatalog.rawValue, params: params) else { return }
        let commands = catalog["commands"] as? [String: [String: Any]] ?? [:]
        slashCommandDispositions = commands.compactMapValues { $0["desktop"] as? String }
            .reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        hasLoadedSlashCatalog = true
    }

    func isSlashCommandHidden(_ command: String) -> Bool {
        slashCommandDispositions[command] != nil || ComposerCompletion.terminalOnlyCommands.contains(command)
    }

    func slashDispositions(forProfile profile: String) async -> [String: String] {
        if let cached = profileSlashDispositions[profile] { return cached }
        guard let catalog = try? await sessionRPCClient.request(HermesFeatureIDs.ID.commandsCatalog.rawValue, params: ["profile": profile]) else { return [:] }
        let commands = catalog["commands"] as? [String: [String: Any]] ?? [:]
        let result = commands.compactMapValues { $0["desktop"] as? String }
            .reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        profileSlashDispositions[profile] = result
        return result
    }

    /// `profile` scopes completions to another bot (the forward box); the open
    /// session belongs to a different profile, so it is left out of the params.
    func composerCompletions(for trigger: ComposerCompletionTrigger, bots: [ComposerCompletionItem], profile: String? = nil) async -> ComposerCompletion.Result {
        do {
            try await sessionRPCClient.connect()
            var params: [String: Any] = [:]
            if let profile {
                params["profile"] = profile
            } else if let sessionID {
                params["session_id"] = sessionID
            } else if let newSessionProjectPath, !newSessionProjectPath.isEmpty {
                params["cwd"] = newSessionProjectPath
            }
            switch trigger {
            case .slash(let text):
                params["text"] = text
                if let profile {
                    let dispositions = await slashDispositions(forProfile: profile)
                    let payload = try await sessionRPCClient.request(HermesFeatureIDs.ID.completeSlash.rawValue, params: params)
                    return ComposerCompletion.slashResult(from: payload, hidden: { dispositions[$0] != nil || ComposerCompletion.terminalOnlyCommands.contains($0) })
                }
                await loadSlashCatalogIfNeeded()
                let payload = try await sessionRPCClient.request(HermesFeatureIDs.ID.completeSlash.rawValue, params: params)
                return ComposerCompletion.slashResult(from: payload, hidden: isSlashCommandHidden)
            case .skill(let token):
                params["text"] = token
                let payload = try await sessionRPCClient.request(HermesFeatureIDs.ID.completeSlash.rawValue, params: params)
                var result = ComposerCompletion.slashResult(from: payload) { _ in false }
                result.items.removeAll { $0.group != "Skills" }
                return result
            case .mention(let word):
                params["word"] = word
                let payload = try await sessionRPCClient.request(HermesFeatureIDs.ID.completePath.rawValue, params: params)
                return ComposerCompletion.mentionResult(from: payload, bots: bots)
            }
        } catch {
            return ComposerCompletion.Result(items: bots)
        }
    }

    /// Mirrors Hermes desktop's slash dispatcher: a few client-owned actions,
    /// then `slash.exec`, falling back to `command.dispatch` for skills,
    /// bundles, quick commands and prompt builtins.
    func runSlashCommand(_ command: ComposerSlashCommand, echo: String) {
        let key = "/\(command.name)"
        switch command.name {
        case "new", "reset":
            newChat(projectPath: sessionID.flatMap { createdSessionProjectPaths[$0] } ?? newSessionProjectPath)
            return
        case "stop":
            _ = stop()
            return
        case "resume":
            let query = command.arg.lowercased()
            guard !query.isEmpty,
                  let session = sessions.first(where: { $0.id == command.arg || $0.title.lowercased() == query })
                    ?? sessions.first(where: { $0.id.hasPrefix(command.arg) || $0.title.lowercased().contains(query) }) else {
                messages.append(ChatMessage(role: .user, text: echo))
                messages.append(ChatMessage(role: .hermes, text: command.arg.isEmpty
                    ? "Pick a session from the sidebar, or type `/resume <title>`."
                    : "No session matches “\(command.arg)”.", isError: !command.arg.isEmpty))
                return
            }
            resumeSession(session)
            return
        default:
            break
        }

        messages.append(ChatMessage(role: .user, text: echo))
        if command.name == "model" {
            // Desktop opens its picker here (`desktop="hidden"` in the catalog); Herm matches the arg.
            // ponytail: `--global` is ignored, the pick is session-scoped like Herm's model menu.
            let query = command.arg.split(separator: " ").filter { !$0.hasPrefix("--") }.joined(separator: " ").lowercased()
            guard !query.isEmpty else {
                messages.append(ChatMessage(role: .hermes, text: "Model: \(sessionModelValue ?? "Hermes default"). Type `/model <name>` or use the model menu."))
                return
            }
            guard let option = runtimeModelOptions.first(where: { $0.model.lowercased() == query })
                    ?? runtimeModelOptions.first(where: { $0.displayName.lowercased().contains(query) }) else {
                messages.append(ChatMessage(role: .hermes, text: "No model matches “\(query)”. Open the model menu to see what’s available.", isError: true))
                return
            }
            updateSessionModel(option)
            messages.append(ChatMessage(role: .hermes, text: "Switched to \(option.displayName)."))
            return
        }
        if isSlashCommandHidden(key) {
            let reason = slashCommandDispositions[key] ?? "terminal"
            messages.append(ChatMessage(role: .hermes, text: "`\(key)` isn’t available in Herm (\(reason)-only).", isError: true))
            return
        }

        let generation = sessionResumeGeneration
        isSending = true
        Task {
            defer { if self.sessionResumeGeneration == generation, self.status != .working { self.isSending = false } }
            do {
                try await sessionRPCClient.connect()
                let sessionID = try await createAuthorizedSession(source: "herm")
                guard self.sessionResumeGeneration == generation else { return }
                // The agent builds lazily and slash.exec doesn't start it, so a plugin
                // command that submits a turn on a fresh session is refused ("could not
                // start the assistant"). Any waiting session RPC blocks on the build.
                _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.approvalPending.rawValue, params: ["session_id": sessionID])
                guard self.sessionResumeGeneration == generation else { return }
                switch command.name {
                case "compress", "compact":
                    // session.compress, not slash.exec: the worker times out on large sessions.
                    _ = try await interruptRPC.compress(sessionID: sessionID, focusTopic: command.arg)
                    appendSlashOutput("Context compressed.", generation: generation)
                case "title" where !command.arg.isEmpty:
                    _ = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.sessionTitle.rawValue,
                        params: scopedSessionParams(["session_id": sessionID, "title": command.arg])
                    )
                    currentSessionTitle = command.arg
                    loadSessions()
                    appendSlashOutput("Renamed to “\(command.arg)”.", generation: generation)
                case "btw", "bg", "background":
                    guard !command.arg.isEmpty else {
                        appendSlashOutput("Usage: `\(key) <prompt>`", generation: generation, isError: true)
                        return
                    }
                    let isBtw = command.name == "btw"
                    let result = try await sessionRPCClient.request(
                        (isBtw ? HermesFeatureIDs.ID.promptBtw : .promptBackground).rawValue,
                        params: ["session_id": sessionID, "text": command.arg]
                    )
                    guard let taskID = result["task_id"] as? String, !taskID.isEmpty else {
                        appendSlashOutput("Hermes did not return a task ID.", generation: generation, isError: true)
                        return
                    }
                    slashSideTaskIDs.insert(taskID)
                    if !isBtw { registerBackgroundTask(id: taskID, prompt: command.arg, parentSessionID: sessionID) }
                    appendSlashOutput(isBtw ? "Asking on the side…" : "Started in the background.", generation: generation)
                default:
                    try await execSlashCommand(command, sessionID: sessionID, generation: generation)
                }
            } catch {
                appendSlashOutput("`\(key)` failed: \(Self.safeUserDiagnostic(error.localizedDescription))", generation: generation, isError: true)
            }
        }
    }

    func execSlashCommand(_ command: ComposerSlashCommand, sessionID: String, generation: Int) async throws {
        let payload: [String: Any]
        do {
            let line = command.arg.isEmpty ? command.name : "\(command.name) \(command.arg)"
            payload = try await sessionRPCClient.request(
                HermesFeatureIDs.ID.slashExec.rawValue,
                params: ["session_id": sessionID, "command": line]
            )
        } catch {
            // Skills, bundles and pending-input builtins refuse slash.exec.
            payload = try await sessionRPCClient.request(
                HermesFeatureIDs.ID.commandDispatch.rawValue,
                params: ["session_id": sessionID, "name": command.name, "arg": command.arg]
            )
        }
        guard self.sessionResumeGeneration == generation else { return }

        let message = (payload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let notice = (payload["notice"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !notice.isEmpty {
            appendSlashOutput(notice, generation: generation)
        }
        switch payload["type"] as? String {
        case "alias":
            let target = (payload["target"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let aliased = ComposerSlashCommand("/\(target) \(command.arg)"), aliased.name != command.name {
                try await execSlashCommand(aliased, sessionID: sessionID, generation: generation)
            }
        case "prefill":
            if !message.isEmpty { draft = message }
        case "send", "skill":
            guard !message.isEmpty else {
                appendSlashOutput("`/\(command.name)`: empty message", generation: generation, isError: true)
                return
            }
            // The expanded skill body is model-facing; the transcript keeps the typed command.
            status = .working
            isSending = true
            _ = try await sessionRPCClient.request(
                HermesFeatureIDs.ID.promptSubmit.rawValue,
                params: scopedSessionParams(["session_id": sessionID, "text": message])
            )
        default:
            let output = (payload["output"] as? String) ?? "(no output)"
            let warning = (payload["warning"] as? String).map { "warning: \($0)\n" } ?? ""
            appendSlashOutput(warning + output, generation: generation)
        }
    }

    func appendSlashOutput(_ text: String, generation: Int, isError: Bool = false) {
        guard sessionResumeGeneration == generation else { return }
        if isError, status == .working {
            status = .idle
            isSending = false
        }
        messages.append(ChatMessage(role: .hermes, text: text, isError: isError))
    }

    /// Moves through the user prompts already present in the active session.
    /// Down past the newest prompt restores the draft that was present before
    /// history navigation began.
    func navigateComposerHistory(direction: Int) -> Bool {
        composer.navigate(direction: direction, history: userPromptHistory)
    }

    var userPromptHistory: [String] {
        messages
            .filter { $0.role == .user }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
