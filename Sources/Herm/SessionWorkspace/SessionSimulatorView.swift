import SwiftUI

struct SessionSimulatorView: View {
    let platform: SessionSimulatorPlatform
    let sessionKey: String
    let isActive: Bool
    @ObservedObject private var launches = SessionSimulatorLaunchStore.shared
    @StateObject private var capture: SessionSimulatorCapture
    @State private var refreshRequest = 0
    @State private var consumedCallID: String?
    @State private var showSetup = false

    init(
        platform: SessionSimulatorPlatform, sessionKey: String, isActive: Bool,
        capture: SessionSimulatorCapture = SessionSimulatorCapture()
    ) {
        self.platform = platform
        self.sessionKey = sessionKey
        self.isActive = isActive
        _capture = StateObject(wrappedValue: capture)
    }

    var presentation: some View {
        VStack(spacing: 0) {
            deviceToolbar
            GeometryReader { geometry in
                if let image = capture.image {
                    SessionSimulatorCanvas(capture: capture, image: image)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.dockDeviceCanvas)
                } else {
                    ScrollView {
                        recoveryContent
                            .frame(maxWidth: 400, alignment: .leading)
                            .padding(24)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height)
                    }
                }
            }
            deviceControls
        }
        .foregroundStyle(Color.dockPrimaryText)
        .background(Color.dockCanvas)
    }

    var body: some View {
        presentation
            .task(id: "\(isActive)-\(refreshRequest)-\(capture.selectedID)-\(launchRequest?.callID ?? "")") {
                guard isActive else {
                    capture.stop()
                    return
                }
                var preferredID: String?
                if let request = launchRequest, consumedCallID != request.callID {
                    consumedCallID = request.callID
                    preferredID = request.receipt.deviceID
                }
                capture.refresh(platform, preferredID: preferredID)
            }
            .onDisappear { capture.stop() }
    }

    private var deviceToolbar: some View {
        HStack(spacing: 8) {
            DockIcon(.deviceMobile, size: 14, color: Color.dockSecondaryText)
            Picker("Device", selection: $capture.selectedID) {
                Text("Choose device…").tag("")
                ForEach(capture.devices) { device in Text(device.name).tag(device.id) }
                if !capture.selectedID.isEmpty && !capture.devices.contains(where: { $0.id == capture.selectedID }) {
                    Text("Selected device unavailable").tag(capture.selectedID)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(capture.isLoading)
            ProgressView().controlSize(.small).frame(width: 16)
                .opacity(capture.isLoading ? 1 : 0)
                .accessibilityHidden(!capture.isLoading)
            Button(capture.image == nil ? "Refresh" : "Reconnect") { refreshRequest += 1 }
                .buttonStyle(.dockSecondary)
        }
        .padding(10)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    private var recoveryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(capture.isLoading ? "Connecting to \(platform.title)" : "Connect a device")
                .dockFont(.body, weight: .semibold)
            Text(capture.message)
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { recoveryActions }
                VStack(alignment: .leading, spacing: 8) { recoveryActions }
            }
            if showSetup {
                Text(
                    "Run Scripts/setup-simulator-bridge.sh from the Herm project. "
                        + (platform == .ios
                            ? "Install the local iOS companion with brew install facebook/fb/idb-companion and select a compatible full Xcode installation."
                            : "Install Android SDK Emulator. Start the AVD with -no-window -grpc-use-token, or ask your chat to launch it.")
                )
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
                .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var recoveryActions: some View {
        Button("Retry connection") { refreshRequest += 1 }
            .buttonStyle(.dockSecondary)
        Button("Setup instructions") { showSetup.toggle() }
            .buttonStyle(.dockSecondary)
    }

    private var deviceControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { controlActions }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], alignment: .leading, spacing: 8) {
                controlActions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!capture.inputAllowed)
        .padding(10)
        .overlay(alignment: .top) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    @ViewBuilder private var controlActions: some View {
        if platform == .android {
            Button("Back") { capture.button("back") }.buttonStyle(.dockSecondary)
            Button("Apps") { capture.button("apps") }.buttonStyle(.dockSecondary)
        }
        Button("Home") { capture.button("home") }.buttonStyle(.dockSecondary)
        Button("Power") { capture.button("power") }.buttonStyle(.dockSecondary)
    }

    private var launchRequest: SessionSimulatorLaunchStore.Request? {
        launches.request(for: sessionKey, platform: platform)
    }
}
