import SwiftUI

struct SessionInspectorEmptyView: View {
    let sections: [SessionInspector.Section]
    let onOpen: (SessionInspector.Section) -> Void

    private func detail(_ section: SessionInspector.Section) -> String {
        switch section {
        case .browser: "Open a page or search the web"
        case .terminal: "Run commands in your workspace"
        case .files: "Browse project files"
        case .artifacts: "Explore this session’s outputs"
        case .changes: "Review repository changes"
        case .timeline: "Inspect session activity"
        case .diff: "Review the attached diff"
        case .github: "Follow the linked pull request or issue"
        case .iosSimulator: "Run the app in an iOS Simulator"
        case .androidEmulator: "Run the app in an Android Emulator"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open a new tab")
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("Choose a tool to use alongside your conversation.")
                        .dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                    ForEach(sections) { section in
                        Button {
                            onOpen(section)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    DockIcon(section.icon, size: 16, color: .dockSecondaryText)
                                    Text(section.navigationTitle)
                                        .dockFont(.body, weight: .semibold)
                                    Spacer(minLength: 0)
                                    DockIcon(.plus, size: 12, color: .dockSecondaryText)
                                }
                                Text(detail(section))
                                    .dockFont(.body)
                                    .foregroundStyle(Color.dockSecondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(Color.dockPrimaryText)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .dockCard(padding: 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .accessibilityLabel("Open \(section.navigationTitle) tab")
                    }
                }
            }
            .frame(maxWidth: 480)
            .dockPadding(DockSpacing.inspectorInset)
            .dockPadding(.top, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.dockCanvas)
    }
}
