import SwiftUI

/// Shared identity hierarchy for the integration inspector and messaging setup.
struct IntegrationInspectorHeader<Icon: View, Status: View>: View {
    let title: String
    let category: String
    let scope: String
    let detail: String
    @ViewBuilder let icon: Icon
    @ViewBuilder let status: Status

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                icon.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).dockFont(.pageTitle, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    status
                }
                Spacer(minLength: 0)
            }
            if !detail.isEmpty, detail != title {
                Text(detail).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(category).dockFont(.body, weight: .semibold)
                Text(scope).dockFont(.body)
            }
            .foregroundStyle(Color.dockMetadataText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockPadding(.bottom, 4)
    }
}
