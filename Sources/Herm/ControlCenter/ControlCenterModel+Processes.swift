import Combine
import Foundation

/// A composer's process inventory follows its own conversation, not window focus.
@MainActor
final class SessionProcessProjection: ObservableObject {
    @Published private(set) var processes: [ProcessSummary] = []
    private(set) var sessionID: String?
    private let control: ControlCenterModel
    private let model: DockModel
    private var generation = UUID()
    private var inventoryBinding: UInt64?

    init(control: ControlCenterModel, model: DockModel) {
        self.control = control
        self.model = model
    }

    private var subscription: UUID?

    func startObserving() {
        guard subscription == nil else { return }
        subscription = model.eventRouter.subscribe { [weak self] type, params in
            guard type == "process.changed", let self else { return }
            let payload = params["payload"] as? [String: Any] ?? [:]
            let session = (params["session_id"] as? String) ?? (payload["session_id"] as? String)
            guard session == nil || session == self.model.sessionID else { return }
            Task { await self.poll() }
        }
    }

    func stopObserving() {
        if let subscription { model.eventRouter.unsubscribe(subscription) }
        subscription = nil
    }

    func reset(for sessionID: String?) {
        guard self.sessionID != sessionID else { return }
        self.sessionID = sessionID
        generation = UUID()
        processes = []
    }

    func poll() async {
        guard let sessionID, !sessionID.isEmpty, model.sessionID == sessionID,
            let rpc = control.rpc
        else { return }
        let binding = control.clientBindingGeneration
        if inventoryBinding != binding {
            inventoryBinding = nil
            processes = []
        }
        let generation = generation
        guard let result = try? await rpc.processes(sessionID: sessionID),
            self.generation == generation, self.sessionID == sessionID, model.sessionID == sessionID,
            control.clientBindingGeneration == binding, !Task.isCancelled
        else { return }
        inventoryBinding = binding
        let parsed = ControlCenterModel.parseProcesses(result)
        if parsed != processes { processes = parsed }
    }

    func confirmation(for process: ProcessSummary) -> ProcessStopConfirmation {
        ProcessStopConfirmation(
            process: process, sessionID: sessionID ?? "", generation: generation,
            binding: control.clientBindingGeneration)
    }

    func stop(_ confirmation: ProcessStopConfirmation) async -> Bool {
        guard !confirmation.sessionID.isEmpty, sessionID == confirmation.sessionID,
            model.sessionID == confirmation.sessionID, generation == confirmation.generation,
            control.clientBindingGeneration == confirmation.binding, inventoryBinding == confirmation.binding,
            processes.contains(where: { $0.id == confirmation.process.id && $0.state == "running" }),
            let rpc = control.rpc
        else { return false }
        do {
            _ = try await rpc.killProcess(sessionID: confirmation.sessionID, processID: confirmation.process.id)
            await poll()
            return true
        } catch {
            control.reportActionError(
                "Could not stop process",
                message: HermesDiagnosticsService.safeSummary(
                    ControlCenterModel.safeUserDiagnostic(error.localizedDescription)))
            return false
        }
    }
}

struct ProcessStopConfirmation {
    let process: ProcessSummary
    let sessionID: String
    let generation: UUID
    let binding: UInt64
}

extension ControlCenterModel {
    /// A session-scoped process listing also proves support when the broad capability probe is unavailable.
    var processControlAvailable: Bool {
        guard rpc != nil else { return false }
        return capabilityAvailable("rpc-activity")
            || (processSessionID != nil && processSessionID == dockModel?.sessionID && !processes.isEmpty)
    }

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
            && processes.contains {
                $0.id == confirmation.process.id && $0.state == confirmation.process.state
            }
    }
}
