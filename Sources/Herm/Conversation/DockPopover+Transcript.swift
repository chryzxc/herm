import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension DockPopover {
    func chatScroll(trailingContentInset: CGFloat) -> some View {
        ConversationTranscriptView(
            model: model, controlCenter: controlCenter, botMode: botMode,
            messageActionState: messageActionState, voiceOutput: voiceOutput,
            conversationMetrics: conversationMetrics, conversationHermFaceID: conversationHermFaceID,
            isShowingMessageSearch: $isShowingMessageSearch, pinnedMessageJumpID: $pinnedMessageJumpID,
            selectedChatImage: $selectedChatImage, trailingContentInset: trailingContentInset,
            latestJumpRequest: sessionRailReplyRequest
        ).equatable()
            .environment(\.sessionPreviewWorkspace, WorkspaceIdentity.session(model))
    }
    func reasoningBlock(_ reasoning: ReasoningState) -> some View {
        DisclosureGroup(isExpanded: $model.isShowingReasoning) {
            Text(reasoning.text.isEmpty ? "…" : reasoning.text)
                .dockFont(.body)
                .textSelection(.enabled)
                .foregroundStyle(Color.dockSecondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dockPadding(.vertical, 4)
        } label: {
            HStack(spacing: 5) {
                DockIcon(.brain)
                    .dockFont(.body)
                Text("Reasoning")
                    .dockFont(.body, weight: .medium)
                if !reasoning.isComplete {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                }
            }
            .foregroundStyle(Color.dockSecondaryText)
        }
        .disclosureGroupStyle(DockDisclosureGroupStyle())
        .dockPadding(.horizontal, 10)
        .dockPadding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .dockSurfaceFill(Color.dockSurface, stroke: Color.dockBorderLight, lineWidth: 0.5)
        )
    }

    func quickPromptChip(_ quickPrompt: QuickPrompt) -> some View {
        let requiredCapability = quickPrompt.requiredCapability
        let isAvailable = requiredCapability.map(controlCenter.capabilityAvailable) ?? true
        return Button(quickPrompt.label) {
            selectQuickPrompt(quickPrompt)
        }
        .buttonStyle(.dockCompact)
        .dockFont(.body, weight: .medium)
        .foregroundStyle(isAvailable ? Color.dockSecondaryText : Color.dockMetadataText)
        .dockPadding(.horizontal, 9)
        .frame(minHeight: 26)
        .fixedSize(horizontal: true, vertical: false)
        .background(Capsule().fill(Color.dockSurface4).stroke(Color.dockBorderLight, lineWidth: 0.5))
        .disabled(!isAvailable)
        .help(isAvailable ? quickPrompt.label : unavailableCapabilityDetail(requiredCapability))
    }

    var quickPromptOverflowMenu: some View {
        DockMenu {
            ForEach(QuickPrompt.allCases.dropFirst(2)) { quickPrompt in
                Button(quickPrompt.label) {
                    selectQuickPrompt(quickPrompt)
                }
                .disabled(quickPrompt.requiredCapability.map(controlCenter.capabilityAvailable) == false)
            }
        } label: {
            DockIconLabel("More", icon: .dotsThree)
                .dockFont(.body, weight: .medium)
                .foregroundStyle(Color.dockSecondaryText)
                .dockPadding(.horizontal, 9)
                .frame(minHeight: 26)
                .background(Capsule().fill(Color.dockSurface4).stroke(Color.dockBorderLight, lineWidth: 0.5))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    func selectQuickPrompt(_ quickPrompt: QuickPrompt) {
        model.draft = quickPrompt.prompt
        model.requestComposerFocus()
    }

    func unavailableCapabilityDetail(_ id: String?) -> String {
        guard let id, let capability = controlCenter.capabilities.first(where: { $0.id == id }) else {
            return "This Hermes capability is unavailable. Open Settings and refresh capabilities."
        }
        return capability.recovery ?? capability.detail
    }
}
