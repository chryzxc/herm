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
/// A new or changed reaction pops in with a springy overshoot and a quick
/// wobble; a retracted one shrinks away. Reduce Motion and motion-free skins
/// swap it with a plain fade. Views that scroll into place do not replay it.
struct MessageReactionBadge: View {
    let reactions: [MessageReaction]
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
                            ? .scale(scale: 0.2, anchor: .bottomLeading).combined(with: .opacity) : .opacity)
            }
        }
        .animation(
            animates ? .spring(duration: 0.38, bounce: 0.4) : .dockEase(duration: 0.18), value: reactions.isEmpty)
    }

    private func chip(animates: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(reactions, id: \.self) { reaction in
                Text(reaction.emoji)
                    .font(.system(size: 13))
                    .transition(
                        animates
                            ? .scale(scale: 0.2).combined(with: .opacity).combined(with: .offset(y: 4))
                            : .opacity)
            }
        }
        .frame(minWidth: 18, minHeight: 18)
        .dockPill()
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .modifier(ReactionPop(trigger: reactions, animates: animates))
        .animation(animates ? .spring(duration: 0.38, bounce: 0.4) : .dockEase(duration: 0.18), value: reactions)
        .help(Self.accessibilityLabel(reactions))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(reactions))
    }

    nonisolated static func accessibilityLabel(_ reactions: [MessageReaction]) -> String {
        reactions.map { ($0.isFromAgent ? "Hermes reacted " : "You reacted ") + $0.emoji }
            .joined(separator: ", ")
    }
}

/// Overshoot and wobble each time the reaction list changes; never on first appearance.
private struct ReactionPop: ViewModifier {
    struct Values {
        var scale = 1.0
        var tilt = 0.0
    }

    let trigger: [MessageReaction]
    let animates: Bool

    func body(content: Content) -> some View {
        // Motion-free: a trigger that never changes never fires.
        content.keyframeAnimator(initialValue: Values(), trigger: animates ? trigger : []) { view, values in
            view.scaleEffect(values.scale).rotationEffect(.degrees(values.tilt), anchor: .bottomLeading)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                SpringKeyframe(1.28, duration: 0.16, spring: .snappy)
                SpringKeyframe(1, duration: 0.34, spring: .bouncy)
            }
            KeyframeTrack(\.tilt) {
                LinearKeyframe(-9, duration: 0.1)
                SpringKeyframe(0, duration: 0.4, spring: .bouncy)
            }
        }
    }
}
