import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ApprovalCardKey: String {
    case returnKey
    case deleteKey
}

struct ApprovalCardKeyAction {
    static func choice(for key: ApprovalCardKey, isFocused: Bool, isPending: Bool) -> String? {
        guard isFocused, !isPending else { return nil }
        return switch key {
        case .returnKey: ApprovalChoice.once
        case .deleteKey: ApprovalChoice.deny
        }
    }
}

struct ConversationPromptRows: View {
    let model: DockModel
    let conversationMetrics: ConversationWorkspaceMetrics
    var showsClarification = true
    var exclusive = false
    let state: ConversationPromptState
    let conversationApproval: ConversationApproval?
    let approvalAnswer: AttentionAnswerState?
    let transcriptMode: Bool

    init(
        model: DockModel, conversationMetrics: ConversationWorkspaceMetrics,
        showsClarification: Bool = true, exclusive: Bool = false,
        conversationApproval: ConversationApproval? = nil, approvalAnswer: AttentionAnswerState? = nil,
        transcriptMode: Bool = false
    ) {
        self.model = model
        self.conversationMetrics = conversationMetrics
        self.showsClarification = showsClarification
        self.exclusive = exclusive
        self.conversationApproval = conversationApproval
        self.approvalAnswer = approvalAnswer
        self.transcriptMode = transcriptMode
        state = ConversationPromptState(model: model)
    }

    @State private var clarificationSelection: [String] = []
    @State private var valuePromptText = ""
    @State private var valuePromptIdentifier = ""
    @FocusState private var approvalCardIsFocused: Bool
    @State private var approvalKeyboardFocus = false
    @DockChromeTheme private var theme

    private var canAnswerApproval: Bool {
        state.matchesApproval(in: model) && model.sessionActionsReady
            && (conversationApproval == nil || model.currentConversationApproval?.id == conversationApproval?.id)
    }

    var body: some View {
        Group {
            if let record = conversationApproval {
                approvalRow(record.approval)
            } else if !transcriptMode, let approval = state.approvalText {
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
        let resolved = conversationApproval?.resolved == true
        let isPending = state.approvalPending || approvalAnswer?.blocksSubmission == true
        let choices = approval.choices
        let badge: String? =
            switch approvalAnswer {
            case .uncertain: "Delivery uncertain"
            case .checking: "Checking…"
            case .failed: "Not sent"
            default: isPending ? "Sending…" : nil
            }
        let alwaysAllowCaption = ApprovalPresentation.alwaysAllowCaption(for: approval)
        return DockCallout(
            tone: .warning, icon: .shieldWarning, title: "Approval required", message: approval.title,
            badge: resolved ? "Resolved" : badge
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
                .dockWell()

                if let reason = approval.reason {
                    DockCalloutDisclosure(title: "Scope and limits", text: reason)
                }

                if !resolved {
                    approvalActions(
                        choices, alwaysAllowCaption: alwaysAllowCaption, isPending: isPending,
                        note: approval.smartDenied ? nil : "Herm asks again next time.")

                    if let answer = approvalAnswer {
                        Text(answer.message)
                            .dockFont(.body)
                            .foregroundStyle(Color.dockMetadataText)
                        if case .uncertain = answer, let record = conversationApproval {
                            Button("Check request") {
                                guard model.currentConversationApproval?.id == record.id else { return }
                                if let target = record.target {
                                    model.recheckAttention(target)
                                } else {
                                    model.recheckLegacyApproval(record.id)
                                }
                            }
                            .buttonStyle(DockSecondaryButtonStyle())
                        }
                    }

                    if approval.smartDenied {
                        approvalNote("Hermes' safety check blocked this. You can override it once.")
                    }
                }
            }
        }
        .overlay {
            if approvalCardIsFocused && approvalKeyboardFocus && !resolved {
                DockThemeShape(cornerRadius: DockLayout.controlRadius)
                    .stroke(Color.dockAccent, lineWidth: 2)
                    .padding(1)
                    .allowsHitTesting(false)
            }
        }
        .focusable(!resolved)
        .focusEffectDisabled()
        .focused($approvalCardIsFocused)
        .onChange(of: approvalCardIsFocused) { _, focused in
            approvalKeyboardFocus = focused && NSApp.currentEvent?.type == .keyDown
        }
        .onKeyPress(keys: [.return, "\u{3}", .delete], phases: .down) { press in
            guard press.modifiers.intersection([.shift, .command, .option, .control]).isEmpty else { return .ignored }
            let key: ApprovalCardKey = press.key == .delete ? .deleteKey : .returnKey
            guard
                let choice = ApprovalCardKeyAction.choice(
                    for: key, isFocused: approvalCardIsFocused, isPending: isPending || resolved),
                choices.contains(choice), canAnswerApproval
            else { return .ignored }
            model.respondToApproval(choice)
            return .handled
        }
        .onChange(of: state.approvalText) { _, value in
            if value == nil { approvalCardIsFocused = false }
        }
        .onChange(of: resolved) { _, value in
            if value { approvalCardIsFocused = false }
        }
        .dockButtonSize(.compact)
        .dockPadding(.horizontal, conversationMetrics.contentInset + 4)
        .dockPadding(.vertical, 8)
    }

    private func approvalActions(_ choices: [String], alwaysAllowCaption: String, isPending: Bool, note: String?)
        -> some View
    {
        Group {
            if choices.contains(ApprovalChoice.session) || choices.contains(ApprovalChoice.always) {
                let scopeNote =
                    choices.contains(ApprovalChoice.always)
                    ? alwaysAllowCaption : "Herm asks again after this session."
                ViewThatFits(in: .horizontal) {
                    VStack(alignment: .leading, spacing: DockSpacing.control) {
                        DockCalloutActions(alignment: .trailing) {
                            HStack(spacing: DockSpacing.section) {
                                HStack(spacing: DockSpacing.control) {
                                    approvalScopeButtons(choices, alwaysAllowCaption: alwaysAllowCaption)
                                }
                                .buttonStyle(.dockSecondary)
                                HStack(spacing: DockSpacing.control) {
                                    approvalDecisionButtons(choices, isPending: isPending, compact: false)
                                }
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        approvalNote(scopeNote)
                    }
                    DockCalloutActions(alignment: .trailing) {
                        DockChipFlow(spacing: DockSpacing.control, hugsContent: true) {
                            approvalScopeMenu(choices, alwaysAllowCaption: alwaysAllowCaption, note: scopeNote)
                            approvalDecisionButtons(choices, isPending: isPending, compact: true)
                        }
                    }
                }
            } else {
                DockCalloutActions(alignment: .trailing, note: note) {
                    DockChipFlow(spacing: DockSpacing.control, hugsContent: true) {
                        approvalDecisionButtons(choices, isPending: isPending, compact: false)
                    }
                }
            }
        }
        .disabled(isPending || !canAnswerApproval)
    }

    @ViewBuilder
    private func approvalScopeButtons(_ choices: [String], alwaysAllowCaption: String) -> some View {
        if choices.contains(ApprovalChoice.session) {
            Button("Allow this session") {
                if canAnswerApproval { model.respondToApproval(ApprovalChoice.session) }
            }
            .help("Don't ask again for this command until the session ends.")
        }
        if choices.contains(ApprovalChoice.always) {
            Button("Always allow") {
                if canAnswerApproval { model.respondToApproval(ApprovalChoice.always) }
            }
            .help(alwaysAllowCaption)
        }
    }

    private func approvalScopeMenu(_ choices: [String], alwaysAllowCaption: String, note: String) -> some View {
        DockMenu(outlined: true) {
            DockMenuSection("Approval duration") {
                approvalScopeButtons(choices, alwaysAllowCaption: alwaysAllowCaption)
                approvalNote(note)
                    .frame(width: 220, alignment: .leading)
                    .dockPadding(.horizontal, DockSpacing.control)
                    .dockPadding(.vertical, DockSpacing.micro)
            }
        } label: {
            DockIcon(.dotsThreeOutline, size: 16, weight: .fill)
        }
        .help("More approval options")
        .accessibilityLabel("More approval options")
    }

    @ViewBuilder
    private func approvalDecisionButtons(_ choices: [String], isPending: Bool, compact: Bool) -> some View {
        if choices.contains(ApprovalChoice.deny) {
            let denyHint = "Press Delete to deny while the approval card is focused."
            Button(role: .destructive) {
                if canAnswerApproval { model.respondToApproval(ApprovalChoice.deny) }
            } label: {
                HStack(spacing: DockSpacing.control) {
                    Text("Deny")
                    if !compact { approvalKeyHint(.backspace, ink: .dockSecondaryText) }
                }
            }
            .buttonStyle(.dockSecondary)
            .help(denyHint)
            .accessibilityHint(denyHint)
        }
        if choices.contains(ApprovalChoice.once) {
            allowOnceButton(isPending: isPending, compact: compact)
        }
    }

    private func approvalNote(_ note: String) -> some View {
        Text(note)
            .dockFont(.body)
            .foregroundStyle(Color.dockMetadataText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func allowOnceButton(isPending: Bool, compact: Bool) -> some View {
        let hint = "Press Return or Enter to allow once when the card is focused or visible above an empty composer."
        let ink = DockPrimaryButtonStyle.foregroundColor(theme)
        let isAllowing =
            approvalAnswer == .sending(ApprovalChoice.once)
            || (approvalAnswer == nil && state.approvalPending)
        return Button {
            if canAnswerApproval { model.respondToApproval(ApprovalChoice.once) }
        } label: {
            HStack(spacing: DockSpacing.control) {
                DockActionLabel(
                    title: "Allow once", pendingTitle: "Allowing…", isPending: isAllowing, tint: ink,
                    icon: compact ? nil : .check)
                approvalKeyHint(.arrowElbowDownLeft, ink: ink)
            }
        }
        .buttonStyle(.dockPrimary)
        .help(hint)
        .accessibilityHint(hint)
        .background {
            if let id = conversationApproval?.id, canAnswerApproval, !isPending {
                GeometryReader { geometry in
                    let button = CGRect(origin: .zero, size: geometry.size)
                    let viewport = geometry.bounds(of: .scrollView(axis: .vertical))
                    Color.clear.preference(
                        key: VisibleApprovalShortcutKey.self,
                        value: viewport?.contains(button) == true ? id : nil
                    )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    private func approvalKeyHint(_ icon: Ph, ink: Color) -> some View {
        DockIcon(icon, size: 14, weight: .fill, color: ink)
            .dockPill(tint: ink, compact: true, outline: ink.opacity(0.2))
            .accessibilityHidden(true)
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
                    .disabled(isDisabled || clarificationSelection.isEmpty)
                }
                Text(
                    choices.isEmpty ? "Type your answer in the message box below." : "Or type a different answer below."
                )
                .dockFont(.body)
                .foregroundStyle(Color.dockMetadataText)
            }
        }
        .dockButtonSize(.compact)
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
        .dockButtonSize(.compact)
        .dockPadding(.horizontal, conversationMetrics.contentInset + 4)
        .dockPadding(.vertical, 8)
    }

}
