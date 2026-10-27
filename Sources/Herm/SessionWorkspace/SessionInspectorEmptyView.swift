import SwiftUI

struct SessionInspectorEmptyView: View {
    let onOpen: (SessionInspector.Section) -> Void

    private let suggestions: [(SessionInspector.Section, String)] = [
        (.browser, "Open a page or search the web"),
        (.terminal, "Run commands in your workspace"),
        (.files, "Browse project files"),
        (.artifacts, "Explore this session’s outputs"),
        (.changes, "Review repository changes"),
        (.timeline, "Inspect session activity"),
    ]

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
                    ForEach(suggestions, id: \.0) { section, detail in
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
                                Text(detail)
                                    .dockFont(.body)
                                    .foregroundStyle(Color.dockSecondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(Color.dockPrimaryText)
                            .multilineTextAlignment(.leading)
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(Color.dockSurface)
                            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius))
                            .overlay {
                                RoundedRectangle(cornerRadius: DockLayout.controlRadius)
                                    .strokeBorder(Color.dockBorder, lineWidth: DockLayout.hairline)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .accessibilityLabel("Open \(section.navigationTitle) tab")
                    }
                }
            }
            .frame(maxWidth: 480)
            .padding(DockSpacing.inspectorInset)
            .padding(.top, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.dockCanvas)
    }
}
