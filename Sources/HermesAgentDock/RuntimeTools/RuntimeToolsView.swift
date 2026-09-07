import SwiftUI

/// Read-only toolset and backend status surface. It deliberately exposes no
/// terminal, browser, computer-use, or LSP controls until Hermes publishes a
/// verified typed command contract.
struct RuntimeToolsView: View {
    let snapshot: ToolsetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("RUNTIME TOOLS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.dockSecondaryText)
                Spacer()
                if snapshot.restartRequired {
                    Text("NEXT SESSION")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.dockWarning)
                }
            }
            ForEach(snapshot.backends) { backend in
                HStack(spacing: 10) {
                    LucideImage(systemName: icon(for: backend.id))
                        .foregroundStyle(color(for: backend.state))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(backend.id.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockPrimaryText)
                        Text(backend.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockMetadataText)
                            .lineLimit(2)
                    }
                    Spacer()
                    Text(label(for: backend.state))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(color(for: backend.state))
                }
                .padding(10)
                .dockGlassPane()
            }
            if !snapshot.toolsets.isEmpty {
                Text("ENABLED TOOLSETS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Color.dockSecondaryText)
                    .padding(.top, 4)
                ForEach(snapshot.toolsets) { toolset in
                    LucideLabel(toolset.id, icon: toolset.isEnabled ? "checkmark.circle" : "circle")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(toolset.isEnabled ? Color.dockSuccess : Color.dockMetadataText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(for state: RuntimeBackendState) -> String {
        switch state { case .available: "AVAILABLE"; case .requiresSetup: "SETUP REQUIRED"; case .unavailable: "UNAVAILABLE"; case .unsupported: "UNSUPPORTED" }
    }

    private func color(for state: RuntimeBackendState) -> Color {
        switch state { case .available: .dockSuccess; case .requiresSetup: .dockWarning; case .unavailable, .unsupported: .dockMetadataText }
    }

    private func icon(for toolset: RuntimeToolset) -> String {
        switch toolset { case .terminal: "terminal"; case .browser: "globe"; case .computerUse: "cursorarrow.click"; case .lsp: "curlybraces" }
    }
}
