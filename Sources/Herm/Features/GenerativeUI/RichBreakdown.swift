import SwiftUI

struct RichBreakdown: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let label: String
        let value: Double
    }

    let items: [Item]
    var unit: String?

    func validate() -> Bool {
        !items.isEmpty && items.count <= 40 && RichIdentity.unique(items.map(\.id)) && (unit?.count ?? 0) <= 64
            && items.allSatisfy {
                !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.label.count <= 256
                    && $0.value.isFinite && $0.value >= 0
            }
    }

    func amount(_ item: Item) -> String {
        [item.value.formatted(.number.precision(.significantDigits(1...15))), unit].compactMap { $0 }.joined(
            separator: " ")
    }

    var plainText: String { items.map { "\($0.label): \(amount($0))" }.joined(separator: "\n") }
}

struct RichBreakdownView: View {
    let breakdown: RichBreakdown

    var body: some View {
        let largest = breakdown.items.map(\.value).max() ?? 0
        VStack(alignment: .leading, spacing: DockSpacing.group) {
            ForEach(breakdown.items) { item in
                VStack(alignment: .leading, spacing: DockSpacing.tight) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.label)
                            Spacer(minLength: DockSpacing.group)
                            amount(item)
                        }
                        VStack(alignment: .leading, spacing: DockSpacing.micro) {
                            Text(item.label)
                            amount(item)
                        }
                    }
                    DockProgressBar(fraction: largest > 0 ? item.value / largest : 0, tint: Color.dockAccent)
                }
                .accessibilityElement(children: .combine)
            }
        }.textSelection(.enabled)
    }

    private func amount(_ item: RichBreakdown.Item) -> some View {
        Text(breakdown.amount(item)).dockFont(.body, weight: .semibold).monospacedDigit()
    }
}
