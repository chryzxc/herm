import Foundation

struct KanbanModelMetadataPresentation: Equatable {
    let label: String
    let isOverride: Bool

    static func make(taskModel: String?, taskProvider: String?, bot: BotSummary?) -> Self {
        let model = clean(taskModel)
        let provider = clean(taskProvider)
        if model != nil || provider != nil {
            return Self(label: format(provider: provider, model: model), isOverride: true)
        }
        let configuredModel = clean(bot?.model)
        let configuredProvider = clean(bot?.provider)
        guard configuredModel != nil || configuredProvider != nil else {
            return Self(label: "Model unavailable", isOverride: false)
        }
        return Self(label: format(provider: configuredProvider, model: configuredModel), isOverride: false)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func format(provider: String?, model: String?) -> String {
        switch (provider, model) {
        case let (provider?, model?): "\(provider) / \(model)"
        case let (provider?, nil): provider
        case let (nil, model?): model
        case (nil, nil): "Model unavailable"
        }
    }
}
