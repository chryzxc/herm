import Foundation

struct ProcessStopConfirmation {
    let process: ProcessSummary
    let sessionID: String
    let generation: UUID
    let binding: UInt64
}

extension ControlCenterModel {
    func clearProcessFocus() {
        currentFocus = nil
        sessionProcessesGeneration = UUID()
        processSessionID = nil
        processes = []
    }

    func acceptsProcessResponse(for sessionID: String, generation: UUID, binding: UInt64) -> Bool {
        sessionProcessesGeneration == generation
            && clientBindingGeneration == binding
            && processSessionID == sessionID
            && (dockModel == nil || dockModel?.sessionID == sessionID)
    }

    @discardableResult
    func refreshFocusedProcesses(for sessionID: String, generation: UUID) -> Task<Void, Never>? {
        guard capabilityAvailable("rpc-sessions"), let rpc else { return nil }
        let binding = clientBindingGeneration
        return Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await rpc.processes(sessionID: sessionID)
                guard self.acceptsProcessResponse(for: sessionID, generation: generation, binding: binding) else {
                    return
                }
                self.processes = Self.parseProcesses(result)
                self.recordProjectionSuccess("processes")
            } catch {
                guard self.acceptsProcessResponse(for: sessionID, generation: generation, binding: binding) else {
                    return
                }
                self.processes = []
                self.recordProjectionFailure("processes", error: Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func processStopConfirmation(_ process: ProcessSummary) -> ProcessStopConfirmation {
        ProcessStopConfirmation(
            process: process, sessionID: processSessionID ?? "", generation: sessionProcessesGeneration,
            binding: clientBindingGeneration)
    }

    func canStopCurrentProcess(_ confirmation: ProcessStopConfirmation) -> Bool {
        !confirmation.sessionID.isEmpty
            && dockModel?.sessionID == confirmation.sessionID
            && acceptsProcessResponse(
                for: confirmation.sessionID, generation: confirmation.generation, binding: confirmation.binding)
            && processes.contains(confirmation.process)
    }
}
