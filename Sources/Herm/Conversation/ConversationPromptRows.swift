import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ConversationPromptRows: View {
    let model: DockModel
    let conversationMetrics: ConversationWorkspaceMetrics
    var showsClarification = true
    var exclusive = false
    let state: ConversationPromptState

    init(
        model: DockModel, conversationMetrics: ConversationWorkspaceMetrics,
        showsClarification: Bool = true, exclusive: Bool = false
    ) {
        self.model = model
        self.conversationMetrics = conversationMetrics
        self.showsClarification = showsClarification
        self.exclusive = exclusive
        state = ConversationPromptState(model: model)
    }

    @State private var clarificationSelection: [String] = []
    @State private var valuePromptText = ""
    @State private var valuePromptIdentifier = ""

    var body: some View {
        Group {
            if let approval = state.approvalText {
                approvalRow(
                    state.approval
                        ?? ApprovalPresentation(
                            title: state.approvalTitle ?? "Review requested action", detail: approval,
                            detailIsCommand: state.approvalTitle == "Run command"))
            }
            if showsClarification, !exclusive || state.approvalText == nil, state.status == .needsClarification,
                state.question != nil
            {
                clarificationRow
            }
            if let prompt = state.prompt,
                !exclusive
                    || (state.approvalText == nil
                        && !(showsClarification && state.status == .needsClarification && state.question != nil))
            {
                valuePromptRow(prompt)
            }
        }
        .onChange(of: state.prompt?.requestID) { _, _ in
            valuePromptText = ""
            valuePromptIdentifier = ""
        }
        .onChange(of: state.sessionID) { _, _ in
            clarificationSelection = []
            valuePromptText = ""
            valuePromptIdentifier = ""
        }
        .onChange(of: state.question) { _, _ in clarificationSelection = [] }
    }
    func approvalRow(_ approval: ApprovalPresentation) -> some View {
        let isPending = state.approvalPending
        let choices = approval.choices
        let alwaysAllowCaption = ApprovalPresentation.alwaysAllowCaption(for: approval)
        return DockCallout(
            tone: .warning, icon: .shieldWarning, title: "Approval required", message: approval.title,
            badge: isPending ? "Sending…" : "Needs approval"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.vertical) {
                    Text(approval.detail)
                        .dockFont(.body, weight: .regular, design: approval.detailIsCommand ? .monospaced : .default)
                        .foregroundStyle(Color.dockPrimaryText)
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .dockPadding(.horizontal, 10)
                .dockPadding(.vertical, 8)
                .background(
                    DockThemeShape(cornerRadius: DockLayout.controlRadius)
                        .dockSurfaceFill(
                            Color.dockSurface2, stroke: Color.dockBorderLight, lineWidth: DockLayout.hairline)
                )

                if let reason = approval.reason {
                    DockCalloutDisclosure(title: "Scope and limits", text: reason)
                }

                DockCalloutActions {
                    if choices.contains(ApprovalChoice.once) {
                        Button {
                            if state.matchesApproval(in: model) { model.respondToApproval(ApprovalChoice.once) }
                        } label: {
                            DockActionLabel(
                                title: "Allow once", pendingTitle: "Allowing…", isPending: isPending,
                                tint: .dockPrimaryText
                            )

                        }
                        .buttonStyle(DockPrimaryButtonStyle())
                    }
                    if choices.contains(ApprovalChoice.session) {
                        Button {
                            if state.matchesApproval(in: model) { model.respondToApproval(ApprovalChoice.session) }
                        } label: {
                            Text("Allow this session")
                        }
                        .buttonStyle(DockSecondaryButtonStyle())
                        .help("Don't ask again for this command until the session ends.")
                    }
                    if choices.contains(ApprovalChoice.always) {
                        Button {
                            if state.matchesApproval(in: model) { model.respondToApproval(ApprovalChoice.always) }
                        } label: {
                            Text("Always allow")
                        }
                        .buttonStyle(DockSecondaryButtonStyle())
                        .help(alwaysAllowCaption)
                    }
                    Button(role: .destructive) {
                        if state.matchesApproval(in: model) { model.respondToApproval(ApprovalChoice.deny) }
                    } label: {
                        Text("Deny")
                    }
                    .buttonStyle(DockSecondaryButtonStyle())
                }
                .disabled(isPending)

                Text(
                    approval.smartDenied
                        ? "Hermes' safety check blocked this. You can override it once."
                        : choices.contains(ApprovalChoice.always) ? alwaysAllowCaption : "Herm asks again next time."
                )
                .dockFont(.body)
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dockButtonSize(.accessible)
        .dockPadding(.horizontal, conversationMetrics.contentInset + 4)
        .dockPadding(.vertical, 8)
    }

    /// The question itself stays in the transcript as Hermes' message; this
    /// card sits under it with the ways to answer.
    var clarificationRow: some View {
        let choices = state.choices
        let isMultiSelect = state.multiSelect
        let isPending = state.clarificationPending
        let isDisabled = isPending || state.restoring
        return DockCallout(
            tone: .info, icon: .question, title: "Clarification needed",
            message: state.progress, badge: isPending ? "Sending…" : "Needs answer"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if !choices.isEmpty {
                    Text(isMultiSelect ? "Choose one or more responses" : "Choose a response")
                        .dockFont(.body, weight: .medium)
                        .foregroundStyle(Color.dockSecondaryText)
                    VStack(spacing: 6) {
                        ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                            let isSelected = clarificationSelection.contains(choice)
                            Button {
                                guard state.matchesClarification(in: model) else { return }
                                if !isMultiSelect {
                                    model.respondToClarification(choice)
                                } else if isSelected {
                                    clarificationSelection.removeAll { $0 == choice }
                                } else {
                                    clarificationSelection.append(choice)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if isMultiSelect {
                                        DockIcon(
                                            isSelected ? .checkSquare : .square, size: 14,
                                            weight: isSelected ? .fill : .regular,
                                            color: isSelected ? .dockAccent : .dockMetadataText)
                                    }
                                    Text(choice)
                                        .dockFont(.body, weight: isSelected ? .semibold : .regular)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    if !isMultiSelect {
                                        DockIcon(.arrowRight, size: 12, color: .dockAccent)
                                    }
                                }
                                .frame(
                                    maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(DockSecondaryButtonStyle())
                            .overlay {
                                DockThemeShape(cornerRadius: DockLayout.controlRadius)
                                    .fill(isSelected ? Color.dockAccent.opacity(0.08) : Color.clear)
                                    .stroke(isSelected ? Color.dockAccent : Color.clear, lineWidth: DockLayout.hairline)
                                    .allowsHitTesting(false)
                            }
                            .accessibilityLabel(isMultiSelect ? choice : "Send suggested response: \(choice)")
                            .accessibilityAddTraits(isMultiSelect && isSelected ? .isSelected : [])
                        }
                    }
                    .controlSize(.small)
                    .disabled(isDisabled)
                }
                if isMultiSelect {
                    Button {
                        guard state.matchesClarification(in: model) else { return }
                        let selection = clarificationSelection
                        model.respondToClarification(
                            ClarifyQuestion.multiSelectAnswer(selection),
                            displayText: selection.joined(separator: ", "))
                    } label: {
                        DockActionLabel(
                            title: clarificationSelection.isEmpty
                                ? "Send selection" : "Send \(clarificationSelection.count) selected",
                            pendingTitle: "Sending…", isPending: isPending, tint: .dockPrimaryText
                        )

                    }
                    .buttonStyle(DockPrimaryButtonStyle())
                    .controlSize(.small)
                    .disabled(isDisabled || clarificationSelection.isEmpty)
                }
                Text(
                    choices.isEmpty ? "Type your answer in the message box below." : "Or type a different answer below."
                )
                .dockFont(.body)
                .foregroundStyle(Color.dockMetadataText)
            }
        }
        .dockButtonSize(.accessible)
        .dockPadding(.horizontal, conversationMetrics.contentInset + 4)
        .dockPadding(.vertical, 8)
    }

    func valuePromptRow(_ prompt: ValuePrompt) -> some View {
        let isPending = state.promptPending
        let canSubmit = !valuePromptText.isEmpty && (!prompt.asksForLogin || !valuePromptIdentifier.isEmpty)
        let submit = {
            guard canSubmit, !isPending, state.matchesPrompt(in: model) else { return }
            model.respondToValuePrompt(prompt.answer(value: valuePromptText, identifier: valuePromptIdentifier))
        }
        return DockCallout(
            tone: .warning, icon: prompt.isSecret ? .lockKey : .key, title: prompt.title,
            message: prompt.message, badge: isPending ? "Sending…" : "Input needed"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if prompt.asksForLogin {
                    Text("Username or email")
                        .dockFont(.body, weight: .medium)
                        .foregroundStyle(Color.dockSecondaryText)
                    DockTextField("Username or email", text: $valuePromptIdentifier)
                        .dockFont(.body)
                        .textFieldStyle(.dockGlass)
                        .textContentType(.username)
                        .disabled(isPending)
                }
                Text(prompt.fieldLabel)
                    .dockFont(.body, weight: .medium)
                    .foregroundStyle(Color.dockSecondaryText)
                Group {
                    if prompt.isSecret {
                        SecureField(prompt.fieldLabel, text: $valuePromptText)
                    } else {
                        TextField(prompt.fieldLabel, text: $valuePromptText)
                            .textContentType(.oneTimeCode)
                    }
                }
                .dockFont(.body)
                .textFieldStyle(.dockGlass)
                .disabled(isPending)
                .onSubmit(submit)

                DockCalloutActions {
                    Button(action: submit) {
                        DockActionLabel(
                            title: prompt.asksForLogin ? "Send login" : "Send", pendingTitle: "Sending…",
                            isPending: isPending, tint: .dockPrimaryText
                        )

                    }
                    .buttonStyle(DockPrimaryButtonStyle())
                    .disabled(!canSubmit)
                    Button {
                        if state.matchesPrompt(in: model) { model.respondToValuePrompt("") }
                    } label: {
                        Text("Skip")
                    }
                    .buttonStyle(DockSecondaryButtonStyle())
                }
                .disabled(isPending)

                Text(state.promptError ?? "Sent only to your local Hermes. Herm does not store it.")
                    .dockFont(.body)
                    .foregroundStyle(state.promptError == nil ? Color.dockMetadataText : Color.dockDestructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dockButtonSize(.accessible)
        .dockPadding(.horizontal, conversationMetrics.contentInset + 4)
        .dockPadding(.vertical, 8)
    }

}
