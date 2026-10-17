import AppKit
import ServiceManagement
import SwiftUI
import Foundation
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
        case .agent: [.runtime, .providers, .chat, .memory, .voice, .advanced]
        case .tools: [.workspace, .browser, .safety, .integrations]
        case .activity: [.session, .project, .diagnostics, .updates]
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
    case chat
    case workspace
    case safety
    case browser
    case memory
    case voice
    case advanced
    case integrations
    case session
    case project
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
        case .chat: "Chat"
        case .workspace: "Files & terminal"
        case .safety: "Privacy & safety"
        case .browser: "Browser"
        case .memory: "Memory & Context"
        case .voice: "Voice"
        case .advanced: "Advanced"
        case .integrations: "Integrations"
        case .session: "Active session"
        case .project: "Project checks"
        case .diagnostics: "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Startup and keyboard shortcuts"
        case .gateway: "Local, remote, SSH, and Hermes Cloud connections"
        case .appearance: "Themes, sidebar, notch, and companion"
        case .notifications: "Completion alerts and repository changes"
        case .updates: "Herm and Hermes versions and updates"
        case .runtime: "Models, dispatch, and tools"
        case .providers: "Accounts, API keys, and sign-in"
        case .chat: "Personality, timezone, and attachments"
        case .workspace: "Working directory, shell, and file access"
        case .safety: "Approvals, privacy, and checkpoints"
        case .browser: "Browser profile and private URLs"
        case .memory: "Persistent memory and context compression"
        case .voice: "Voice chat, speech to text, and text to speech"
        case .advanced: "Agent limits, subagents, and output limits"
        case .integrations: "Permissions and connected services"
        case .session: "Active session controls and context"
        case .project: "Repository facts and verification"
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
        case .chat: .chatText
        case .workspace: .folder
        case .safety: .shieldWarning
        case .browser: .link
        case .memory: .brain
        case .voice: .microphone
        case .advanced: .cpu
        case .integrations: .shieldCheck
        case .session: .pulse
        case .project: .sealCheck
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint == .dockWarning ? Color.dockWarning : Color.dockPrimaryText)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous)
                    .fill(Color.dockSurface.opacity(0.34))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous)
                    .stroke(Color.dockBorderLight, lineWidth: 0.5)
            )
        }
    }
}

struct SettingsPreferenceRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.dockPrimaryText)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .frame(minHeight: 52)
    }
}

struct SettingsStatusRow: View {
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockPrimaryText)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText).lineLimit(3)
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
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dockPrimaryText)
                if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText).lineLimit(2) }
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
            Circle().fill(tint).frame(width: 7, height: 7).padding(.top, 4)
            Text(text).font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

struct SettingsInventoryList<Content: View>: View {
    let emptyMessage: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let emptyMessage, !emptyMessage.isEmpty {
                Text(emptyMessage).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
            } else {
                content()
            }
        }
    }
}

/// The session inspector is deliberately a separate surface from the workspace.
/// Workspace navigation answers "what needs attention overall?"; this panel
/// answers "what is happening in this conversation?".
