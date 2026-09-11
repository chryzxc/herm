import SwiftUI

/// Deterministic visual identity for built-in Bot roles. Stored Hermes assets
/// still take precedence; this only improves the local fallback avatar.
enum BotAvatarPresentation {
    static func symbol(for profileID: String) -> String {
        switch profileID.lowercased() {
        case "nexus": return "compass.drawing"
        case "cypher": return "shield.fill"
        case "atlas": return "globe"
        case "archon": return "building.columns.fill"
        case "canvas": return "paintpalette.fill"
        case "ripple": return "pencil.and.outline"
        case "forge": return "hammer.fill"
        case "sentry": return "eye.fill"
        case "sentinel": return "checkmark.shield.fill"
        case "aegis": return "server.rack"
        case "scout": return "binoculars.fill"
        default: return "person.crop.circle"
        }
    }

    static func palette(for profileID: String) -> [Color] {
        let hue: Double
        switch profileID.lowercased() {
        case "nexus": hue = 0.82
        case "cypher": hue = 0.56
        case "atlas": hue = 0.37
        case "archon": hue = 0.13
        case "canvas": hue = 0.29
        case "ripple": hue = 0.95
        case "forge": hue = 0.04
        case "sentry": hue = 0.61
        case "sentinel": hue = 0.46
        case "aegis": hue = 0.72
        case "scout": hue = 0.33
        default: hue = 0.68
        }
        return [
            Color(hue: hue, saturation: 0.58, brightness: 0.82),
            Color(hue: hue, saturation: 0.72, brightness: 0.42)
        ]
    }
}

/// Avatar rendering with Bot Mode's fallback behavior: the profile's stored
/// asset when Hermes has one, otherwise a deterministic role mark derived from
/// the Bot's profile ID so the same Bot always looks the same.
struct BotAvatarView: View {
    let bot: BotSummary
    let imageData: Data?
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            if let imageData, let image = NSImage(data: imageData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                deterministicFace
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(Color.dockBorderLight.opacity(0.6), lineWidth: 0.5)
        )
        .opacity(bot.isHidden ? 0.45 : 1)
    }

    private var deterministicFace: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: BotAvatarPresentation.palette(for: bot.id),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .stroke(.white.opacity(0.20), lineWidth: max(0.6, size * 0.018))
                .frame(width: size * 0.64, height: size * 0.64)
            LucideImage(systemName: BotAvatarPresentation.symbol(for: bot.id))
                .font(.system(size: size * 0.34, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(0.96))
                .shadow(color: .black.opacity(0.22), radius: size * 0.06, y: size * 0.04)
        }
    }
}
