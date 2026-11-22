import QuartzCore

/// The period works the H like a spring-loaded key. All coordinates use a top-left 128pt artboard.
enum DockStartupLogo {
    static func install(in host: CALayer, flipped: Bool, ivory: CGColor, mint: CGColor, graphite: CGColor, paused: Bool)
    {
        let scale = min(host.bounds.width, host.bounds.height) / 128
        func position(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: host.bounds.midX + (x - 64) * scale, y: host.bounds.midY + (y - 64) * scale * (flipped ? 1 : -1))
        }
        func piece(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat, color: CGColor) -> CALayer {
            let layer = CAGradientLayer()
            layer.bounds.size = CGSize(width: w * scale, height: h * scale)
            layer.position = position(x, y)
            layer.cornerRadius = radius * scale
            layer.backgroundColor = color
            layer.colors = [
                ivory.copy(alpha: 0.11) ?? ivory, graphite.copy(alpha: 0) ?? graphite,
                graphite.copy(alpha: 0.24) ?? graphite,
            ]
            layer.locations = [0, 0.58, 1]
            layer.startPoint = CGPoint(x: 0.22, y: flipped ? 0 : 1)
            layer.endPoint = CGPoint(x: 0.78, y: flipped ? 1 : 0)
            host.addSublayer(layer)
            return layer
        }

        let tile = piece(64, 67, 108, 108, radius: 24, color: graphite)
        tile.borderColor = ivory.copy(alpha: 0.42)
        tile.borderWidth = scale
        let key = piece(58, 67, 22, 17, radius: 3, color: ivory)
        for x: CGFloat in [40, 76] {
            let stem = piece(x, 67, 20, 61, radius: 6, color: ivory)
            stem.shadowColor = graphite
            stem.shadowOpacity = 0.24
            stem.shadowOffset = CGSize(width: 0, height: -2 * scale)
            stem.shadowRadius = scale
        }

        let ball = piece(96, 91.5, 12, 12, radius: 6, color: mint)
        ball.shadowColor = mint
        ball.shadowRadius = 3 * scale
        ball.shadowOpacity = 0.6
        ball.shadowOffset = .zero
        guard !paused else { return }

        // X and Y move independently. The period rises clear of the right stem
        // before crossing it, then drops vertically into the narrow keyway.
        let beats: [NSNumber] = [0, 0.13, 0.25, 0.36, 0.42, 0.49, 0.62, 0.74, 0.86, 0.92, 1]
        func play(_ layer: CALayer, _ keyPath: String, _ values: [CGFloat]) {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = beats
            animation.timingFunctions = Array(
                repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: beats.count - 1)
            animation.duration = 1.85
            animation.repeatCount = .infinity
            layer.add(animation, forKey: keyPath)
        }

        play(ball, "position.x", [96, 96, 79, 58, 58, 58, 67, 91, 96, 96, 96].map { position($0, 0).x })
        play(ball, "position.y", [91.5, 47, 21, 35, 52.5, 62.5, 23, 30, 91.5, 86, 91.5].map { position(0, $0).y })
        play(key, "position.y", [67, 67, 67, 67, 67, 77, 67, 67, 67, 67, 67].map { position(0, $0).y })
    }
}
