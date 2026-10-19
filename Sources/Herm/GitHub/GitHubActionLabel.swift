import SwiftUI

/// Keeps pending feedback inside the action without changing its control style.
struct GitHubActionLabel: View {
    let title: String
    let isBusy: Bool
    var body: some View {
        HStack(spacing: 6) {
            if isBusy { ProgressView().controlSize(.mini).frame(width: 12, height: 12) }
            Text(title)
        }
    }
}
