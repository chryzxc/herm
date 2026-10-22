import SwiftUI

/// One drawing context per avatar under a shared indicator clock. Uploaded art
/// is clipped to the avatar tile; Herm faces draw their effects past it.
struct DockBotOrbitCanvas: View {
    let id: String
    let image: NSImage?
    let size: CGFloat
    let mood: BotMood
    let pose: BotFacePose
    @ObservedObject private var themeStore = DockThemeStore.shared

    var body: some View {
        let theme = themeStore.selectedThemeID
        Canvas { context, box in
            var avatar = context
            avatar.translateBy(x: (box.width - size) / 2, y: (box.height - size) / 2)
            if let image {
                let rect = CGRect(x: 0, y: 0, width: size, height: size)
                avatar.clip(to: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).path(in: rect))
                let zoom = 1.03 + pose.bob
                let aspect = image.size.width / max(1, image.size.height)
                let width = max(size, size * aspect) * zoom
                let height = max(size, size / max(0.001, aspect)) * zoom
                avatar.draw(Image(nsImage: image), in: CGRect(x: (size - width) / 2, y: (size - height) / 2,
                                                            width: width, height: height))
            } else {
                BotFaceMark.draw(in: &avatar, id: id, size: size, mood: mood, pose: pose, theme: theme)
            }
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

extension BotFaceMark {
    /// The pre-Herm Faces blob, still and idle. Only kept so avatars saved to
    /// Hermes before the redesign are still recognized as Herm faces.
    static func drawLegacyBlob(in ctx: inout GraphicsContext, id: String, size s: CGFloat) {
        let genes = BotBlobGenes(id: id)
        let ink = GraphicsContext.Shading.color(Color(white: 0.08, opacity: 0.88))
        let eye = s * genes.eyeSize
        let gap = s * genes.eyeGap
        let body = BotBlobShape(genes: genes).path(in: CGRect(x: 0, y: 0, width: s, height: s))
        ctx.fill(body, with: .color(Color(hue: BotAvatarPresentation.hue(for: id), saturation: 0.58, brightness: 0.82)))
        ctx.fill(body, with: .linearGradient(Gradient(colors: [.white.opacity(0.22), .clear]),
                                             startPoint: .zero, endPoint: CGPoint(x: s / 2, y: s / 2)))
        if genes.cheeks {
            let w = eye * 1.25, h = eye * 0.7, dx = (gap + eye * 1.2 + w) / 2
            let blush = Color(hue: 0.97, saturation: 0.55, brightness: 1).opacity(0.45)
            for side in [-1.0, 1.0] {
                ctx.fill(Path(ellipseIn: CGRect(x: s / 2 + side * dx - w / 2, y: s * (genes.eyeY + 0.075) - h / 2, width: w, height: h)),
                         with: .color(blush))
            }
        }
        let eyeY = s * genes.eyeY
        for side in [-1.0, 1.0] {
            let h = eye * genes.eyeTall
            let x = s / 2 + side * (gap + eye) / 2
            ctx.fill(Path(ellipseIn: CGRect(x: x - eye / 2, y: eyeY - h / 2, width: eye, height: h)), with: ink)
            let d = eye * 0.36
            ctx.fill(Path(ellipseIn: CGRect(x: x - eye / 2 + eye * 0.16, y: eyeY + eye * 0.14 - h / 2, width: d, height: d)),
                     with: .color(.white.opacity(0.9)))
        }
        if genes.mouth > 0 {
            let w = s * 0.09, h = s * 0.045
            let mouth = BotBlobMouth(open: genes.mouth == 2)
                .path(in: CGRect(x: s / 2 - w / 2, y: s * (genes.eyeY + 0.1) - h / 2, width: w, height: h))
            ctx.stroke(mouth, with: ink, style: StrokeStyle(lineWidth: max(1, s * 0.028), lineCap: .round))
        }
    }
}
