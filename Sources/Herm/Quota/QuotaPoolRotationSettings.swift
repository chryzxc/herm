import SwiftUI

struct QuotaPoolRotationSettings: View {
    typealias Strategy = HermesPoolRotationService.Strategy
    typealias Pool = HermesPoolRotationService.Pool

    @ObservedObject var model: HermesPoolRotationModel
    let providers: [HermesProviderRow]
    @State private var change: Change?

    private struct Change {
        let pool: Pool
        let name: String
        let strategy: Strategy
        let scope: HermesPoolRotationService.Scope
    }

    private static let rotationHelp = """
        Fill first (default) uses the first healthy account until it becomes unavailable.
        Round robin cycles through healthy accounts on each selection.
        Least used picks the account selected fewest times.
        Random picks a healthy account at random.
        """

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.visibleState {
            case .loading:
                SettingsPreferenceRow(title: "Reading Hermes account pools…", detail: "") {
                    DockLoadingIndicator().controlSize(.small)
                }
            case .ready(let pools) where pools.isEmpty:
                SettingsPreferenceRow(
                    title: "No Hermes account pools", detail: "Add an account to configure rotation."
                ) { EmptyView() }
            case .ready(let pools):
                ForEach(pools) { pool in
                    if pool.id != pools.first?.id { Divider().overlay(Color.dockBorderLight) }
                    rotationRow(pool)
                }
            case .unavailable(let message):
                SettingsPreferenceRow(title: "Account rotation unavailable", detail: message) {
                    DockAsyncButton("Retry") { await model.load() }
                        .buttonStyle(.dockSecondary)
                }
            }
        }
        .task(id: model.scope) { await model.load() }
        .confirmationDialog(
            "Change account rotation?",
            isPresented: Binding(get: { change != nil }, set: { if !$0 { change = nil } }),
            titleVisibility: .visible, presenting: change
        ) { change in
            Button("Change Rotation") {
                Task {
                    do {
                        try await model.save(change.strategy, for: change.pool, scope: change.scope)
                    } catch {
                        DockActionErrorCenter.shared.report("Couldn’t change account rotation", error: error)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { change in
            Text(
                "Hermes will use \(change.strategy.title) for all accounts in the \(change.name) pool when it next loads that pool. Other providers and already-loaded pools are unchanged."
            )
        }
    }

    private func rotationRow(_ pool: Pool) -> some View {
        let name = providers.first { $0.slug == pool.id }?.name ?? pool.id
        let scope = model.scope
        return SettingsPreferenceRow(title: name, detail: "") {
            ZStack {
                if model.savingPool == pool.id { DockLoadingIndicator().controlSize(.small) }
            }
            .frame(width: 16, height: 16)
            DockMenuPicker(
                title: pool.strategy.title,
                selection: Binding(
                    get: { pool.strategy },
                    set: { strategy in
                        guard strategy != pool.strategy, let scope else { return }
                        change = Change(pool: pool, name: name, strategy: strategy, scope: scope)
                    })
            ) {
                ForEach(Strategy.allCases, id: \.self) { strategy in
                    DockMenuOption(strategy.title, value: strategy)
                }
            }
            .dockFont(.control)
            .disabled(model.savingPool != nil)
            .help(Self.rotationHelp)
            .accessibilityLabel("\(name) account rotation")
            .accessibilityValue(pool.strategy.title)
            .accessibilityHint(Self.rotationHelp)
        }
    }
}
