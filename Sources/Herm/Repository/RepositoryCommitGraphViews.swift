import SwiftUI

/// Approved accents in lane order; the first lane is the checked-out history.
enum RepositoryCommitGraphPalette {
    static let lanes: [DockAccentColor] = [.blue, .violet, .pink, .amber, .teal, .coral, .green, .cyan, .orange, .indigo]
    static func accent(_ index: Int) -> DockAccentColor { lanes[index % lanes.count] }
}

/// Draws one row of commit lanes. Fills the row's full height so lanes stay
/// continuous when a commit expands to show its details.
struct RepositoryCommitGraphLanes: View {
    static let laneSpacing: CGFloat = 12
    static let rowHeight: CGFloat = 24
    /// Matches the vertical center of the collapsed commit row.
    static let nodeY: CGFloat = rowHeight / 2

    let row: RepositoryCommitGraphRow
    let isHead: Bool
    let isMerge: Bool

    var body: some View {
        Canvas { context, size in
            func x(_ lane: Int) -> CGFloat { Self.laneSpacing / 2 + CGFloat(lane) * Self.laneSpacing + 2 }
            func stroke(_ path: Path, _ color: Int) {
                context.stroke(path, with: .color(RepositoryCommitGraphPalette.accent(color).fill), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            let node = Self.nodeY
            for segment in row.top {
                var path = Path()
                path.move(to: CGPoint(x: x(segment.from), y: 0))
                path.addCurve(to: CGPoint(x: x(segment.to), y: node), control1: CGPoint(x: x(segment.from), y: node / 2), control2: CGPoint(x: x(segment.to), y: node / 2))
                stroke(path, segment.color)
            }
            for segment in row.bottom {
                let turn = min(size.height, node * 2)
                var path = Path()
                path.move(to: CGPoint(x: x(segment.from), y: node))
                path.addCurve(to: CGPoint(x: x(segment.to), y: turn), control1: CGPoint(x: x(segment.from), y: (node + turn) / 2), control2: CGPoint(x: x(segment.to), y: (node + turn) / 2))
                path.addLine(to: CGPoint(x: x(segment.to), y: size.height))
                stroke(path, segment.color)
            }
            let color = RepositoryCommitGraphPalette.accent(row.color).fill
            func circle(_ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: x(row.lane) - radius, y: node - radius, width: radius * 2, height: radius * 2))
            }
            if isHead || isMerge {
                // HEAD and merges read as rings, like VS Code's graph; merges keep a center dot.
                let ring = circle(isHead ? 4.5 : 4)
                context.fill(ring, with: .color(Color.dockSurface))
                context.stroke(ring, with: .color(color), lineWidth: isHead ? 2 : 1.5)
                if isMerge { context.fill(circle(1.5), with: .color(color)) }
            } else {
                context.fill(circle(3.5), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

struct RepositoryCommitReferencePill: View {
    let reference: RepositoryCommitReference
    let accent: DockAccentColor

    var body: some View {
        HStack(spacing: 3) {
            DockIcon(icon, size: 10, color: accent.color)
            Text(reference.name)
                .dockFont(size: 11, weight: reference.isHead ? .semibold : .medium)
                .foregroundStyle(accent.color)
                .lineLimit(1)
                .truncationMode(.middle)
            if reference.isSynced {
                DockIcon(.cloud, size: 10, color: accent.color)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule().fill(accent.fill.opacity(0.14)))
        .overlay(Capsule().stroke(accent.fill.opacity(reference.isHead ? 0.7 : 0.3), lineWidth: reference.isHead ? 1 : 0.5))
        .help(help)
    }

    private var icon: Ph {
        switch reference.kind {
        case .branch: .gitBranch
        case .remote: .cloud
        case .tag: .tag
        }
    }

    private var help: String {
        let kind = switch reference.kind {
        case .branch: reference.isHead ? "Checked-out branch" : "Branch"
        case .remote: "Remote branch"
        case .tag: "Tag"
        }
        return "\(kind) \(reference.name)\(reference.isSynced ? ", in sync with its remote" : "")"
    }
}
