import SwiftUI

extension WorkspaceActivitySidebar {
    var updatesContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "Software updates", subtitle: "", tint: .dockAccent) {
                SoftwareUpdateControls(appUpdater: appUpdater, agentUpdateService: agentUpdateService)
            }
            SettingsSection(title: "Agent compatibility", subtitle: "", tint: .dockAccent) {
                HermesCompatibilitySettings(installedVersion: agentUpdateService.installed?.displayVersion)
            }
            HermChangelogView()
        }
    }
}
