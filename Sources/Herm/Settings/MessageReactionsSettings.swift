import SwiftUI

/// Hermes' `display.message_reactions` switch. It gates the agent's
/// `react_to_message` tool, so Hermes owns the value; this row reads it back
/// and shows the new state only after Hermes accepts the write.
struct MessageReactionsSettings: View {
    let model: DockModel
    @State private var isOn = false
    @State private var isLoaded = false
    @State private var isSaving = false

    var body: some View {
        SettingsPreferenceRow(
            title: "Bot reactions",
            detail: "Let Hermes answer with an emoji on a message, like a tapback, when a reply would add nothing."
        ) {
            Toggle(
                "Bot reactions",
                isOn: Binding(get: { isOn }, set: { save($0) })
            )
            .labelsHidden().toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
            .disabled(!isLoaded || isSaving)
        }
        .task { await load() }
    }

    private func load() async {
        let params = model.scopedSessionParams(["key": "full"], profileID: model.profileScopeID)
        guard
            let result = try? await model.sessionRPCClient.request(
                HermesFeatureIDs.ID.configGet.rawValue, params: params),
            let config = result["config"] as? [String: Any]
        else { return }
        isOn = (config["display"] as? [String: Any])?["message_reactions"] as? Bool ?? false
        isLoaded = true
    }

    private func save(_ value: Bool) {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let params = model.scopedSessionParams(
                    ["key": "display.message_reactions", "value": value ? "true" : "false"],
                    profileID: model.profileScopeID)
                let result = try await model.sessionRPCClient.request(
                    HermesFeatureIDs.ID.configSet.rawValue, params: params)
                guard result["key"] as? String == "display.message_reactions", let confirmed = result["value"] as? Bool
                else { throw HermesGateway.GatewayError.malformedResponse }
                isOn = confirmed
            } catch {
                model.actionErrors.report("Could not change bot reactions", error: error)
            }
        }
    }
}
