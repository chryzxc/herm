import SwiftUI

/// Explicit shell intent; ordinary code blocks never gain execution behavior.
struct RichCommand: Codable, Equatable, Sendable {
    let command: String

    func validate() -> Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && command.utf8.count <= 512
            && !command.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
                    || CharacterSet.illegalCharacters.contains($0) || $0.properties.generalCategory == .format
            }
    }
}

struct RichCommandView: View {
    let command: RichCommand
    @Environment(\.richReplyContext) private var context
    @Environment(\.richHostActionRouter) private var router
    @Environment(\.richCommandCompletion) private var completion
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(command.command).dockFont(.code, design: .monospaced)
                .textSelection(.enabled).dockPadding(12).dockPadding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                Button {
                    do {
                        guard let router else { return }
                        try router.run(command, context: context)
                        error = nil
                        completion?()
                    } catch {
                        self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription)
                    }
                } label: {
                    Label("Run in Terminal", systemImage: "play")
                }
                .buttonStyle(.dockPrimary)
                .disabled(router?.canRunCommand(context: context) != true)
                DockCopyButton(command.command, label: "Copy", accessibilityLabel: "Copy command")
            }.dockButtonSize(.compact)
            Text(error ?? directoryLabel).dockFont(.body)
                .foregroundStyle(error == nil ? Color.dockSecondaryText : Color.dockDestructive)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var directoryLabel: String {
        guard router?.canRunCommand(context: context) == true, let directory = router?.terminal?.directory else {
            return "Open the original reply in its session to run this command."
        }
        return "On this Mac · " + directory
    }
}

private struct RichCommandCompletionKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    var richCommandCompletion: (@MainActor () -> Void)? {
        get { self[RichCommandCompletionKey.self] }
        set { self[RichCommandCompletionKey.self] = newValue }
    }
}
