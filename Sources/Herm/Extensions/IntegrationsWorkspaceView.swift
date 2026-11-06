import SwiftUI

struct IntegrationsWorkspaceView: View {
    @ObservedObject var state: IntegrationsWorkspaceState

    var body: some View {
        DockExpandedPage(
            title: "Integrations", subtitle: state.status, showsClose: false, close: {}, trailing: { headerActions }
        ) {
            VStack(spacing: 0) {
                categoryNavigation
                Color.dockBorderLight.frame(height: DockLayout.hairline)
                if state.category == .messaging {
                    MessagingWorkspaceView(workspace: state)
                } else if let section = state.category.section {
                    WorkflowIntegrationView(workspace: state, section: section)
                }
            }
        }
        .dockFont(.body)
        .task(id: state.category) { await state.load() }
        .task { state.profiles = await BotService(client: state.workflow.client).rosterList().bots }
        .onDisappear { state.close() }
        .confirmationDialog("Discard unsaved integration changes?", isPresented: $state.showsLeaveConfirmation) {
            Button("Keep editing", role: .cancel) { state.keepEditing() }
            Button("Discard changes", role: .destructive) { state.discardAndLeave() }
        } message: {
            Text("Your changes have not been saved. Keep editing to save them, or discard them before leaving.")
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if state.category == .connectors {
                Text("Account connections").dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            } else {
                DockMenu {
                    DockMenuSection("Configure profile") {
                        profileOption("Launch profile", nil)
                        ForEach(state.profiles) { profile in profileOption(profile.name, profile.id) }
                    }
                } label: {
                    DockIconLabel(state.profileName, icon: .user)
                }
                .buttonStyle(.dockSecondary).disabled(state.navigationLocked)
                .help("Choose which Hermes profile to configure")
            }
            Button {
                Task { await state.load(force: true) }
            } label: {
                DockActionLabel(title: "Refresh", pendingTitle: "Refreshing…", isPending: state.busy)
            }
            .buttonStyle(.dockSecondary).disabled(state.navigationLocked)
        }
        .dockButtonSize(.compact)
    }

    private func profileOption(_ title: String, _ id: String?) -> some View {
        Button {
            Task { await state.useProfile(id) }
        } label: {
            HStack {
                Text(title)
                if state.profileID == id { DockIcon(.check) }
            }
        }
    }

    private var categoryNavigation: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                ForEach([IntegrationsCategory.skills, .plugins, .tools, .connectors, .mcp, .messaging]) { category in
                    Button {
                        state.selectCategory(category)
                    } label: {
                        HStack(spacing: 8) {
                            DockIcon(category.icon, size: 16)
                            Text(category.title).dockFont(
                                .body, weight: state.category == category ? .semibold : .regular)
                            if let count = state.count(category) {
                                Text(count.formatted()).dockFont(.metadata).monospacedDigit()
                                    .foregroundStyle(Color.dockMetadataText)
                            }
                        }
                        .foregroundStyle(Color.dockPrimaryText)
                        .dockPadding(.horizontal, 14).dockPadding(.vertical, 12)
                        .dockSelectionBackground(
                            DockThemeShape(cornerRadius: DockLayout.controlRadius),
                            active: state.category == category, fill: Color.dockSurface4, allowsInvert: false
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .accessibilityAddTraits(state.category == category ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            DockMenuPicker(
                title: state.category.title,
                selection: Binding(get: { state.category }, set: { state.selectCategory($0) })
            ) {
                ForEach(IntegrationsCategory.allCases) { category in
                    DockMenuOption(category.title, value: category)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(state.navigationLocked)
        .dockPadding(.horizontal, 20).dockPadding(.vertical, 8)
    }
}
