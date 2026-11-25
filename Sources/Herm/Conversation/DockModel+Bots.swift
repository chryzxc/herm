extension DockModel {
    func makeBotMode() -> BotModeModel {
        let bots = BotModeModel()
        bots.bind(to: controlRPCClient, capabilityAvailable: false)
        isBotModeLoaded = true
        syncBotActivitySignals()
        return bots
    }

    /// Feeds the Bot activity board the session state Herm tracks from
    /// gateway events, so a Bot's status flips without waiting for a poll.
    /// Coalesces inventory changes into one pass. Live status updates send
    /// the affected session's signal directly.
    func syncBotActivitySignals() {
        guard !botActivitySyncPending else { return }
        botActivitySyncPending = true
        Task { @MainActor [weak self] in self?.flushBotActivitySignals() }
    }

    func flushBotActivitySignals() {
        botActivitySyncPending = false
        guard isBotModeLoaded else { return }
        var rows: [BotSessionSignal] = []
        var seen = Set<String>()
        func add(_ sessions: [HermesSession]) {
            rows.reserveCapacity(rows.count + sessions.count)
            for session in sessions where seen.insert(session.id).inserted { rows.append(BotSessionSignal(session)) }
        }
        // Event-patched lists first, so a stale scan row never overrides them.
        add(sessions)
        add(pinnedSessions)
        switch allBotSessionsState {
        case .ready(let all), .stale(let all, _): add(all)
        case .loading, .empty, .unavailable, .failed: break
        }
        var attention: [String: String?] = [:]
        for (sessionID, request) in sessionAttention {
            attention[rowSessionID(sessionID)] = request.responseTarget?.profileID
        }
        botMode.updateActivitySignals(
            BotActivitySignals(sessions: rows, attention: attention, scopeProfileID: profileScopeID))
    }
}
