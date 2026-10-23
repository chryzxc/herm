import SwiftUI

/// One row of Hermes' provider catalog (`model.options` with
/// `include_unconfigured`). Unconfigured rows carry Hermes' own setup hint.
struct HermesProviderRow: Identifiable, Equatable {
    enum Access: Equatable { case apiKey, browser, external }

    let slug: String
    let name: String
    let authenticated: Bool
    let isCurrent: Bool
    let isUserDefined: Bool
    let authType: String?
    let keyEnv: String?
    let warning: String?
    let totalModels: Int

    var id: String { slug }

    /// How Herm can connect this provider: a pasted key (`model.save_key`),
    /// a browser sign-in (`hermes auth add`), or only through `hermes model`.
    var access: Access {
        if AddPoolAccountSheet.browserSignInProviders.contains(slug) { return .browser }
        if isUserDefined || Self.externalSlugs.contains(slug) { return .external }
        if let authType, authType != "api_key" { return .external }
        return .apiKey
    }

    private static let externalSlugs: Set<String> = ["bedrock", "vertex", "copilot", "copilot-acp", "custom", "moa"]

    static func rows(from result: [String: Any]) -> [Self] {
        (result["providers"] as? [[String: Any]] ?? []).compactMap { row in
            guard let slug = row["slug"] as? String, !slug.isEmpty else { return nil }
            return Self(
                slug: slug,
                name: (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug,
                authenticated: row["authenticated"] as? Bool ?? true,
                isCurrent: row["is_current"] as? Bool ?? false,
                isUserDefined: row["is_user_defined"] as? Bool ?? false,
                authType: row["auth_type"] as? String,
                keyEnv: row["key_env"] as? String,
                warning: row["warning"] as? String,
                totalModels: row["total_models"] as? Int ?? (row["models"] as? [Any])?.count ?? 0
            )
        }
    }
}

/// Settings → Providers: Hermes' whole provider catalog, connected first.
/// Accounts are added with the same sheet and sign-in flow as Quota.
struct ProvidersSettingsView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var control: ControlCenterModel

    private enum Filter: Hashable { case all, connected, available }

    private var rows: [HermesProviderRow] { control.hermesProviderRows ?? [] }
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var query = ""
    @State private var filter = Filter.all
    @State private var expanded: String?
    @State private var keyDraft = ""
    @State private var busySlug: String?
    @State private var actionError: [String: String] = [:]
    @State private var addingAccountFor: String?
    @State private var confirmingDisconnect: HermesProviderRow?

    private var visible: [HermesProviderRow] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { row in
            (needle.isEmpty || row.name.lowercased().contains(needle) || row.slug.contains(needle))
                && (filter == .all || (filter == .connected) == row.authenticated)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    DockIcon(.magnifyingGlass).foregroundStyle(Color.dockMetadataText)
                    DockTextField("Search providers", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                        .dockSurfaceFill(Color.dockControlSurface, stroke: Color.dockBorder, lineWidth: DockLayout.hairline)
                )
                DockSegmentedPicker(selection: $filter, options: [(.all, "All"), (.connected, "Connected"), (.available, "Available")])
                Button { load() } label: {
                    if isLoading { ProgressView().controlSize(.small) } else { DockIcon(.arrowsClockwise) }
                }
                .buttonStyle(.dockHover)
                .help("Reload providers from Hermes")
                .disabled(isLoading)
            }

            if let loadError {
                ModalNote(text: loadError, icon: .warning, tone: .dockWarning)
            }

            let connected = visible.filter(\.authenticated)
            let available = visible.filter { !$0.authenticated }
            if !connected.isEmpty {
                section("Connected", count: connected.count, rows: connected)
            }
            if !available.isEmpty {
                section("Available", count: available.count, rows: available)
            }
            if visible.isEmpty && !isLoading && loadError == nil {
                Text(rows.isEmpty ? "Hermes hasn't reported any providers yet." : "No providers match.")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .task { load() }
        .sheet(item: Binding(get: { addingAccountFor.map(SheetProvider.init) }, set: { addingAccountFor = $0?.id })) { item in
            AddPoolAccountSheet(control: control, initialProvider: item.id, onAdded: { load() })
        }
        .confirmationDialog(
            "Disconnect \(confirmingDisconnect?.name ?? "provider")?",
            isPresented: Binding(get: { confirmingDisconnect != nil }, set: { if !$0 { confirmingDisconnect = nil } }),
            presenting: confirmingDisconnect
        ) { row in
            Button("Disconnect", role: .destructive) { disconnect(row) }
        } message: { _ in
            Text("Hermes removes this provider's saved key and signed-in accounts.")
        }
    }

    private struct SheetProvider: Identifiable { let id: String }

    private func section(_ title: String, count: Int, rows: [HermesProviderRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DockSectionLabel(title: title, count: count)
            VStack(spacing: 8) {
                ForEach(rows) { row in
                    providerRow(row)
                        .background(
                            RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous)
                                .dockSurfaceFill(Color.dockSurface.opacity(0.34))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous)
                                .stroke(Color.dockBorderLight, lineWidth: 0.5)
                        )
                }
            }
        }
    }

    private func poolCount(_ slug: String) -> Int {
        control.providerQuotas.filter { $0.hermesCredential?.provider == slug }.count
    }

    private func providerRow(_ row: HermesProviderRow) -> some View {
        let isExpanded = expanded == row.slug
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded = isExpanded ? nil : row.slug }
                keyDraft = ""
            } label: {
                HStack(spacing: 10) {
                    ProviderMarkBadge(mark: ProviderMark(hermesProvider: row.slug), size: 24)
                        .opacity(row.authenticated ? 1 : 0.6)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(row.name)
                                .dockFont(size: 12.5, weight: .semibold)
                                .foregroundStyle(Color.dockPrimaryText)
                            if row.isCurrent { tag("Current", color: .dockAccent) }
                        }
                        Text(subtitle(row))
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockMetadataText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    tag(accessTitle(row.access), color: .dockMetadataText)
                    DockIcon(isExpanded ? .caretDown : .caretRight)
                        .foregroundStyle(Color.dockMetadataText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockPress)
            .accessibilityLabel("\(row.name), \(row.authenticated ? "connected" : "not connected")")

            if isExpanded {
                detail(row)
                    .padding(.top, 12)
                    .padding(.horizontal, 12)
                    .padding(.leading, 34)
                    .padding(.bottom, 12)
            }
        }
    }

    private func subtitle(_ row: HermesProviderRow) -> String {
        var parts = [row.slug]
        if row.totalModels > 0 { parts.append("\(row.totalModels) model\(row.totalModels == 1 ? "" : "s")") }
        let pooled = poolCount(row.slug)
        if pooled > 0 { parts.append("\(pooled) pooled account\(pooled == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func accessTitle(_ access: HermesProviderRow.Access) -> String {
        switch access {
        case .apiKey: "API key"
        case .browser: "Sign-in"
        case .external: "External"
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .dockFont(.compactStatus, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Capsule().fill(Color.dockSurface4))
    }

    @ViewBuilder
    private func detail(_ row: HermesProviderRow) -> some View {
        let busy = busySlug == row.slug
        VStack(alignment: .leading, spacing: 10) {
            switch row.access {
            case .apiKey:
                HStack(spacing: 8) {
                    SecureField(row.keyEnv.map { "Paste \($0)" } ?? "Paste an API key", text: $keyDraft)
                        .textFieldStyle(.dockGlass)
                        .onSubmit { saveKey(row) }
                    Button(row.authenticated ? "Replace Key" : "Save Key") { saveKey(row) }
                        .buttonStyle(.dockPrimary)
                        .disabled(busy || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ModalNote(text: "Saved by Hermes in its own .env\(row.keyEnv.map { " as \($0)" } ?? "").", icon: .lockSimple)
            case .browser:
                ModalNote(text: row.authenticated
                    ? "Signed in. Add another account to let Hermes rotate between them."
                    : "Sign in through your browser. Hermes keeps the account in its credential pool.",
                    icon: .user)
            case .external:
                ModalNote(text: row.warning ?? "Configure this provider with Hermes' setup wizard.", icon: .info)
                HStack(spacing: 6) {
                    Text("hermes model")
                        .dockFont(size: 11.5, design: .monospaced)
                        .foregroundStyle(Color.dockPrimaryText)
                        .textSelection(.enabled)
                    DockCopyButton("hermes model", accessibilityLabel: "Copy command", presentation: .icon)
                        .buttonStyle(.dockPress)
                }
            }

            if let error = actionError[row.slug] {
                ModalNote(text: error, icon: .warning, tone: .dockWarning)
            }

            HStack(spacing: 8) {
                if row.access == .browser && !row.authenticated {
                    Button { addingAccountFor = row.slug } label: { DockIconLabel("Sign In", icon: .user) }
                        .buttonStyle(.dockPrimary)
                } else if row.access != .external {
                    Button { addingAccountFor = row.slug } label: { DockIconLabel("Add Pool Account", icon: .plus) }
                        .buttonStyle(.dockSecondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if row.authenticated && !row.isUserDefined && row.access != .external {
                    Button("Disconnect", role: .destructive) { confirmingDisconnect = row }
                        .buttonStyle(.dockSecondary)
                        .disabled(busy)
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Hermes RPC

    private func load() {
        isLoading = true
        Task {
            do {
                let result = try await model.quickWorkflowClient.request(
                    HermesFeatureIDs.ID.modelOptions.rawValue,
                    params: ["include_unconfigured": true]
                )
                control.hermesProviderRows = HermesProviderRow.rows(from: result)
                control.refreshProviderQuota(quiet: true)
                loadError = nil
            } catch {
                loadError = "Couldn't load providers from Hermes: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    private func saveKey(_ row: HermesProviderRow) {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        run(row, HermesFeatureIDs.ID.modelSaveKey, params: ["slug": row.slug, "api_key": key]) { keyDraft = "" }
    }

    private func disconnect(_ row: HermesProviderRow) {
        control.clearHermesStoredKey(slug: row.slug)
        run(row, HermesFeatureIDs.ID.modelDisconnect, params: ["slug": row.slug]) {}
    }

    private func run(_ row: HermesProviderRow, _ method: HermesFeatureIDs.ID, params: [String: Any], onSuccess: @escaping () -> Void) {
        busySlug = row.slug
        actionError[row.slug] = nil
        Task {
            do {
                _ = try await model.quickWorkflowClient.request(method.rawValue, params: params)
                onSuccess()
                load()
                control.refreshProviderQuota()
            } catch {
                actionError[row.slug] = error.localizedDescription
            }
            busySlug = nil
        }
    }
}
