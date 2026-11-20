import Foundation

struct BrowserScreencast {
    struct Viewport: Equatable {
        let cssSize: CGSize
        let pixelSize: CGSize
        let backingScale: CGFloat
        let isMobile: Bool
    }

    enum FrameDisposition: Equatable {
        case display, ignore, restart
    }

    let sessionID: String
    let viewport: Viewport
    private var phase = Phase.waiting

    private enum Phase { case waiting, retried, streaming }

    init(sessionID: String, viewport: Viewport) {
        self.sessionID = sessionID
        self.viewport = viewport
    }

    mutating func receive(cssSize: CGSize, pixelSize: CGSize) -> FrameDisposition {
        guard cssSize.width > 0, cssSize.height > 0 else { return .ignore }
        if phase != .streaming, cssSize != viewport.cssSize { return .ignore }

        // Chrome can report the new CSS size before its compositor has resized the actual pixels.
        let aspectError = abs(pixelSize.width * cssSize.height - pixelSize.height * cssSize.width)
        let matchesAspect = aspectError <= 2 * max(cssSize.width, cssSize.height)
        let expectedArea = viewport.pixelSize.width * viewport.pixelSize.height
        let pixelArea = pixelSize.width * pixelSize.height
        if phase == .waiting, !matchesAspect || pixelArea < expectedArea * 0.98 {
            phase = .retried
            return .restart
        }

        guard matchesAspect else { return .ignore }
        phase = .streaming
        return .display
    }
}
