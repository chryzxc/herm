import SwiftUI

enum UsageCostGrouping: String, CaseIterable {
    case models = "Models"
    case providers = "Providers"
}

/// A compact cost ledger beside the daily chart; the full model details follow below.
struct UsageSpendSummary: View {
    let report: TokenUsageReport
    @Binding var grouping: UsageCostGrouping
    var providersRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                DockSectionLabel(title: "Estimated cost")
                Text(UsageWorkspaceView.cost(report.totalCost))
                    .dockFont(.metric)
                    .foregroundStyle(Color.dockPrimaryText)
                    .monospacedDigit()
                Text("\(report.sessions.formatted()) sessions · API estimate")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                Text("Includes background work")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
            }
            .accessibilityElement(children: .combine)
            .help("Hermes' estimate in USD, not an invoice. Subscription-included and unpriced models report $0.")

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    ForEach(UsageCostGrouping.allCases, id: \.self) { choice in
                        DockTabButton(title: choice.rawValue, isSelected: grouping == choice) { grouping = choice }
                    }
                }
                DockSectionLabel(title: "Top \(grouping.rawValue.lowercased()) by cost")
                if grouping == .models {
                    ForEach(report.costRankedModels.prefix(4)) { model in modelRow(model) }
                    if report.models.isEmpty { rankingMessage("No models in this period.") }
                } else if let providers = report.costRankedProviders {
                    let total = providers.reduce(0) { $0 + $1.estimatedCost }
                    ForEach(providers.prefix(4)) { provider in
                        providerRow(provider, total: total)
                    }
                    if providers.isEmpty { rankingMessage("No provider usage in this period.") }
                } else {
                    rankingMessage(
                        providersRefreshing
                            ? "Reading provider costs…" : "Provider costs unavailable. Refresh to retry.")
                }
            }
            .frame(minHeight: 244, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rankingMessage(_ text: String) -> some View {
        Text(text).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func providerRow(_ provider: TokenUsageReport.Provider, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if !provider.provider.isEmpty {
                    ProviderMarkBadge(mark: ProviderMark(hermesProvider: provider.provider), size: 16)
                }
                Text(provider.provider.isEmpty ? "Unknown provider" : provider.provider)
                    .dockFont(.body, weight: .semibold).lineLimit(1)
                Spacer(minLength: 4)
                Text(UsageWorkspaceView.cost(provider.estimatedCost)).dockFont(.machineMetadata).fixedSize()
            }
            .foregroundStyle(Color.dockPrimaryText)
            Text(
                "\(total > 0 ? UsageWorkspaceView.percent(provider.estimatedCost / total * 100) + " of cost · " : "")\(UsageWorkspaceView.tokens(provider.totalTokens)) tokens"
            )
            .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
        }
        .accessibilityElement(children: .combine)
        .help(
            "Per-call provider accounting, including background work. Shares use provider totals, which can differ from session totals above."
        )
    }

    private func modelRow(_ model: TokenUsageReport.Model) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if model.providers.count == 1, let provider = model.providers.first {
                    ProviderMarkBadge(mark: ProviderMark(hermesProvider: provider), size: 16)
                }
                Text(model.model)
                    .dockFont(.body, weight: .semibold)
                    .lineLimit(1)
                    .help(model.model)
                Spacer(minLength: 4)
                Text(UsageWorkspaceView.cost(model.estimatedCost))
                    .dockFont(.machineMetadata)
                    .fixedSize()
            }
            .foregroundStyle(Color.dockPrimaryText)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    if report.totalCost > 0 {
                        Text("\(UsageWorkspaceView.percent(model.estimatedCost / report.totalCost * 100)) of cost ·")
                    }
                    Text("\(UsageWorkspaceView.tokens(model.totalTokens)) tokens")
                }
                Text("\(UsageWorkspaceView.tokens(model.totalTokens)) tokens")
            }
            .dockFont(.metadata)
            .foregroundStyle(Color.dockMetadataText)
        }
        .accessibilityElement(children: .combine)
    }
}

struct UsageSpendTotals: View {
    let report: TokenUsageReport
    var isWide = false
    private var monochrome: Bool { DockThemeRuntime.current == .mono || DockThemeRuntime.current == .eInk }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DockSectionLabel(title: "Token totals")
            if isWide {
                HStack(alignment: .top, spacing: 18) {
                    inputTotals
                    outputTotals
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 18) {
                    GridRow { inputTotals }
                    GridRow { outputTotals }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    tokenMix.frame(minWidth: 280)
                    costMix.frame(minWidth: 280)
                }
                VStack(alignment: .leading, spacing: 20) {
                    tokenMix
                    costMix
                }
            }

            Color.dockBorderLight.frame(height: DockLayout.hairline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)],
                alignment: .leading, spacing: 10
            ) {
                detail("API calls", report.apiCalls.formatted())
                    .help("Main conversation calls; background calls are listed under Background work.")
                detail("Reasoning", UsageWorkspaceView.tokens(report.reasoningTokens))
                    .help("Main conversation reasoning tokens; already included in output, not added again.")
                detail("Models", report.models.count.formatted())
            }
            Text("Cache reads and hit rate cover the main conversation; background cache usage is not reported.")
                .dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var inputTotals: some View {
        total("Processed tokens", UsageWorkspaceView.tokens(report.processedTokens))
            .help("Input, output, and reported cache reads, including background input and output.")
        total("Cache reads", UsageWorkspaceView.tokens(report.cacheReadTokens))
        total("Uncached input", UsageWorkspaceView.tokens(report.totalInputTokens))
    }

    @ViewBuilder
    private var outputTotals: some View {
        total("Output", UsageWorkspaceView.tokens(report.totalOutputTokens))
        total("Cache hit rate", report.cacheHitRate.map { UsageWorkspaceView.percent($0 * 100) } ?? "—")
    }

    private var tokenMix: some View {
        UsageSpendBreakdown(
            title: "Token mix",
            segments: [
                .init(
                    label: "Input", value: Double(report.totalInputTokens),
                    display: UsageWorkspaceView.tokens(report.totalInputTokens), color: .dockInfoFill),
                .init(
                    label: "Cache reads", value: Double(report.cacheReadTokens),
                    display: UsageWorkspaceView.tokens(report.cacheReadTokens),
                    color: Color.dockMergedFill.opacity(monochrome ? 0.65 : 1)),
                .init(
                    label: "Output", value: Double(report.totalOutputTokens),
                    display: UsageWorkspaceView.tokens(report.totalOutputTokens),
                    color: Color.dockReviewFill.opacity(monochrome ? 0.4 : 1)),
            ])
    }

    private var costMix: some View {
        UsageSpendBreakdown(
            title: "Cost by work",
            segments: [
                .init(
                    label: "Conversation", value: report.estimatedCost,
                    display: UsageWorkspaceView.cost(report.estimatedCost), color: .dockReviewFill),
                .init(
                    label: "Background", value: report.auxCost,
                    display: UsageWorkspaceView.cost(report.auxCost),
                    color: Color.dockMergedFill.opacity(monochrome ? 0.65 : 1)),
            ])
    }

    private func total(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            Text(value).dockFont(.metric).foregroundStyle(Color.dockPrimaryText).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(Color.dockSecondaryText)
            Text(value).foregroundStyle(Color.dockPrimaryText).fontWeight(.semibold)
        }
        .dockFont(.metadata)
        .accessibilityElement(children: .combine)
    }
}

private struct UsageSpendBreakdown: View {
    struct Segment: Identifiable {
        let label: String
        let value: Double
        let display: String
        let color: Color
        var id: String { label }
    }

    let title: String
    let segments: [Segment]

    var body: some View {
        let total = segments.reduce(0) { $0 + max(0, $1.value) }
        return VStack(alignment: .leading, spacing: 10) {
            DockSectionLabel(title: title)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(segments) { segment in
                        segment.color
                            .frame(width: total > 0 ? geometry.size.width * max(0, segment.value) / total : 0)
                            .overlay(alignment: .trailing) {
                                if segment.value > 0, segment.id != segments.last?.id {
                                    Color.dockCanvas.frame(width: 2)
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.dockBorderLight)
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 8
            ) {
                ForEach(segments) { segment in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(segment.color).frame(width: 8, height: 8)
                        Text(segment.label).foregroundStyle(Color.dockSecondaryText)
                        Text(segment.display).foregroundStyle(Color.dockPrimaryText)
                    }
                    .dockFont(.metadata)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
