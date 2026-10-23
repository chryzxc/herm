import Combine
import Foundation

extension ControlCenterModel {
    func refreshPromptBudget() {
        guard let cli else { return }
        let generation = UUID()
        promptBudgetGeneration = generation
        beginProjectionRefresh("prompt.budget")
        Task {
            do {
                let result = try await cli.promptSize()
                guard generation == promptBudgetGeneration else { return }
                guard result.succeeded,
                    let data = result.stdout.data(using: .utf8),
                    let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    recordProjectionFailure("prompt.budget", error: Self.safeUserDiagnostic(result.stderr))
                    return
                }
                promptBudget = PromptBudgetSummary(
                    totalTokens: Self.intValue(row["total_tokens"] ?? row["total"]),
                    tokenLimit: Self.optionalIntValue(row["token_limit"] ?? row["context_max"]),
                    percent: Self.doubleValue(row["percent"] ?? row["context_percent"]), model: row["model"] as? String)
                recordProjectionSuccess("prompt.budget")
            } catch {
                guard generation == promptBudgetGeneration else { return }
                recordProjectionFailure("prompt.budget", error: Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func refreshVerification(for requestedSessionID: String? = nil) {
        guard let rpc, let repository = developmentContext, !repository.path.isEmpty else {
            projectFacts = nil
            verification = VerificationSummary(state: .notApplicable, evidence: nil)
            return
        }
        let factsGeneration = UUID()
        let verificationGeneration = UUID()
        let bindingGeneration = clientBindingGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        projectFactsGeneration = factsGeneration
        self.verificationGeneration = verificationGeneration
        let sessionID = requestedSessionID ?? dockModel?.sessionID
        Task { @MainActor in
            do {
                let factsResult = try await rpc.projectFacts(cwd: repository.path)
                guard factsGeneration == self.projectFactsGeneration,
                    self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration)
                else { return }
                projectFacts = Self.parseProjectFacts(factsResult)
            } catch {
                guard factsGeneration == self.projectFactsGeneration,
                    self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration)
                else { return }
                projectFacts = nil
            }
            do {
                let result = try await rpc.verificationStatus(sessionID: sessionID, cwd: repository.path)
                guard verificationGeneration == self.verificationGeneration,
                    self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration)
                else { return }
                verification = Self.parseVerification(result)
            } catch {
                guard verificationGeneration == self.verificationGeneration,
                    self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration)
                else { return }
                verification = VerificationSummary(state: .unknown, evidence: nil)
            }
        }
    }

    func startBackgroundTask(_ prompt: String, kind: HermesBackgroundTaskKind = .general) async -> Bool {
        guard capabilityAvailable("gateway"), let rpc, let dockModel, let sessionID = dockModel.sessionID,
            !sessionID.isEmpty
        else {
            lastError =
                capabilityAvailable("gateway")
                ? "Open a Hermes session before starting a background task."
                : "Background tasks are unavailable in this Hermes installation."
            return false
        }
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else { return false }
        do {
            let result = try await rpc.startBackgroundPrompt(sessionID: sessionID, text: cleanPrompt)
            guard let taskID = result["task_id"] as? String, !taskID.isEmpty else {
                lastError = "Hermes did not return a background task ID."
                return false
            }
            dockModel.registerBackgroundTask(id: taskID, prompt: cleanPrompt, parentSessionID: sessionID, kind: kind)
            return true
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
    }

    func renameActiveSession(_ title: String) async -> Bool {
        guard let rpc, let sessionID = dockModel?.sessionID, !sessionID.isEmpty else { return false }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        do {
            _ = try await rpc.setSessionTitle(sessionID: sessionID, title: clean)
            refresh()
            return true
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
    }

    func redirectActiveSession(_ text: String) async -> SessionTextActionResult? {
        guard let rpc, let sessionID = dockModel?.sessionID, !sessionID.isEmpty else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        do {
            let result = try await rpc.redirect(sessionID: sessionID, text: clean)
            guard let raw = result["status"] as? String,
                let status = SessionTextActionStatus(rawValue: raw.lowercased()),
                let acceptedStatus = [SessionTextActionStatus.queued, .redirected, .rejected].first(where: {
                    $0 == status
                })
            else {
                lastError = "Hermes returned an invalid redirect response."
                return nil
            }
            let response = SessionTextActionResult(status: acceptedStatus, text: clean)
            if !response.wasAccepted { lastError = "Hermes rejected the redirect." }
            return response
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return nil
        }
    }

    func undoActiveSession() async -> Bool {
        guard let rpc, let dockModel, let sessionID = dockModel.sessionID, !sessionID.isEmpty else { return false }
        do {
            _ = try await rpc.undo(sessionID: sessionID)
            dockModel.resumeSession(
                HermesSession(
                    id: sessionID, title: dockModel.currentSessionTitle ?? "Hermes session", preview: "",
                    startedAt: nil, messageCount: 0, source: "hermes"))
            refresh()
            return true
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
    }

    func compressActiveSession(focusTopic: String? = nil) async -> Bool {
        guard capabilityAvailable("rpc-sessions"), let rpc, let sessionID = dockModel?.sessionID, !sessionID.isEmpty
        else {
            lastError = "Session compression is unavailable in this Hermes installation."
            return false
        }
        do {
            _ = try await rpc.compress(sessionID: sessionID, focusTopic: focusTopic)
            refreshSessionCockpit()
            return true
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
    }

    func branchActiveSession(name: String? = nil) async -> Bool {
        guard capabilityAvailable("rpc-sessions"), let rpc, let dockModel, let sessionID = dockModel.sessionID,
            !sessionID.isEmpty
        else {
            lastError = "Session branching is unavailable in this Hermes installation."
            return false
        }
        do {
            let result = try await rpc.branch(sessionID: sessionID, name: name)
            if let branchID = result["session_id"] as? String {
                dockModel.resumeSession(
                    HermesSession(
                        id: branchID, title: name ?? "Hermes branch", preview: "", startedAt: nil, messageCount: 0,
                        source: "branch"))
            }
            refresh()
            return true
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
    }

    func pauseDelegation(_ paused: Bool) async -> Bool {
        guard let rpc else { return false }
        do {
            let result = try await rpc.pauseDelegation(paused)
            delegationPaused = result["paused"] as? Bool ?? paused
            return true
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
    }

    func interruptSubagent(_ subagentID: String) async -> Bool {
        guard let rpc else { return false }
        do {
            let result = try await rpc.interruptSubagent(subagentID: subagentID)
            guard result["found"] as? Bool != false else {
                lastError = "Hermes could not find that subagent."
                return false
            }
            return true
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
    }

    /// Cheap `process.list`-only refresh for the composer strip while a turn runs.
    func pollProcesses() async {
        guard let rpc, capabilityAvailable("rpc-activity"),
            let sessionID = dockModel?.sessionID, !sessionID.isEmpty,
            let result = try? await rpc.processes(sessionID: sessionID),
            dockModel?.sessionID == sessionID
        else { return }
        let parsed = Self.parseProcesses(result)
        if parsed != processes { processes = parsed }
    }

    func killProcess(_ process: ProcessSummary) async -> Bool {
        guard rpc != nil, capabilityAvailable("rpc-activity") else {
            lastError = "Process control is unavailable through this Hermes gateway."
            return false
        }
        let actionID = "process.kill:\(process.id)"
        guard beginAction(actionID) else { return false }
        defer { finishAction(actionID) }
        guard let rpc, let sessionID = dockModel?.sessionID, !sessionID.isEmpty else { return false }
        do {
            _ = try await rpc.killProcess(sessionID: sessionID, processID: process.id)
            refresh()
            return true
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
    }
}
