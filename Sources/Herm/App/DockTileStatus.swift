import AppKit
import Combine

/// Mirrors agent state onto the Dock tile: a badge for requests waiting on you and a ring while work runs.
/// The tile is only visible while the workspace window keeps Herm a regular app.
@MainActor
final class DockTileStatus {
    private var cancellable: AnyCancellable?

    init(model: DockModel) {
        cancellable = Publishers.CombineLatest3(model.$sessionAttention, model.$status, model.$isSending)
            .map { attention, status, sending in (attention.count, status == .working || sending) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] count, working in self?.apply(attentionCount: count, working: working) }
    }

    private func apply(attentionCount: Int, working: Bool) {
        let tile = NSApp.dockTile
        tile.badgeLabel = attentionCount > 0 ? String(attentionCount) : nil
        tile.contentView = working ? DockRingView() : nil
        tile.display()
    }
}

/// The app icon with a thin accent outline hugging its rounded body; static because the tile is not redrawn per frame.
private final class DockRingView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        // The icon body fills about 80% of the tile; trace just outside it.
        let body = bounds.insetBy(dx: bounds.width * 0.085, dy: bounds.height * 0.085)
        let ring = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
        ring.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        ring.stroke()
    }
}
