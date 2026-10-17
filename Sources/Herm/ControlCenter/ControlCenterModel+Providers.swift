import Foundation
import Combine

extension ControlCenterModel {
    func quotaReaderID(for providerID: String) -> String? { providerQuotaReaderIDs[providerID] }

    /// Loads the stored Codex account quota through Codex's authenticated usage endpoint,
    /// independently of the active Hermes provider/model. Each provider is
    /// published as soon as its read returns, so one slow service never holds
    /// back the rest. `readerIDs` limits the read to those services and keeps
    /// every other provider's last reading.
    /// `quiet` is the notch's background poll: it skips while another read is
    /// in flight and publishes only real changes, since each publish re-renders
    /// every view observing this model (a scroll hitch every 30s otherwise).
    func refreshProviderQuota(only readerIDs: Set<String>? = nil, quiet: Bool = false) {
        let quotaState = projectionRefreshStates["provider.quota"]
        let quiet = quiet && quotaState?.lastSuccess != nil && quotaState?.error == nil && quotaState?.isStale == false
        if quiet, providerQuotaReadsInFlight > 0 { return }
        let generation = UUID()
        let bindingGeneration = clientBindingGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        providerQuotaGeneration = generation
        guard isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else {
            providerQuotas = []
            reportedProviderQuotas = []
            return
        }
        if !quiet { beginProjectionRefresh("provider.quota") }
        // Balance cards derive spend and runway from usage analytics.
        if !quiet, tokenUsage == nil { refreshTokenUsage(days: UsageWorkspaceView.storedDays) }
        let readers = Self.quotaReaders.filter { readerIDs?.contains($0.id) ?? true }
        providerQuotaReadsInFlight += 1
        Task { @MainActor in
            defer { providerQuotaReadsInFlight -= 1 }
            var changed = false
            var diagnostics = readerIDs == nil ? [:] : providerQuotaDiagnostics
            var seen = Set<String>()
            var errors: [String] = []
            await withTaskGroup(of: (String, QuotaReadResult).self) { group in
                for reader in readers {
                    group.addTask { await (reader.id, Self.readQuota(reader.read)) }
                }
                for await (readerID, result) in group {
                    guard generation == providerQuotaGeneration,
                          self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { continue }
                    let previous = reportedProviderQuotas.filter { providerQuotaReaderIDs[$0.provider] == readerID }
                    diagnostics[readerID] = nil
                    if let error = result.error {
                        // A failed read keeps the last reading rather than
                        // dropping the provider until the next success.
                        diagnostics[readerID] = error
                        errors.append(error)
                        seen.formUnion(previous.map(\.provider))
                        continue
                    }
                    let snapshots = Self.providerQuotaSnapshots(readerID: readerID, raw: result.value)
                    for snapshot in snapshots { providerQuotaReaderIDs[snapshot.provider] = readerID }
                    seen.formUnion(snapshots.map(\.provider))
                    guard snapshots != previous else { continue }
                    let replaced = Set(previous.map(\.provider))
                    reportedProviderQuotas = reportedProviderQuotas.filter { !replaced.contains($0.provider) } + snapshots
                    applyProviderQuotaPresentation()
                    changed = true
                }
            }
            guard generation == providerQuotaGeneration else { return }
            guard self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else {
                // Rebound mid-read: clear the spinner or every later poll,
                // which skips while a read is in flight, would stall.
                recordProjectionFailure("provider.quota", error: "Quota read was interrupted.")
                return
            }
            if providerQuotaDiagnostics != diagnostics { providerQuotaDiagnostics = diagnostics; changed = true }
            if readerIDs == nil, reportedProviderQuotas.contains(where: { !seen.contains($0.provider) }) {
                reportedProviderQuotas.removeAll { !seen.contains($0.provider) }
                applyProviderQuotaPresentation()
                changed = true
            }
            if !seen.isEmpty {
                refreshHermesActiveCredentials()
                if !quiet || changed { recordProjectionSuccess("provider.quota") }
            } else {
                recordProjectionFailure("provider.quota", error: errors.first ?? "Provider quota data is unavailable.")
            }
        }
    }

    /// Hermes pools (Codex and the rest) report several accounts at once.
    static func providerQuotaSnapshots(readerID: String, raw: [String: Any]?) -> [ProviderQuotaSnapshot] {
        guard let raw else { return [] }
        if let accounts = raw["_accounts"] as? [[String: Any]] {
            return accounts.compactMap(parseProviderQuota)
        }
        return parseProviderQuota(raw).map { [$0] } ?? []
    }

    /// Saves (or removes, when nil) a user-entered API key for an API-key
    /// provider and immediately re-reads quota with it.
    func saveProviderAPIKey(_ key: String?, for descriptor: QuotaProviderDescriptor) {
        guard let storageKey = descriptor.storageKey else { return }
        ProviderKeyStore().save(key, storageKey: storageKey)
        refreshProviderQuota()
    }

    /// Rebuilds `providerQuotas` from the last reported snapshots, applying
    /// nicknames and the saved display order without re-reading providers.
    func applyProviderQuotaPresentation() {
        let named = reportedProviderQuotas.map { snapshot in
            ProviderQuotaSnapshot(
                provider: snapshot.provider,
                displayName: providerNicknameStore.nickname(for: snapshot.provider) ?? snapshot.displayName,
                model: snapshot.model,
                updatedAt: snapshot.updatedAt,
                windows: snapshot.windows + Self.balanceUsageWindows(for: snapshot, usage: tokenUsage),
                safeDetail: snapshot.safeDetail,
                hermesCredential: snapshot.hermesCredential
            )
        }
        providerQuotas = QuotaWorkspacePresentation.ordered(named, savedOrder: providerQuotaOrder)
    }

    /// Pay-as-you-go APIs only report a balance, so their cards add spend,
    /// top model, and runway from Hermes' own usage analytics.
    static func balanceUsageWindows(for snapshot: ProviderQuotaSnapshot, usage: TokenUsageReport?) -> [ProviderQuotaWindow] {
        guard let usage, usage.days > 0, ["deepseek", "kimi", "openrouter"].contains(snapshot.provider) else { return [] }
        let models = usage.models.filter { model in
            (model.providers.isEmpty ? [model.model] : model.providers)
                .contains { QuotaWorkspacePresentation.quotaProviderID(for: $0) == snapshot.provider }
        }
        guard !models.isEmpty else { return [] }
        let cost = models.reduce(0) { $0 + $1.estimatedCost }
        let tokens = models.reduce(0) { $0 + $1.totalTokens }
        let calls = models.reduce(0) { $0 + $1.apiCalls }
        func window(_ id: String, _ label: String, _ value: String, _ detail: String?) -> ProviderQuotaWindow {
            ProviderQuotaWindow(id: id, label: label, remainingPercent: nil, remainingDisplay: value, limitDisplay: detail, resetsAt: nil, resetsDisplay: nil)
        }
        var windows = [window("hermes-spend", "Spent · last \(usage.days)d", "\(UsageWorkspaceView.cost(cost)) est.", "\(UsageWorkspaceView.tokens(tokens)) tokens · \(calls) calls")]
        if let top = models.max(by: { $0.totalTokens < $1.totalTokens }) {
            windows.append(window("hermes-top-model", "Top model", top.model, "\(UsageWorkspaceView.tokens(top.totalTokens)) tokens · \(UsageWorkspaceView.cost(top.estimatedCost))"))
        }
        if cost > 0, let balance = snapshot.windows.lazy.compactMap(\.amount).first {
            let days = balance / (cost / Double(usage.days))
            windows.append(window("hermes-runway", "Runway", days < 1 ? "Under a day" : "~\(Int(days.rounded())) days", "at the \(usage.days)-day pace"))
        }
        return windows
    }

    /// Sets a custom display name (nickname) for a provider. Persists across
    /// app launches. An empty or whitespace-only name restores the default.
    func setProviderNickname(_ nickname: String, for providerID: String) {
        providerNicknameStore.setNickname(nickname, for: providerID)
        applyProviderQuotaPresentation()
    }

    /// Gets the custom display name for a provider, or nil if not set.
    func getProviderNickname(for providerID: String) -> String? {
        providerNicknameStore.nickname(for: providerID)
    }

    /// The name the provider itself reports, ignoring any nickname.
    func reportedProviderName(for providerID: String) -> String? {
        reportedProviderQuotas.first(where: { $0.provider == providerID })?.displayName
    }

    /// Removes the custom nickname for a provider (reverts to default).
    func removeProviderNickname(for providerID: String) {
        providerNicknameStore.removeNickname(for: providerID)
        applyProviderQuotaPresentation()
    }

    /// The user's saved order of connected quota providers, keyed by the
    /// reported provider id so individual Hermes accounts (`codex-hermes-<pool entry id>`) can be
    /// ordered independently.
    var providerQuotaOrder: [String] {
        presentationDefaults.stringArray(forKey: Self.providerQuotaOrderKey) ?? []
    }

    /// Moves `providerID` into the position currently held by `targetID` and
    /// persists the resulting order.
    func moveProviderQuota(_ providerID: String, to targetID: String) {
        let current = providerQuotas.map(\.provider)
        let reordered = QuotaWorkspacePresentation.moving(providerID, to: targetID, in: current)
        guard reordered != current else { return }
        saveProviderQuotaOrder(reordered)
    }

    /// Moves a provider one position up (`offset: -1`) or down (`offset: 1`).
    func moveProviderQuota(_ providerID: String, by offset: Int) {
        let current = providerQuotas.map(\.provider)
        guard let index = current.firstIndex(of: providerID) else { return }
        let target = index + offset
        guard current.indices.contains(target) else { return }
        moveProviderQuota(providerID, to: current[target])
    }

    func saveProviderQuotaOrder(_ ids: [String]) {
        // Keep ids of providers that are temporarily disconnected, after the
        // visible ones, so reconnecting does not lose their saved position.
        let retained = providerQuotaOrder.filter { !ids.contains($0) }
        presentationDefaults.set(ids + retained, forKey: Self.providerQuotaOrderKey)
        applyProviderQuotaPresentation()
    }

    static func hermesCredentialRemovalActionID(_ providerID: String) -> String {
        "quota.hermesCredential.remove.\(providerID)"
    }

    /// Re-reads which pooled credential Hermes would pick next (the `←` row of
    /// `hermes auth list`), keyed `provider/id`. Under `round_robin` that is the
    /// account next in line, since Hermes rotates the order after each pick.
    func refreshHermesActiveCredentials() {
        guard let cli, reportedProviderQuotas.contains(where: { $0.hermesCredential != nil }) else { return }
        Task {
            await restoreHermesPrimaryCredentials(cli)
            guard let result = try? await cli.authList(), result.succeeded else { return }
            let active = Self.hermesActiveCredentialKeys(fromAuthList: result.stdout)
            if active != hermesActiveCredentialKeys { hermesActiveCredentialKeys = active }
        }
    }

    /// Primary picked through Make primary, `provider -> pool entry id`.
    var hermesPrimaryCredentials: [String: String] {
        get { presentationDefaults.dictionary(forKey: Self.hermesPrimaryCredentialsKey) as? [String: String] ?? [:] }
        set { presentationDefaults.set(newValue, forKey: Self.hermesPrimaryCredentialsKey) }
    }

    /// Hermes saves a pool with each process's in-memory priorities, so a
    /// gateway or session that loaded the pool before Make primary writes the
    /// old order back on its next flush (token refresh, rotation). Re-apply the
    /// user's pick whenever it has slipped, but only under `fill_first`, where
    /// order is meant to be stable; a pick whose account is gone is forgotten.
    func restoreHermesPrimaryCredentials(_ cli: HermesCLIAdapter) async {
        let pins = hermesPrimaryCredentials
        guard !pins.isEmpty else { return }
        if configEditor.state == .idle { await configEditor.load() }
        guard configEditor.state == .ready else { return }
        let credentials = reportedProviderQuotas.compactMap(\.hermesCredential)
        let plan = Self.hermesPrimaryRestorePlan(pins: pins, credentials: credentials) {
            self.configEditor.value("credential_pool_strategies.\($0)") as? String
        }
        if plan.forget.isEmpty == false {
            hermesPrimaryCredentials = pins.filter { !plan.forget.contains($0.key) }
        }
        for credential in plan.restore {
            _ = try? await cli.authPriority(provider: credential.provider, credentialID: credential.id, priority: 0)
        }
    }

    nonisolated static func hermesPrimaryRestorePlan(
        pins: [String: String],
        credentials: [HermesPooledCredential],
        strategy: (String) -> String?
    ) -> (restore: [HermesPooledCredential], forget: Set<String>) {
        var restore: [HermesPooledCredential] = []
        var forget = Set<String>()
        for (provider, id) in pins {
            let pool = credentials.filter { $0.provider == provider }
            // No cards for the provider yet (read failed): keep the pin, decide next refresh.
            guard !pool.isEmpty else { continue }
            guard let pinned = pool.first(where: { $0.id == id }) else { forget.insert(provider); continue }
            let current = strategy(provider) ?? "fill_first"
            if current == "fill_first", pinned.position != 1 { restore.append(pinned) }
        }
        return (restore, forget)
    }

    func isHermesPinnedPrimary(_ credential: HermesPooledCredential) -> Bool {
        hermesPrimaryCredentials[credential.provider] == credential.id
    }

    func isHermesActiveCredential(_ credential: HermesPooledCredential) -> Bool {
        hermesActiveCredentialKeys.contains("\(credential.provider)/\(credential.id)")
    }

    /// Parses `hermes auth list`: `<provider> (N credentials):` headers, then
    /// entry rows carrying `id=<id>` and a trailing `←` on the selected one.
    nonisolated static func hermesActiveCredentialKeys(fromAuthList output: String) -> Set<String> {
        var provider = ""
        var keys = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            if !line.hasPrefix(" "), let header = line.split(separator: " ").first, line.hasSuffix("credentials):") {
                provider = String(header)
            } else if line.contains("←"),
                      let id = line.split(separator: " ").first(where: { $0.hasPrefix("id=") })?.dropFirst(3), !id.isEmpty {
                keys.insert("\(provider)/\(id)")
            }
        }
        return keys
    }

    static func hermesCredentialPrimaryActionID(_ providerID: String) -> String {
        "quota.hermesCredential.primary.\(providerID)"
    }

    /// Moves a pooled account to the front of Hermes' pool order through
    /// `hermes auth priority <provider> <id> 0`. Under `round_robin` Hermes
    /// rotates the order after each pick, so it only stays first until then.
    func makeHermesPooledCredentialPrimary(for providerID: String) {
        guard let credential = reportedProviderQuotas.first(where: { $0.provider == providerID })?.hermesCredential else { return }
        guard let cli else {
            providerQuotaActionErrors[providerID] = "Hermes is not connected, so the account order could not be changed."
            return
        }
        let actionID = Self.hermesCredentialPrimaryActionID(providerID)
        guard beginAction(actionID) else { return }
        providerQuotaActionErrors[providerID] = nil
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.authPriority(provider: credential.provider, credentialID: credential.id, priority: 0)
                guard result.succeeded else {
                    let message = Self.safeUserDiagnostic(result.stderr)
                    providerQuotaActionErrors[providerID] = message.isEmpty ? "Hermes could not reorder this account." : message
                    return
                }
                hermesPrimaryCredentials[credential.provider] = credential.id
                refreshProviderQuota()
            } catch {
                providerQuotaActionErrors[providerID] = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    /// Removes a Hermes-pooled account from Hermes itself through
    /// `hermes auth remove`, so Hermes stops rotating through it too. The Dock
    /// only forgets its own nickname and position after Hermes succeeds.
    func removeHermesPooledCredential(for providerID: String) {
        guard let credential = reportedProviderQuotas.first(where: { $0.provider == providerID })?.hermesCredential else { return }
        guard let cli else {
            providerQuotaActionErrors[providerID] = "Hermes is not connected, so the account could not be removed."
            return
        }
        let actionID = Self.hermesCredentialRemovalActionID(providerID)
        guard beginAction(actionID) else { return }
        providerQuotaActionErrors[providerID] = nil
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.authRemove(provider: credential.provider, credentialID: credential.id)
                guard result.succeeded else {
                    let message = Self.safeUserDiagnostic(result.stderr)
                    providerQuotaActionErrors[providerID] = message.isEmpty ? "Hermes could not remove this account." : message
                    return
                }
                providerNicknameStore.removeNickname(for: providerID)
                presentationDefaults.set(providerQuotaOrder.filter { $0 != providerID }, forKey: Self.providerQuotaOrderKey)
                reportedProviderQuotas.removeAll { $0.provider == providerID }
                applyProviderQuotaPresentation()
                refreshProviderQuota()
            } catch {
                providerQuotaActionErrors[providerID] = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    /// Saves the user's preferred catalog order (used for providers without a
    /// saved display position).
    func setProviderOrder(_ providerIDs: [String]) {
        QuotaProviderCatalog.saveProviderOrder(providerIDs)
        applyProviderQuotaPresentation()
    }

    /// Gets the current provider display order based on user preferences.
    func getProviderOrder() -> [String] {
        QuotaProviderCatalog.orderedProviderIDs()
    }

    /// Launches the provider's desktop app so the user can sign in; quota is
    /// re-read shortly afterwards, once the app's local service is up.
    func openProviderApplication(named applicationName: String) {
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", applicationName]
            try? process.run()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self.refreshProviderQuota()
        }
    }

    nonisolated static func readQuota(_ read: @Sendable () async throws -> [String: Any]) async -> QuotaReadResult {
        do { return QuotaReadResult(value: try await read(), error: nil) }
        catch { return QuotaReadResult(value: nil, error: Self.safeUserDiagnostic(error.localizedDescription)) }
    }
}
