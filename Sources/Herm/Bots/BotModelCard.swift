import SwiftUI

/// A bot's model setup: the primary model and the ordered fallbacks Hermes
/// tries when it fails. New Bot (page and Settings modal) and Edit Bot share it
/// so creating and editing a bot read the same.
struct BotModelCard<Footer: View>: View {
    typealias Choices = [(provider: String, models: [String])]

    let choices: Choices
    @Binding var primary: BotRuntimeConfig.ModelRef?
    /// What a nil `primary` means, e.g. "Hermes default".
    let unsetTitle: String
    /// New bots can go back to the default; an existing pin cannot be cleared through Hermes.
    var offersUnset = true
    @Binding var fallbacks: [BotRuntimeConfig.ModelRef]
    /// False while the profile's runtime config is still loading.
    var fallbacksEditable = true
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                rowTitle("Primary", detail: "Answers every message")
                Spacer(minLength: 8)
                modelMenu(selected: primary, offersUnset: offersUnset, outlined: false, exclude: []) {
                    primary = $0
                } label: {
                    HStack(spacing: 8) {
                        modelName(primary, placeholder: unsetTitle, alignment: .trailing)
                        DockIcon(.caretUpDown, size: 11, color: Color.dockMetadataText)
                    }
                    .dockPadding(.horizontal, 8)
                    .dockPadding(.vertical, 4)
                }
            }
            .dockPadding(.horizontal, 12)
            .dockPadding(.vertical, 10)
            Divider()
            fallbackRows
            footer
        }
        .dockCard(padding: 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: fallbacks)
    }

    private var fallbackRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            rowTitle("Fallbacks", detail: "Tried in order when the primary fails")
            ForEach(Array(fallbacks.enumerated()), id: \.offset) { index, ref in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .dockFont(.metadata, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(Color.dockMetadataText)
                        .frame(width: 14)
                    modelName(ref, placeholder: "", alignment: .leading)
                    Spacer(minLength: 8)
                    Button {
                        fallbacks.remove(at: index)
                    } label: {
                        DockIcon(.x, size: 10, color: Color.dockSecondaryText).frame(width: 20, height: 20)
                    }
                    .buttonStyle(.dockHover)
                    .help("Remove \(ref.model)")
                    .accessibilityLabel("Remove \(ref.model)")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            modelMenu(
                selected: nil, offersUnset: false, outlined: true, exclude: fallbacks + (primary.map { [$0] } ?? [])
            ) {
                if let ref = $0 { fallbacks.append(ref) }
            } label: {
                Label("Add Fallback", icon: .plus)
            }
            .disabled(!fallbacksEditable || choices.isEmpty)
            .dockButtonSize(.compact)
        }
        .dockPadding(.horizontal, 12)
        .dockPadding(.vertical, 10)
    }

    private func rowTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
            Text(detail).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
        }
    }

    private func modelName(_ ref: BotRuntimeConfig.ModelRef?, placeholder: String, alignment: HorizontalAlignment)
        -> some View
    {
        VStack(alignment: alignment, spacing: 1) {
            Text(ref?.model ?? placeholder)
                .dockFont(.body, weight: .medium)
                .foregroundStyle(Color.dockPrimaryText)
            if let provider = ref?.provider {
                Text(provider).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    /// Every model Hermes reports, grouped by provider in one scrolling menu.
    private func modelMenu(
        selected: BotRuntimeConfig.ModelRef?, offersUnset: Bool, outlined: Bool, exclude: [BotRuntimeConfig.ModelRef],
        pick: @escaping (BotRuntimeConfig.ModelRef?) -> Void, @ViewBuilder label: () -> some View
    ) -> some View {
        DockMenu(outlined: outlined) {
            if offersUnset {
                DockMenuCheckRow(title: unsetTitle, isSelected: selected == nil) { pick(nil) }
            }
            if choices.isEmpty {
                Text("Hermes reported no models").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    .dockPadding(8)
            }
            ForEach(choices, id: \.provider) { choice in
                let models = choice.models.filter { model in
                    !exclude.contains { $0.provider == choice.provider && $0.model == model }
                }
                if !models.isEmpty {
                    DockMenuSection(choice.provider) {
                        ForEach(models, id: \.self) { model in
                            DockMenuCheckRow(
                                title: model,
                                isSelected: selected?.provider == choice.provider && selected?.model == model
                            ) { pick(.init(provider: choice.provider, model: model)) }
                        }
                    }
                }
            }
        } label: {
            label()
        }
    }
}

extension BotModelCard where Footer == EmptyView {
    init(
        choices: Choices, primary: Binding<BotRuntimeConfig.ModelRef?>, unsetTitle: String, offersUnset: Bool = true,
        fallbacks: Binding<[BotRuntimeConfig.ModelRef]>, fallbacksEditable: Bool = true
    ) {
        self.init(
            choices: choices, primary: primary, unsetTitle: unsetTitle, offersUnset: offersUnset,
            fallbacks: fallbacks, fallbacksEditable: fallbacksEditable
        ) { EmptyView() }
    }
}

/// Role and purpose, worded the same when creating and editing a bot.
struct BotIdentityFields: View {
    @Binding var role: String
    @Binding var purpose: String

    var body: some View {
        labeledField("Role", hint: "Optional; shown beside the name") {
            DockTextField("e.g. Travel Agent", text: $role).textFieldStyle(.dockGlass)
        }
        labeledField("What should this bot help with?", hint: "Optional") {
            DockTextField("Plans trips, compares flights and hotels…", text: $purpose, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.dockGlass)
        }
    }
}
