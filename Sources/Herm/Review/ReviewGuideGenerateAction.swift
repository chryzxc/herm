import SwiftUI

struct ReviewGuideGenerateAction: View {
    let requesting: Bool
    var menuRow = false
    let generate: (String?) -> Void
    @Environment(\.chatContextRouter) private var router

    var body: some View {
        Group {
            if let bots = router?.bots {
                ReviewGuideReviewerMenu(bots: bots, requesting: requesting, menuRow: menuRow, generate: generate)
            } else {
                if menuRow {
                    Button("Generate review guide") { generate(nil) }
                } else {
                    Button(requesting ? "Requesting guide…" : "Generate review guide") { generate(nil) }
                        .buttonStyle(.dockCompact)
                }
            }
        }
        .help(ReviewGuideCoordinator.skillTooltip)
    }
}

private struct ReviewGuideReviewerMenu: View {
    @ObservedObject var bots: BotModeModel
    let requesting: Bool
    let menuRow: Bool
    let generate: (String?) -> Void

    var body: some View {
        if bots.inventory.availability == .ready && bots.inventory.isPluginEnabled {
            DockMenu {
                DockMenuSection("Reviewer · new conversation") {
                    Button("Default bot") { generate(nil) }
                    ForEach(bots.bots.filter { !$0.isHidden && !$0.isDefault }) { bot in
                        Button {
                            generate(bot.id)
                        } label: {
                            HStack(spacing: 8) {
                                BotMenuAvatar(bot: bot)
                                Text(bot.name)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(requesting ? "Requesting guide…" : "Generate review guide")
                    DockIcon(.caretDown, size: 10, color: Color.dockSecondaryText)
                }
                .dockFont(.control)
                .dockPadding(menuRow ? 0 : 6)
                .background(menuRow ? Color.clear : Color.dockControlSurface, in: RoundedRectangle(cornerRadius: 6))
            }
        } else {
            if menuRow {
                Button("Generate review guide") { generate(nil) }
            } else {
                Button(requesting ? "Requesting guide…" : "Generate review guide") { generate(nil) }
                    .buttonStyle(.dockCompact)
            }
        }
    }
}
