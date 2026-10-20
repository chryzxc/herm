import SwiftUI

/// Rear orbit, clipped avatar, then front orbit share a single drawing context.
struct DockBotOrbitCanvas: View {
    let id: String
    let image: NSImage?
    let size: CGFloat
    let busy: Bool
    let mood: BotMood?
    let pose: BotFacePose
    let frame: DockBotIndicatorFrame
    let orbits: Bool

    var body: some View {
        Canvas { context, box in
            let origin = CGPoint(x: (box.width - size) / 2, y: (box.height - size) / 2)
            if orbits && frame.moves { orbit(in: context, box: box, front: false) }
            var avatar = context
            avatar.translateBy(x: origin.x, y: origin.y)
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            avatar.clip(to: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).path(in: rect))
            if let image {
                let zoom = 1.03 + pose.bob
                let aspect = image.size.width / max(1, image.size.height)
                let width = max(size, size * aspect) * zoom
                let height = max(size, size / max(0.001, aspect)) * zoom
                avatar.draw(Image(nsImage: image), in: CGRect(x: (size - width) / 2, y: (size - height) / 2,
                                                            width: width, height: height))
            } else {
                BotFaceMark.draw(in: &avatar, id: id, size: size, busy: busy, mood: mood, pose: pose)
            }
            if orbits && frame.moves { orbit(in: context, box: box, front: true) }
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    private func orbit(in context: GraphicsContext, box: CGSize, front: Bool) {
        let seed = BotAvatarPresentation.seed(for: id)
        let t = frame.face(id: id, busy: true).t
        let alpha = BotFacePose.swirl(at: t, seed: seed).1
        guard alpha > 0 else { return }
        var context = context
        context.opacity = alpha
        context.translateBy(x: box.width / 2, y: box.height / 2)
        context.rotate(by: .degrees(-12))
        for i in (0..<4).reversed() {
            let theta = BotFacePose.swirl(at: t - Double(i) * 0.05, seed: seed).0 * .pi / 180
            let depth = sin(theta)
            guard (depth > 0) == front else { continue }
            let d = (i == 0 ? size * 0.26 : size * 0.07) * (0.8 + 0.3 * depth)
            let rect = CGRect(x: size * 0.62 * cos(theta) - d / 2, y: size * 0.18 * depth - d / 2, width: d, height: d)
            let shape = i == 0 ? BotOrbitStar().path(in: rect) : Path(ellipseIn: rect)
            var dot = context
            dot.opacity *= (front ? 1 : 0.7) * (1 - Double(i) * 0.25)
            dot.fill(shape, with: .color(Color(hue: 0.12, saturation: 0.72, brightness: 0.97)))
            dot.stroke(shape, with: .color(.black.opacity(0.45)), lineWidth: i == 0 ? 0.75 : 0.5)
        }
    }
}

extension BotFaceMark {
    static func draw(in ctx: inout GraphicsContext, id: String, size s: CGFloat, busy: Bool,
                     mood override: BotMood?, pose: BotFacePose) {
        let genes = BotBlobGenes(id: id)
        let mood = override ?? (busy ? .work : .idle)
        let hue = BotAvatarPresentation.hue(for: id)
        let ink = GraphicsContext.Shading.color(Color(white: 0.08, opacity: 0.88))
        let eye = s * genes.eyeSize * (mood == .surprised ? 1.25 : 1)
        let gap = s * genes.eyeGap
        let look = mood == .sleepy ? .zero : pose.look
        let glow = mood == .work ? (1 + sin(pose.t * 2.6)) / 2 : 0
        ctx.translateBy(x: 0, y: pose.bob * s * (mood == .sleepy ? 0.5 : 1))
        let body = BotBlobShape(genes: genes, t: pose.t, busy: busy).path(in: CGRect(x: 0, y: 0, width: s, height: s))
        ctx.fill(body, with: .color(Color(hue: (hue - 0.04 * glow + 1).truncatingRemainder(dividingBy: 1),
                                          saturation: 0.58, brightness: 0.82 + 0.07 * glow)))
        ctx.fill(body, with: .linearGradient(Gradient(colors: [.white.opacity(0.22), .clear]),
                                             startPoint: .zero, endPoint: CGPoint(x: s / 2, y: s / 2)))
        if genes.cheeks || mood == .happy {
            let w = eye * 1.25, h = eye * 0.7, dx = (gap + eye * 1.2 + w) / 2
            let blush = Color(hue: 0.97, saturation: 0.55, brightness: 1).opacity(mood == .happy ? 0.6 : 0.45)
            for side in [-1.0, 1.0] {
                ctx.fill(Path(ellipseIn: CGRect(x: s / 2 + side * dx - w / 2, y: s * (genes.eyeY + 0.075) - h / 2, width: w, height: h)),
                         with: .color(blush))
            }
        }
        let eyeY = s * genes.eyeY + look.height * s
        for side in [-1.0, 1.0] {
            switch mood {
            case .happy, .sleepy:
                let w = eye * 0.85, h = eye * 0.4
                var arch = BotBlobArch().path(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                if mood == .sleepy { arch = arch.applying(CGAffineTransform(scaleX: 1, y: -1)) }
                let x = s / 2 + side * (gap + w) / 2 + look.width * s
                ctx.stroke(arch.applying(CGAffineTransform(translationX: x, y: eyeY)), with: ink,
                           style: StrokeStyle(lineWidth: max(1, eye * 0.26), lineCap: .round))
            default:
                let blink = mood == .surprised ? 1 : pose.blink
                let h = eye * genes.eyeTall
                let x = s / 2 + side * (gap + eye) / 2 + look.width * s
                ctx.fill(Path(ellipseIn: CGRect(x: x - eye / 2, y: eyeY - h * blink / 2, width: eye, height: h * blink)), with: ink)
                let d = eye * 0.36
                ctx.fill(Path(ellipseIn: CGRect(x: x - eye / 2 + eye * 0.16, y: eyeY + (eye * 0.14 - h / 2) * blink,
                                                width: d, height: d * blink)), with: .color(.white.opacity(0.9)))
            }
        }
        if genes.mouth > 0 || mood != .idle, mood != .sleepy {
            let w = s * (mood == .happy ? 0.12 : 0.09), h = s * (mood == .happy ? 0.06 : 0.045)
            let mouth = BotBlobMouth(open: mood == .work || mood == .surprised || (mood == .idle && genes.mouth == 2))
                .path(in: CGRect(x: s / 2 + look.width * s * 0.5 - w / 2, y: s * (genes.eyeY + 0.1) - h / 2, width: w, height: h))
            ctx.stroke(mouth, with: ink, style: StrokeStyle(lineWidth: max(1, s * 0.028), lineCap: .round))
        }
    }
}
