import AppIntents

/// Shortcuts / Spotlight entry points. They only stage text and open the panel: nothing is sent without the user pressing Return.
struct AskHermIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Herm"
    static let description = IntentDescription("Opens Herm with your text ready in the composer.")
    static let openAppWhenRun = true

    @Parameter(title: "Text") var text: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        HermDelegate.current?.stageAndShow(text ?? "")
        return .result()
    }
}

struct HermShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHermIntent(), phrases: ["Ask \(.applicationName)", "Open \(.applicationName)"],
            shortTitle: "Ask Herm", systemImageName: "bubble.left.and.text.bubble.right")
    }
}
