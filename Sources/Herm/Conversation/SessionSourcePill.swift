import SwiftUI

/// A session's reported origin, shared by conversation list rows.
struct SessionSourcePill: View {
    let title: String

    private var icon: Ph {
        switch title {
        case "Discord": .discordLogo
        case "WhatsApp": .whatsappLogo
        case "Telegram": .telegramLogo
        case "Slack": .slackLogo
        case "Email": .envelope
        case "BlueBubbles": .appleLogo
        case "Google Chat": .googleLogo
        case "Microsoft Teams": .microsoftTeamsLogo
        default: .chatCenteredText
        }
    }

    private var tint: Color {
        switch title {
        case "Discord": .dockDiscord
        case "WhatsApp": DockAccentColor.green.color
        default: .dockSecondaryText
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            DockIcon(icon, size: 12)
            Text(title).dockFont(.metadata, weight: .medium)
        }
        .foregroundStyle(tint)
        .dockPill(tint: tint)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Source: \(title)")
        .help("Session from \(title)")
    }
}

/// The bot that owns a conversation in the all-profiles list: avatar and
/// name, the same identity a bot reply shows in the chat.
struct SessionProfilePill: View {
    let bot: BotSummary
    let imageData: Data?

    var body: some View {
        HStack(spacing: 4) {
            BotAvatarView(bot: bot, imageData: imageData, size: 14, animated: false, orbits: false)
            Text(bot.name)
                .dockFont(.metadata, weight: .medium)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Color.dockSecondaryText)
        .dockPill(compact: true)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bot: \(bot.name)")
    }
}
