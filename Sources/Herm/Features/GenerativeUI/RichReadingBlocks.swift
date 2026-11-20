import SwiftUI

struct RichCallout: Codable, Equatable, Sendable {
    enum Tone: String, Codable, CaseIterable, Sendable {
        case note, tip, important, warning, caution

        var icon: Ph {
            switch self {
            case .note: .info
            case .tip: .lightbulb
            case .important: .bookmarkSimple
            case .warning: .warning
            case .caution: .warningOctagon
            }
        }
    }

    let tone: Tone
    let body: String

    func validate() -> Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && body.utf8.count <= 16_384
    }

    var plainText: String { tone.rawValue.capitalized + "\n" + body }
}

struct RichFacts: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let label: String
        let value: String
    }

    let items: [Item]

    func validate() -> Bool {
        !items.isEmpty && items.count <= 100 && RichIdentity.unique(items.map(\.id))
            && items.allSatisfy {
                !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.label.count <= 256
                    && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value.utf8.count <= 8_192
            }
    }

    var plainText: String { items.map { "\($0.label): \($0.value)" }.joined(separator: "\n") }
}

struct RichCalloutView: View {
    let callout: RichCallout

    var body: some View {
        DockCallout(
            tone: callout.tone == .warning ? .warning : callout.tone == .caution ? .danger : .info,
            icon: callout.tone.icon, title: callout.tone.rawValue.capitalized
        ) {
            MarkdownMessageView(markdown: callout.body).equatable()
        }
    }
}

struct RichFactsView: View {
    let facts: RichFacts
    var inlineMarkdown = false
    @Environment(\.markdownOpenURL) private var openLink

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Grid(
                alignment: .leadingFirstTextBaseline, horizontalSpacing: DockSpacing.page,
                verticalSpacing: DockSpacing.control
            ) {
                ForEach(facts.items) { item in
                    GridRow {
                        label(item)
                        value(item)
                    }
                    if item.id != facts.items.last?.id { rule }
                }
            }
            VStack(alignment: .leading, spacing: DockSpacing.control) {
                ForEach(facts.items) { item in
                    VStack(alignment: .leading, spacing: DockSpacing.micro) {
                        label(item)
                        value(item)
                    }
                    if item.id != facts.items.last?.id { rule }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, openLink)
    }

    private func text(_ source: String) -> Text {
        inlineMarkdown
            ? Text(MarkdownMessageView.linkAffordances(in: MarkdownInlineParser.parse(source))) : Text(source)
    }

    private var rule: some View { Divider().gridCellUnsizedAxes(.horizontal) }
    private func label(_ item: RichFacts.Item) -> some View {
        text(item.label).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
    }
    private func value(_ item: RichFacts.Item) -> some View {
        text(item.value).dockFont(.body, weight: .medium).foregroundStyle(Color.dockPrimaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
