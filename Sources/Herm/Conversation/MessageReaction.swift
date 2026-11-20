import Foundation
import SwiftUI

/// One emoji reaction Hermes stores on a message row
/// (`display_metadata.reactions`, `message.reaction` events). One per author.
struct MessageReaction: Equatable, Hashable, Sendable {
    let emoji: String
    let author: String
    let at: Double?

    var isFromAgent: Bool { author == "agent" }

    /// Decodes `[{emoji, author, at}]`, dropping entries without an emoji.
    nonisolated static func parse(_ value: Any?) -> [MessageReaction] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let emoji = (row["emoji"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !emoji.isEmpty
            else { return nil }
            return MessageReaction(
                emoji: emoji, author: row["author"] as? String ?? "user",
                at: (row["at"] as? NSNumber)?.doubleValue)
        }
    }

    /// History rows carry `display_metadata` as an object or a JSON string.
    nonisolated static func parse(displayMetadata value: Any?) -> [MessageReaction] {
        if let object = value as? [String: Any] { return parse(object["reactions"]) }
        guard let text = value as? String, let data = text.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        return parse(object["reactions"])
    }

    /// The message a `message.reaction` event paints. A known row id wins. A
    /// live message has no row id yet, so the event's `role` picks the newest
    /// message of that role, but only for a row newer than every known one;
    /// an older unknown row (an earlier turn) waits for the next history read.
    nonisolated static func targetIndex(
        rowID: Int, role: String?, messages: [ChatMessage], knownRows: [Int: UUID]
    ) -> Int? {
        if let id = knownRows[rowID] { return messages.lastIndex { $0.id == id } }
        guard rowID > (knownRows.keys.max() ?? -1) else { return nil }
        return messages.lastIndex { message in
            guard message.systemEvent == nil, message.kanbanNotice == nil else { return false }
            switch role {
            case "user": return message.role == .user
            case "assistant": return message.role == .hermes && message.hasBodyText
            default: return false
            }
        }
    }
}

/// The reaction badge on a bubble. It never changes its row's height: user
/// bubbles hang it off the top corner inside their reserved top padding, and
/// assistant rows seat it at the start of the action line.
///
/// The first badge grows from its attachment point. Later emoji changes
/// briefly compress the existing pill, without moving its message or actions.
struct MessageReactionBadge: View {
    let reactions: [MessageReaction]
    var anchor: UnitPoint = .topLeading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animates = DockMotion.isEnabled(reduceMotion: reduceMotion)
        // Always mounted so the first reaction on a live row can run its
        // insertion; an empty list occupies no space.
        ZStack {
            if !reactions.isEmpty {
                chip(animates: animates)
                    .transition(
                        animates
                            ? .asymmetric(
                                insertion: .scale(scale: 0.72, anchor: anchor).combined(with: .opacity),
                                removal: .scale(scale: 0.9, anchor: anchor).combined(with: .opacity)) : .identity)
            }
        }
        .animation(
            animates ? .dockEase(duration: 0.2) : nil, value: reactions.isEmpty)
    }

    private func chip(animates: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(reactions, id: \.self) { reaction in
                Text(reaction.emoji)
                    .font(.system(size: 13))
                    .transition(
                        animates
                            ? .offset(y: 2).combined(with: .opacity) : .identity)
            }
        }
        .frame(minWidth: 18, minHeight: 18)
        .dockPill()
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .modifier(ReactionPop(trigger: reactions, animates: animates, anchor: anchor))
        .animation(animates ? .dockEase(duration: 0.2) : nil, value: reactions)
        .help(Self.accessibilityLabel(reactions))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(reactions))
    }

    nonisolated static func accessibilityLabel(_ reactions: [MessageReaction]) -> String {
        reactions.map { ($0.isFromAgent ? "Hermes reacted " : "You reacted ") + $0.emoji }
            .joined(separator: ", ")
    }
}

/// A live change briefly widens the pill against its attachment point.
private struct ReactionPop: ViewModifier {
    let trigger: [MessageReaction]
    let animates: Bool
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat(0), trigger: animates ? trigger : []) { view, pressure in
            let compression = animates ? pressure : 0
            view.scaleEffect(x: 1 + compression * 0.09, y: 1 - compression * 0.07, anchor: anchor)
        } keyframes: { _ in
            KeyframeTrack(\.self) {
                CubicKeyframe(1, duration: 0.09)
                CubicKeyframe(-0.25, duration: 0.11)
                CubicKeyframe(0, duration: 0.1)
            }
        }
    }
}
