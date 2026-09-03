import SwiftUI

/// Avatar rendering with Bot Mode's fallback behavior: the profile's stored
/// asset when Hermes has one, otherwise a deterministic face derived from
/// the Bot's name so the same Bot always looks the same.
struct BotAvatarView: View {
    let bot: BotSummary
    let imageData: Data?
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let imageData, let image = NSImage(data: imageData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
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

    private var initials: String {
        let source = (bot.title ?? bot.name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return "?" }
        let words = source.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? String(source.prefix(1)).uppercased() : letters.uppercased()
    }

    private var deterministicFace: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [hueColor.opacity(0.85), hueColor.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(initials)
                .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .minimumScaleFactor(0.6)
        }
    }

    private var hueColor: Color {
        var hash = 5381
        for scalar in bot.id.unicodeScalars { hash = (hash << 5) &+ hash &+ Int(scalar.value) }
        return Color(hue: Double(abs(hash) % 360) / 360.0, saturation: 0.55, brightness: 0.72)
    }
}
