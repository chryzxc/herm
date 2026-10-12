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
        BotFaceMark(id: bot.id, size: size)
    }
}

/// Hermes-style face: a flat colored shape with two eyes. Shape and color are
/// derived from the profile ID so a Bot always gets the same face.
struct BotFaceMark: View {
    let id: String
    var size: CGFloat = 160

    private var seed: UInt64 {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8.reduce(UInt64(14695981039346656037)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
    }

    var body: some View {
        let colors = BotAvatarPresentation.palette(for: id)
        let shape = BotFaceShape(kind: Int(seed / 360 % 5))
        let pupil = size * 0.045
        ZStack {
            shape.fill(colors[0]).frame(width: size * 0.82, height: size * 0.82)
            HStack(spacing: size * 0.1) {
                ForEach(0..<2, id: \.self) { _ in
                    Circle().fill(Color(white: 0.96))
                        .frame(width: size * 0.15, height: size * 0.15)
                        .overlay(Circle().fill(colors[1]).frame(width: pupil * 2, height: pupil * 2))
                }
            }
            .offset(y: size * 0.04)
        }
        .frame(width: size, height: size)
    }
}

private struct BotFaceShape: Shape {
    let kind: Int

    func path(in r: CGRect) -> Path {
        switch kind {
        case 0: return Circle().path(in: r)
        case 1: return RoundedRectangle(cornerRadius: r.width * 0.3, style: .continuous).path(in: r)
        case 2: return Capsule().path(in: r.insetBy(dx: r.width * 0.12, dy: 0))
        case 3: // drop
            var p = Path()
            let c = CGPoint(x: r.midX, y: r.maxY - r.width * 0.36), rad = r.width * 0.36
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: c.x + rad, y: c.y), control: CGPoint(x: c.x + rad, y: c.y - rad * 1.2))
            p.addArc(center: c, radius: rad, startAngle: .zero, endAngle: .degrees(180), clockwise: false)
            p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY), control: CGPoint(x: c.x - rad, y: c.y - rad * 1.2))
            return p
        default: // hexagon
            var p = Path()
            for i in 0..<6 {
                let a = Double(i) * .pi / 3 - .pi / 2
                let pt = CGPoint(x: r.midX + r.width / 2 * cos(a), y: r.midY + r.height / 2 * sin(a))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath()
            return p
        }
    }
}
