import AppKit
import SwiftUI

/// In-board card drag: the card lifts and follows the pointer, the target
/// lane opens a gap where it will land, and the card settles into that gap
/// (or flies back on cancel). Pointer location is observed only by the ghost,
/// so moving the mouse does not re-evaluate the board.
@MainActor @Observable
final class KanbanDragController {
    nonisolated static let space = "kanban.board"
    nonisolated static let gapID = "kanban.drop-gap"
    nonisolated static let cardSpacing: CGFloat = 6

    struct Session {
        let task: KanbanTaskSummary
        let source: KanbanLane
        let size: CGSize
        /// Pointer offset inside the card, preserved for the whole drag.
        let grab: CGSize
        var isSettling = false
    }

    /// A dropped move shown in its new lane while Hermes applies it.
    struct Placement: Equatable {
        let taskID: String
        let lane: KanbanLane
        let index: Int
    }

    var session: Session?
    var location: CGPoint = .zero
    var target: KanbanLane?
    var insertion = 0
    var placement: Placement?

    // Board inputs and measured geometry; written often, never rendered directly.
    @ObservationIgnored var tasks: [KanbanTaskSummary] = []
    @ObservationIgnored var actions = KanbanCardActionAvailability()
    @ObservationIgnored var pendingActionIDs: Set<String> = []
    @ObservationIgnored var motion: Animation?
    @ObservationIgnored var drop: (@MainActor (KanbanTaskSummary, KanbanLane) -> Void)?
    @ObservationIgnored var laneFrames: [KanbanLane: CGRect] = [:]
    @ObservationIgnored var rowFrames: [String: CGRect] = [:]

    func isPending(_ taskID: String) -> Bool { pendingActionIDs.contains { $0.hasSuffix(":\(taskID)") } }

    func dragChanged(task: KanbanTaskSummary, lane: KanbanLane, value: DragGesture.Value) {
        if session == nil {
            guard let frame = rowFrames[task.id] else { return }
            session = Session(
                task: task, source: lane, size: frame.size,
                grab: CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY))
        }
        guard let session, !session.isSettling, session.task.id == task.id else { return }
        location = value.location

        let hovered = laneFrames.first { $0.value.contains(value.location) }?.key
        let accepts =
            hovered.map {
                $0 != session.source && !isPending(task.id) && actions.destinations(for: task.status).contains($0)
            }
            ?? false
        (hovered == nil || hovered == session.source || accepts ? NSCursor.closedHand : NSCursor.operationNotAllowed)
            .set()

        let newTarget = accepts ? hovered : nil
        let newInsertion =
            newTarget.map { lane in
                Self.insertionIndex(
                    pointerY: value.location.y,
                    rowMidYs: tasks.filter { KanbanBoardPresentation.lane(for: $0.status) == lane && $0.id != task.id }
                        .map { rowFrames[$0.id]?.midY ?? .infinity },
                    openGap: target == lane ? insertion : nil,
                    gapHeight: session.size.height + Self.cardSpacing)
            } ?? 0
        guard newTarget != target || newInsertion != insertion else { return }
        withAnimation(motion) {
            target = newTarget
            insertion = newInsertion
        }
    }

    func dragEnded() {
        guard var session, !session.isSettling else { return }
        let lane = target
        let index = insertion
        NSCursor.arrow.set()
        let outcome = lane.map { KanbanBoardPresentation.dropOutcome(taskStatus: session.task.status, target: $0) }
        // Done/Blocked still need confirmation, so those cards return to their slot first.
        let settles = if case .move = outcome { true } else { false }
        let finish = { [self] in
            // The ghost sits exactly on its slot, so swap it for the real card without a crossfade.
            var swap = Transaction()
            swap.disablesAnimations = true
            withTransaction(swap) {
                if let lane, settles {
                    placement = Placement(taskID: session.task.id, lane: lane, index: index)
                }
                self.session = nil
                target = nil
                insertion = 0
            }
            if let lane { drop?(session.task, lane) }
        }
        session.isSettling = true
        self.session = session
        guard let motion, let frame = settles ? rowFrames[Self.gapID] : rowFrames[session.task.id] else {
            return finish()
        }
        withAnimation(motion) {
            if !settles { target = nil }
            location = CGPoint(x: frame.minX + session.grab.width, y: frame.minY + session.grab.height)
        } completion: {
            finish()
        }
    }

    /// Where the dragged card lands among a lane's rows. Rows after an already
    /// open gap are measured at their pre-gap position so the gap cannot chase
    /// the pointer.
    nonisolated static func insertionIndex(
        pointerY: CGFloat, rowMidYs: [CGFloat], openGap: Int?, gapHeight: CGFloat
    ) -> Int {
        let natural = rowMidYs.enumerated().map { index, midY in
            if let openGap, index >= openGap { midY - gapHeight } else { midY }
        }
        return natural.firstIndex { pointerY < $0 } ?? natural.count
    }
}

/// The lifted card that follows the pointer.
struct KanbanDragGhost<Card: View>: View {
    let controller: KanbanDragController
    let session: KanbanDragController.Session
    @ViewBuilder let card: Card
    @State private var lifted = false

    var body: some View {
        let raised = lifted && !session.isSettling
        card
            .frame(width: session.size.width, height: session.size.height)
            .scaleEffect(raised ? 1.04 : 1)
            .rotationEffect(.degrees(raised ? 2 : 0))
            .shadow(color: .black.opacity(raised ? 0.28 : 0.08), radius: raised ? 16 : 2, y: raised ? 10 : 1)
            .position(
                x: controller.location.x - session.grab.width + session.size.width / 2,
                y: controller.location.y - session.grab.height + session.size.height / 2
            )
            .allowsHitTesting(false)
            .onAppear {
                if let motion = controller.motion {
                    withAnimation(motion) { lifted = true }
                } else {
                    lifted = true
                }
            }
    }
}

/// The empty slot a card leaves behind, or the gap it will land in.
struct KanbanDropSlot: View {
    /// `nil` fills the proposed height.
    let height: CGFloat?
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous)
            .fill(tint.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}
