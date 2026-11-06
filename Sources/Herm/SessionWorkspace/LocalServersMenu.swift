import SwiftUI

struct LocalServersMenu: View {
    @Environment(\.localPreviewDiscoveryVisible) private var surfaceVisible
    @Environment(\.dockHostVisible) private var hostVisible
    let processIDs: [Int32]
    var active = true
    @StateObject private var discovery = LocalPreviewDiscoveryModel()
    @State private var isOpen = false
    private var isActive: Bool { active && surfaceVisible && hostVisible && isOpen }
    private var scope: String { processIDs.map(String.init).joined(separator: ",") + ":\(isActive)" }
    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            LocalPreviewsLabel()
        }
        .buttonStyle(.dockCompact)
        .help("Open a local development preview")
        .accessibilityLabel("Local previews")
        .dockPopover(isPresented: $isOpen, arrowEdge: .bottom) {
            LocalPreviewsPanel(
                servers: discovery.servers, isRefreshing: discovery.isRefreshing, error: discovery.error,
                refresh: { Task { await discovery.refresh() } },
                open: { server in
                    isOpen = false
                    InAppBrowser.open(server.url)
                })
        }
        .task(id: scope) {
            discovery.configure(processIDs: processIDs, active: isActive)
            guard isActive else {
                isOpen = false
                return
            }
            while !Task.isCancelled {
                await discovery.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .onChange(of: hostVisible) { _, visible in if !visible { isOpen = false } }
        .onChange(of: surfaceVisible) { _, visible in if !visible { isOpen = false } }
        .onDisappear {
            isOpen = false
            discovery.configure(processIDs: processIDs, active: false)
        }
    }
}

struct LocalPreviewsLabel: View {
    var body: some View {
        HStack(spacing: DockSpacing.tight) {
            DockIcon(.globe).dockFont(.body)
            Text("Previews").dockFont(.control)
            DockIcon(.caretDown).dockFont(.compactStatus, weight: .regular)
        }.foregroundStyle(Color.dockPrimaryText)
    }
}

struct LocalPreviewsPanel: View {
    let servers: [LocalPreviewServer]
    let isRefreshing: Bool
    let error: String?
    let refresh: () -> Void
    let open: (LocalPreviewServer) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DockSpacing.group) {
                VStack(alignment: .leading, spacing: DockSpacing.micro) {
                    Text("Local previews").dockFont(.body, weight: .semibold)
                    Text(
                        error != nil && !servers.isEmpty
                            ? "Previous results · refresh failed" : "From this session’s terminals"
                    )
                    .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                }
                Spacer(minLength: 0)
                DockIconButton(
                    icon: .arrowsClockwise, label: "Refresh local previews", isBusy: isRefreshing, size: 24,
                    style: DockThemePalette(theme: DockThemeRuntime.current), action: refresh)
            }.dockPadding(DockSpacing.group)
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            if servers.isEmpty {
                VStack(alignment: .leading, spacing: DockSpacing.control) {
                    Text(
                        error != nil
                            ? "Couldn’t find previews"
                            : isRefreshing ? "Looking for local previews…" : "No local previews"
                    )
                    .dockFont(.body, weight: .semibold)
                    Text(
                        error
                            ?? (isRefreshing
                                ? "Checking local listeners in these terminals."
                                : "Start a development server in a Herm terminal, then refresh.")
                    )
                    .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading).dockPadding(
                    .horizontal, DockSpacing.group)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(servers) { server in
                            Button {
                                open(server)
                            } label: {
                                HStack(spacing: DockSpacing.group) {
                                    DockIcon(.globe).foregroundStyle(Color.dockSecondaryText)
                                    VStack(alignment: .leading, spacing: DockSpacing.micro) {
                                        Text(server.processName ?? "Process \(server.pid)")
                                            .dockFont(.body, weight: .semibold).lineLimit(1).truncationMode(
                                                .middle)
                                        Text(server.url.absoluteString).dockFont(
                                            .metadata, weight: .regular, design: .monospaced
                                        )
                                        .fontDesign(.monospaced)
                                        .foregroundStyle(Color.dockSecondaryText).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    DockIcon(.arrowUpRight).foregroundStyle(Color.dockSecondaryText)
                                }
                                .dockPadding(DockSpacing.group).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.dockHover)
                            .help("Open \(server.url.absoluteString) in the session browser")
                            .accessibilityLabel("Open \(server.processName ?? "process") on port \(server.port)")
                        }
                    }
                }.frame(height: min(248, CGFloat(servers.count) * 64))
                if let error {
                    Text(error).dockFont(.metadata).foregroundStyle(Color.dockWarning)
                        .dockPadding(.horizontal, DockSpacing.group).dockPadding(.bottom, DockSpacing.control)
                }
            }
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            Text("Opens in the session browser. Nothing starts automatically.")
                .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).dockPadding(DockSpacing.group)
        }
        .frame(width: 320).foregroundStyle(Color.dockPrimaryText)
        .background(Color.dockCanvas).dockThemedRoot()
    }
}

private struct LocalPreviewDiscoveryVisibleKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var localPreviewDiscoveryVisible: Bool {
        get { self[LocalPreviewDiscoveryVisibleKey.self] }
        set { self[LocalPreviewDiscoveryVisibleKey.self] = newValue }
    }
}
