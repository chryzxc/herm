import CoreFoundation
import Foundation

@MainActor
enum HermesRemoteProviderService {
    static let readerID = "remote-backend"
    static let balanceReaderID = "remote-openrouter-balance"

    static func profileName(_ profile: String?) -> String {
        guard let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "default" }
        return profile
    }

    static func readQuota(client: HermesRPCClientProtocol, profile: String?) async throws -> [ProviderQuotaSnapshot] {
        let params: [String: Any] = ["include_unconfigured": true, "profile": profileName(profile)]
        let result = try await client.request(HermesFeatureIDs.ID.modelOptions.rawValue, params: params)
        try validateCatalog(result)
        return snapshots(from: result, profile: profile, now: .now)
    }

    struct PartialRead {
        var snapshots: [ProviderQuotaSnapshot] = []
        var retainIDs: Set<String> = []
        var unavailableIDs: Set<String> = []
        var retainPrefixes: [String] = []
        var missingUsagePrefixes: [String] = []
        var missingUsageProviders: Set<String> = []
        var malformed = false
    }

    static func readPartial(client: HermesRPCClientProtocol, profile: String?) async throws -> PartialRead {
        let result = try await client.request(
            HermesFeatureIDs.ID.modelOptions.rawValue,
            params: ["include_unconfigured": true, "profile": profileName(profile)])
        return try partial(result, profile: profile)
    }

    static func partial(_ result: [String: Any], profile: String?) throws -> PartialRead {
        guard let rows = result["providers"] as? [[String: Any]] else { throw invalidCatalog() }
        var output = PartialRead()
        for row in rows {
            guard let slug = row["slug"] as? String, !slug.isEmpty else { throw invalidCatalog() }
            guard let mapped = QuotaWorkspacePresentation.quotaProviderID(for: slug) else { continue }
            let quotaID = mapped == "codex" ? "codex-hermes" : mapped
            let prefix =
                "\(quotaID)-backend-\(Data(profileName(profile).utf8).base64EncodedString())."
                + "\(Data(slug.utf8).base64EncodedString())."
            guard let rawUsage = row["usage"] else {
                output.missingUsagePrefixes.append(prefix)
                output.missingUsageProviders.insert(quotaID)
                continue
            }
            guard let usage = rawUsage as? [String: Any] else {
                output.malformed = true
                output.retainPrefixes.append(prefix)
                continue
            }
            if let accounts = usage["accounts"] as? [[String: Any]] {
                let ids = accounts.compactMap { $0["id"] as? String }
                guard ids.count == accounts.count, ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
                    output.malformed = true
                    output.retainPrefixes.append(prefix)
                    continue
                }
                for account in accounts {
                    var single = row
                    single["usage"] = ["accounts": [account]]
                    do {
                        try validateCatalog(["providers": [single]])
                        if let state = account["state"] as? String, state == "unknown" || state == "unavailable" {
                            let id = snapshotID(
                                quotaID, profile: profile, slug: slug, account: account["id"] as? String)
                            output.unavailableIDs.insert(id)
                        }
                        output.snapshots += snapshots(from: ["providers": [single]], profile: profile, now: .now)
                    } catch {
                        output.malformed = true
                        let id = snapshotID(quotaID, profile: profile, slug: slug, account: account["id"] as? String)
                        output.retainIDs.insert(id)
                    }
                }
            } else {
                do {
                    try validateCatalog(["providers": [row]])
                    output.snapshots += snapshots(from: ["providers": [row]], profile: profile, now: .now)
                } catch {
                    output.malformed = true
                    output.retainPrefixes.append(prefix)
                }
            }
        }
        return output
    }

    static func validateCatalog(_ result: [String: Any]) throws {
        guard let providers = result["providers"] as? [[String: Any]] else { throw invalidCatalog() }
        for row in providers {
            guard let slug = row["slug"] as? String, !slug.isEmpty else { throw invalidCatalog() }
            guard QuotaWorkspacePresentation.quotaProviderID(for: slug) != nil else { continue }
            guard let raw = row["usage"] else { throw invalidCatalog() }
            guard let usage = raw as? [String: Any] else { throw invalidCatalog() }
            if let rawAccounts = usage["accounts"] {
                guard let accounts = rawAccounts as? [[String: Any]] else { throw invalidCatalog() }
                var ids = Set<String>()
                for account in accounts {
                    guard let id = account["id"] as? String, !id.isEmpty, ids.insert(id).inserted else {
                        throw invalidCatalog()
                    }
                    guard let state = account["state"] as? String,
                        ["ready", "limited", "unknown", "unavailable"].contains(state),
                        let windows = account["windows"]
                    else { throw invalidCatalog() }
                    try validateWindows(windows)
                }
            } else if let windows = usage["windows"] {
                try validateWindows(windows)
            } else {
                throw invalidCatalog()
            }
        }
    }

    private static func validateWindows(_ raw: Any) throws {
        guard let windows = raw as? [[String: Any]] else { throw invalidCatalog() }
        for window in windows {
            guard ControlCenterModel.boundedQuotaText(window["label"]) != nil,
                let number = window["used_percent"] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
            else { throw invalidCatalog() }
        }
    }

    private static func invalidCatalog() -> NSError {
        NSError(
            domain: "HermesRemoteProvider", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The backend returned an invalid provider catalog."])
    }

    static func snapshots(from result: [String: Any], profile: String?, now: Date) -> [ProviderQuotaSnapshot] {
        guard let providers = result["providers"] as? [[String: Any]] else { return [] }
        var snapshots: [ProviderQuotaSnapshot] = []
        var seen = Set<String>()
        for row in providers {
            guard let slug = row["slug"] as? String, !slug.isEmpty,
                let usage = row["usage"] as? [String: Any],
                let mappedID = QuotaWorkspacePresentation.quotaProviderID(for: slug)
            else { continue }
            let quotaID = mappedID == "codex" ? "codex-hermes" : mappedID
            let providerName = ControlCenterModel.boundedQuotaText(row["name"]) ?? slug
            if let accounts = usage["accounts"] as? [[String: Any]] {
                for account in accounts {
                    guard let id = account["id"] as? String, !id.isEmpty else { continue }
                    let identity = snapshotID(quotaID, profile: profile, slug: slug, account: id)
                    guard seen.insert(identity).inserted else { continue }
                    let name = ControlCenterModel.boundedQuotaText(account["label"]) ?? providerName
                    let state = account["state"] as? String
                    let windows = (state == "ready" || state == "limited") ? parseWindows(account["windows"]) : []
                    snapshots.append(
                        ProviderQuotaSnapshot(
                            provider: identity, displayName: name, model: nil, updatedAt: now, windows: windows,
                            safeDetail: windows.isEmpty
                                ? "Quota unavailable for this backend account." : "Hermes backend"
                        ))
                }
            } else {
                let identity = snapshotID(quotaID, profile: profile, slug: slug, account: nil)
                guard seen.insert(identity).inserted else { continue }
                let windows = parseWindows(usage["windows"])
                snapshots.append(
                    ProviderQuotaSnapshot(
                        provider: identity, displayName: providerName, model: nil, updatedAt: now, windows: windows,
                        safeDetail: windows.isEmpty ? "Quota unavailable for this backend provider." : "Hermes backend"
                    ))
            }
        }
        return snapshots
    }

    static func snapshotID(_ quotaID: String, profile: String?, slug: String, account: String?) -> String {
        let parts = [profileName(profile), slug, account == nil ? "singleton" : "account", account ?? ""]
        let encoded = parts.map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
        return "\(quotaID)-backend-\(encoded)"
    }

    private static func parseWindows(_ raw: Any?) -> [ProviderQuotaWindow] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.enumerated().compactMap { index, row in
            guard let label = ControlCenterModel.boundedQuotaText(row["label"]),
                let number = row["used_percent"] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
            else { return nil }
            let remaining = max(0, min(100, 100 - number.doubleValue))
            return ProviderQuotaWindow(
                id: "\(index)", label: label, remainingPercent: remaining, remainingDisplay: nil,
                limitDisplay: nil, resetsAt: QuotaJSON.date(row["resets_at"]), resetsDisplay: nil)
        }
    }
}
