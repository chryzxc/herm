import SwiftUI

/// Shared method selection and primary action; the landing host owns confirmation and writes.
struct PullRequestMergeButton: View {
    @Binding var method: GitHubMergeMethod
    let methods: [GitHubMergeMethod]
    var isBusy = false
    var enabled = true
    var selectionEnabled = true
    var help = "Choose a merge method, then confirm the merge."
    var onShowRequirements: (() -> Void)? = nil
    let action: () -> Void
    @Environment(\.dockWorkspaceScale) private var scale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Group {
                    if isBusy {
                        ProgressView().controlSize(.mini).frame(width: 16, height: 16)
                    } else {
                        DockIcon(.gitMerge, size: 16)
                    }
                    Text(method.actionTitle).lineLimit(1)
                }
                .opacity(enabled ? 1 : 0.42)
                Color.clear.frame(width: DockWorkspaceScale.points(22, scale: scale), height: 1)
            }
        }
        .buttonStyle(DockPrimaryButtonStyle(dimsWhenDisabled: false))
        .controlSize(.small)
        .disabled(!enabled)
        .accessibilityLabel(method.actionTitle)
        .accessibilityHint(help)
        .dockHoverTip(help)
        .overlay(alignment: .trailing) {
            DockMenu {
                ForEach(methods) { option in
                    Button {
                        method = option
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            DockIcon(.check, size: 14).opacity(method == option ? 1 : 0)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option == .merge ? "Create a merge commit" : option.title)
                                    .dockFont(.body, weight: .semibold)
                                Text(option.detail).dockFont(.body)
                                    .foregroundStyle(Color.dockSecondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(width: 280, alignment: .leading).padding(.vertical, 6)
                    }
                    .accessibilityAddTraits(method == option ? .isSelected : [])
                }
                if let onShowRequirements {
                    Divider()
                    Button("View merge requirements", action: onShowRequirements)
                }
            } label: {
                DockIcon(.caretDown, size: 12)
                    .foregroundStyle(DockPrimaryButtonStyle.foregroundColor)
                    .frame(
                        width: DockWorkspaceScale.points(28, scale: scale),
                        height: DockWorkspaceScale.points(26, scale: scale)
                    )
                    .overlay(alignment: .leading) {
                        DockPrimaryButtonStyle.foregroundColor.opacity(0.3)
                            .frame(width: 1, height: DockWorkspaceScale.points(14, scale: scale))
                    }
            }
            .disabled(!selectionEnabled || (methods.isEmpty && onShowRequirements == nil))
            .accessibilityLabel("Choose merge method")
            .accessibilityValue(method.title)
            .help("Choose merge method")
        }
        .fixedSize()
    }
}
