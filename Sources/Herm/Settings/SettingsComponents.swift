import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsCategoryGroup: String, CaseIterable, Identifiable {
    case app = "App"
    case agent = "Agent"
    case tools = "Tools & access"
    case activity = "Activity & maintenance"

    var id: Self { self }

    var categories: [SettingsCategory] {
        switch self {
        case .app: [.general, .gateway, .appearance, .notifications]
        case .agent: [.runtime, .providers, .bots, .chat, .memory, .voice, .advanced]
        case .tools: [.workspace, .browser, .safety, .integrations]
        case .activity: [.session, .diagnostics, .updates]
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case gateway
    case appearance
    case notifications
    case runtime
    case providers
    case bots
    case chat
    case workspace
    case safety
    case browser
    case memory
    case voice
    case advanced
    case integrations
    case session
    case diagnostics
    case updates

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .gateway: "Gateway"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .updates: "Updates"
        case .runtime: "Models & tools"
        case .providers: "Providers"
        case .bots: "Bots"
        case .chat: "Chat"
        case .workspace: "Files & terminal"
        case .safety: "Privacy & safety"
        case .browser: "Browser"
        case .memory: "Memory & Context"
        case .voice: "Voice"
        case .advanced: "Advanced"
        case .integrations: "Integrations"
        case .session: "Active session"
        case .diagnostics: "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Startup, keyboard shortcuts, power, and restart"
        case .gateway: "Connections and the local messaging gateway"
        case .appearance: "Themes, sidebar, notch, and companion"
        case .notifications: "Completion alerts and repository changes"
        case .updates: "Herm and Hermes versions and updates"
        case .runtime: "Models, dispatch, and tools"
        case .providers: "Accounts, API keys, sign-in, and account rotation"
        case .bots: "Create, edit, and remove bots and their routines"
        case .chat: "Layout, typing, replies, session titles, and attachments"
        case .workspace: "Working directory, shell, file access, and output limits"
        case .safety: "Approvals, screen capture, privacy, and checkpoints"
        case .browser: "Browser profile and private URLs"
        case .memory: "Persistent memory and context compression"
        case .voice: "Voice chat, speech to text, and text to speech"
        case .advanced: "Agent limits and subagents"
        case .integrations: "Permissions and connected services"
        case .session: "Active session controls and context"
        case .diagnostics: "Observed health and storage"
        }
    }

    var icon: Ph {
        switch self {
        case .general: .slidersHorizontal
        case .gateway: .globe
        case .appearance: .sparkle
        case .notifications: .bell
        case .updates: .arrowsClockwise
        case .runtime: .gearSix
        case .providers: .key
        case .bots: .ghost
        case .chat: .chatText
        case .workspace: .folder
        case .safety: .shieldWarning
        case .browser: .link
        case .memory: .brain
        case .voice: .microphone
        case .advanced: .cpu
        case .integrations: .shieldCheck
        case .session: .pulse
        case .diagnostics: .stethoscope
        }
    }
}

enum SettingsLayoutMode: Equatable {
    case rail
    case menu

    static func forWidth(_ width: CGFloat) -> Self {
        width >= 760 ? .rail : .menu
    }
}

struct SettingsCategoryBadge: Equatable {
    enum Kind: Equatable {
        case dot
        case count(Int)
    }

    let kind: Kind
    let isWarning: Bool
}

struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        // Grouped-card pattern: the heading sits outside a single quiet card so
        // a page reads as a short list of groups, not a stack of hairlines.
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .dockFont(.navigation, weight: .semibold)
                    .foregroundStyle(tint == .dockWarning ? Color.dockWarning : Color.dockPrimaryText)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .dockPadding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dockCard(padding: DockSpacing.section)
        }
    }
}

struct SettingsPreferenceRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        SettingsPreferenceLayout {
            summary
            // A builder may emit zero or several views; the layout owns exactly two slots.
            HStack(spacing: DockSpacing.control) { control() }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .dockFont(.navigation, weight: .medium)
                .foregroundStyle(Color.dockPrimaryText)
            if !detail.isEmpty {
                Text(detail)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Keep small controls trailing; only wide controls move below the readable label column.
private struct SettingsPreferenceLayout: Layout {
    private func measurements(_ subviews: Subviews, width: CGFloat?) -> (CGSize, CGSize, Bool, CGFloat) {
        let control = subviews[1].sizeThatFits(.unspecified)
        let available = width ?? subviews[0].sizeThatFits(.unspecified).width + control.width + DockSpacing.section
        let horizontal = available >= 160 + control.width + DockSpacing.section
        let textWidth = horizontal ? available - control.width - DockSpacing.section : available
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
        return (text, control, horizontal, available)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (text, control, horizontal, width) = measurements(subviews, width: proposal.width)
        return CGSize(
            width: width,
            height: horizontal ? max(text.height, control.height) : text.height + DockSpacing.group + control.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (text, control, horizontal, _) = measurements(subviews, width: bounds.width)
        let textWidth = horizontal ? bounds.width - control.width - DockSpacing.section : bounds.width
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: horizontal ? bounds.midY - text.height / 2 : bounds.minY),
            proposal: ProposedViewSize(width: textWidth, height: text.height))
        subviews[1].place(
            at: CGPoint(
                x: horizontal ? bounds.maxX - control.width : bounds.minX,
                y: horizontal ? bounds.midY - control.height / 2 : bounds.minY + text.height + DockSpacing.group),
            proposal: ProposedViewSize(control))
    }
}

struct SettingsStatusRow: View {
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7).dockPadding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).dockFont(.body, weight: .medium).foregroundStyle(Color.dockPrimaryText)
                if !detail.isEmpty {
                    Text(detail).dockFont(.metadata).foregroundStyle(Color.dockMetadataText).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
    }
}

struct SettingsActionRow<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let actions: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).dockFont(.navigation, weight: .medium).foregroundStyle(Color.dockPrimaryText)
                if !detail.isEmpty {
                    Text(detail).dockFont(.metadata).foregroundStyle(Color.dockMetadataText).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            actions()
        }
        .frame(minHeight: 52)
    }
}

struct SettingsInlineNotice: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(tint).frame(width: 7, height: 7).dockPadding(.top, 4)
            Text(text).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).fixedSize(
                horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .dockPadding(.vertical, 8)
    }
}

struct SettingsInventoryList<Content: View>: View {
    let emptyMessage: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let emptyMessage, !emptyMessage.isEmpty {
                Text(emptyMessage).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
            } else {
                content()
            }
        }
    }
}

/// The session inspector is deliberately a separate surface from the workspace.
/// Workspace navigation answers "what needs attention overall?"; this panel
/// answers "what is happening in this conversation?".
