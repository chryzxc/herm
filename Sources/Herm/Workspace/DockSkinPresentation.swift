import AppKit
import SwiftUI

/// Semantic component styling roles. Views consume these roles rather
/// than checking theme IDs; palette and geometry remain in DockTheme.
struct DockSkinPresentation: Equatable {
    enum Transcript: Equatable { case bubbles, document }
    enum Composer: Equatable { case floating, desktop, line }

    var transcript: Transcript = .bubbles
    var composer: Composer = .floating
    var composerPlaceholder: String = "Do anything"
    var restoringPlaceholder: String = "Restoring conversation…"
    var answerPlaceholder: String = "Answer Hermes' question…"
    var submitLabel: String = "Send message"
    var steerLabel: String = "Steer active turn"

    static var current: Self { DockThemeRuntime.current.presentation }


    var composerRadius: CGFloat { switch composer { case .desktop: 14; case .line: 0; case .floating: DockLayout.paneRadius + 4 } }
    var composerShadow: CGFloat { composer == .floating ? 6 : 0 }
    var composerControlFill: Color { composer == .floating ? .dockControlSurface : .clear }

    static func nativeFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        switch DockThemeStyle.current.fontDesign {
        case .monospaced: return .monospacedSystemFont(ofSize: size, weight: weight)
        case .serif:
            let font = NSFont.systemFont(ofSize: size, weight: weight)
            return font.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? font
        case .rounded:
            let font = NSFont.systemFont(ofSize: size, weight: weight)
            return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
        default: return .systemFont(ofSize: size, weight: weight)
        }
    }
}

extension DockThemeID {
    var presentation: DockSkinPresentation {
        switch self {
        case .retro:
            DockSkinPresentation(composerPlaceholder: "C:\\> Type a message_", restoringPlaceholder: "Please wait…", answerPlaceholder: "Reply to Hermes_")
        case .eInk:
            DockSkinPresentation(transcript: .document, composer: .desktop)
        case .clay:
            DockSkinPresentation(composerPlaceholder: "Say anything")
        case .pixel:
            DockSkinPresentation(composerPlaceholder: "Insert coin ▸ type a message", restoringPlaceholder: "Loading save file…", answerPlaceholder: "Player 1, answer Hermes…")
        case .notebook:
            DockSkinPresentation(transcript: .document, composer: .desktop, composerPlaceholder: "Jot something down…", restoringPlaceholder: "Opening your notebook…")
        case .hud:
            DockSkinPresentation(composerPlaceholder: "Awaiting input…", restoringPlaceholder: "Restoring session…", answerPlaceholder: "Respond to Hermes…")
        case .swiss:
            DockSkinPresentation(transcript: .document, composer: .line, composerPlaceholder: "Ask anything")
        default: DockSkinPresentation()
        }
    }
}

