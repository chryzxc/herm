import SwiftUI

private struct ConversationRowBounds: PreferenceKey {
    struct Row {
        let target: MessageNavigatorTarget
        let index: Int
        let bounds: Anchor<CGRect>
    }

    static let defaultValue: [Row] = []

    static func reduce(value: inout [Row], nextValue: () -> [Row]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func conversationRowBounds(target: MessageNavigatorTarget, index: Int) -> some View {
        anchorPreference(key: ConversationRowBounds.self, value: .bounds) {
            [.init(target: target, index: index, bounds: $0)]
        }
    }

    /// Resolve the entire batch in document coordinates with one geometry reader.
    func conversationRowGeometry<Measured: View>(
        @ViewBuilder measured: @escaping ([MessageNavigatorViewport]) -> Measured
    ) -> some View {
        backgroundPreferenceValue(ConversationRowBounds.self) { rows in
            GeometryReader { geometry in
                measured(
                    rows.map { row in
                        let frame = geometry[row.bounds]
                        return MessageNavigatorViewport(
                            target: row.target, index: row.index, minY: frame.minY, maxY: frame.maxY)
                    })
            }
        }
    }
}
