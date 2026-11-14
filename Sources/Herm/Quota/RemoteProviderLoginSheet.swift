import AppKit
import SwiftUI

/// Backend-owned device sign-in; no credentials are returned to Herm.
struct RemoteProviderLoginSheet: View {
    @ObservedObject var control: ControlCenterModel
    let provider: String
    @StateObject private var login = HermesRemoteProviderLoginService()
    @Environment(\.dismiss) private var dismiss
    @State private var binding: UInt64 = 0
    @State private var profile: String?
    @State private var identity: ObjectIdentifier?
    @State private var closing = false

    var body: some View {
        DockModal(
            title: "Backend sign-in", subtitle: "Sign in to \(provider) on the Hermes backend.", onClose: requestClose
        ) {
            VStack(alignment: .leading, spacing: 16) {
                ModalNote(text: login.message, icon: .info)
                Text("Profile: \(HermesRemoteProviderService.profileName(profile))")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
                if let info = login.startInfo {
                    Text(info.code).dockFont(.rowTitle, weight: .semibold)
                    ViewThatFits(in: .horizontal) {
                        HStack { verificationActions(info) }
                        VStack(alignment: .leading) { verificationActions(info) }
                    }
                } else if !login.approved {
                    Text(ProviderBackendAvailability.remoteAuthMessage)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockMetadataText)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        } footer: {
            Spacer()
            Button(login.approved || login.cancellationInDoubt ? "Done" : "Cancel") {
                requestClose()
            }
            .buttonStyle(.dockSecondary)
            if !login.approved && !login.busy && !login.cancellationInDoubt {
                Button("Start Sign-In") { begin() }.buttonStyle(.dockPrimary)
            }
        }
        .interactiveDismissDisabled(login.busy || closing)
        .onAppear { profile = control.dockModel?.profileScopeID }
        .onChange(of: login.message) { _, message in
            NSAccessibility.post(
                element: NSApp.mainWindow ?? NSApp, notification: .announcementRequested,
                userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        .onDisappear { Task { _ = await login.cancel() } }
        .onReceive(control.objectWillChange) { _ in
            if login.busy && !isCurrent { Task { _ = await login.cancel() } }
        }
    }

    private func requestClose() {
        guard !closing else { return }
        closing = true
        Task {
            await Self.cancelAndDismiss(login: login) { dismiss() }
            closing = false
        }
    }

    static func cancelAndDismiss(login: HermesRemoteProviderLoginService, dismiss: () -> Void) async {
        if login.busy, !(await login.cancel()) { return }
        dismiss()
    }

    @ViewBuilder private func verificationActions(_ info: HermesRemoteProviderLoginService.Start) -> some View {
        Button("Open Verification Page") { ExternalOpen.open(info.url) }.buttonStyle(.dockPrimary)
        DockCopyButton(info.code, accessibilityLabel: "Copy sign-in code")
    }

    private var isCurrent: Bool {
        control.isCurrentClient(identity, bindingGeneration: binding) && control.dockModel?.profileScopeID == profile
    }

    private func begin() {
        guard let model = control.dockModel else { return }
        binding = control.clientBindingGeneration
        profile = model.profileScopeID
        identity = ObjectIdentifier(model.controlRPCClient)
        login.begin(
            client: model.quickWorkflowClient, profile: profile, provider: provider,
            current: { isCurrent },
            onApproved: {
                control.refreshProviderQuota()
                Task { try? await control.loadHermesProviderRows() }
            })
    }
}
