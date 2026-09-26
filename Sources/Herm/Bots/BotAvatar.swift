import SwiftUI

/// Deterministic visual identity for built-in Bot roles. Stored Hermes assets
/// still take precedence; this only improves the local fallback avatar.
enum BotAvatarPresentation {
    static func symbol(for profileID: String) -> Ph {
        switch profileID.lowercased() {
        case "nexus": return .compassTool
        case "cypher": return .shield
        case "atlas": return .globe
        case "archon": return .bank
        case "canvas": return .palette
        case "ripple": return .pencilLine
        case "forge": return .hammer
        case "sentry": return .eye
        case "sentinel": return .shieldCheck
        case "aegis": return .hardDrives
        case "probe": return .flask
        case "beacon": return .broadcast
        case "scout": return .binoculars
        default: return .userCircle
        }
    }

    static func palette(for profileID: String) -> [Color] {
        // Profile IDs are Hermes-owned and can be added or renamed. FNV-1a is
        // stable across launches, unlike Swift's randomized Hasher, so every
        // dynamic bot keeps the same fallback identity without a role table.
        let normalized = profileID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let seed = normalized.utf8.reduce(UInt64(14695981039346656037)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        let hue = normalized.isEmpty ? 0.68 : Double(seed % 360) / 360
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
            if let imageData, let image = Self.decoded(imageData) {
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

    /// Rows re-render on every scroll frame; decode each avatar once.
    private static let images = NSCache<NSData, NSImage>()

    private static func decoded(_ data: Data) -> NSImage? {
        let key = data as NSData
        if let cached = images.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: key)
        return image
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
            DockIcon(BotAvatarPresentation.symbol(for: bot.id))
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
                .shadow(color: .black.opacity(0.22), radius: size * 0.06, y: size * 0.04)
        }
    }
}
