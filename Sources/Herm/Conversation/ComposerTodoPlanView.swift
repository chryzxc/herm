import SwiftUI

/// Read-only Hermes plan; only disclosure state belongs to the view.
struct ComposerTodoPlanView: View {
    let plan: TodoPlan
    var isWorking: Bool
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: Animation? {
        reduceMotion || !DockThemeStyle.current.animates ? nil : .dockEase(duration: 0.22)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(motion) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().stroke(Color.dockBorderStrong, lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: CGFloat(plan.done) / CGFloat(max(1, plan.items.count)))
                            .stroke(Color.dockSuccess, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)

                    Text("\(plan.done)/\(plan.items.count)")
                        .dockFont(.body, weight: .semibold).monospacedDigit()
                        .foregroundStyle(Color.dockPrimaryText)
                        .contentTransition(.numericText())
                        .fixedSize()
                    Text(
                        isExpanded
                            ? "Tasks · \(plan.done) of \(plan.items.count) done"
                            : plan.inProgress.map { "In progress: \($0.content)" }
                                ?? plan.current?.content ?? "Plan finished"
                    )
                    .dockFont(.body, weight: isExpanded ? .medium : .regular)
                    .foregroundStyle(isExpanded ? Color.dockPrimaryText : Color.dockSecondaryText)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    DockIcon(.caretRight, size: 10, color: .dockMetadataText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .dockPadding(.horizontal, 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .accessibilityLabel(
                "Task plan, \(plan.done) of \(plan.items.count) steps resolved. \(plan.current?.content ?? "Plan finished")"
            )
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hide task details" : "Show task details")
            .help(isExpanded ? "Collapse task plan" : "Expand task plan")

            if isExpanded {
                ScrollView {
                    TodoPlanTaskList(plan: plan, isWorking: isWorking)
                }
                .defaultScrollAnchor(.top)
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
                .dockPadding(.horizontal, 4)
                .dockPadding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(motion, value: plan)
        .transaction {
            if motion == nil {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        }
    }

}

/// Shared task order, status indicators, and emphasis for the composer and session rail.
struct TodoPlanTaskList: View {
    let plan: TodoPlan
    let isWorking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: Animation? {
        reduceMotion || !DockThemeStyle.current.animates ? nil : .dockEase(duration: 0.22)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(plan.orderedItemIndices, id: \.self) { index in
                taskRow(plan.items[index])
            }
        }
    }

    private func taskRow(_ item: TodoPlan.Item) -> some View {
        let active = item.status == "in_progress"
        let completed = item.status == "completed"
        let cancelled = item.status == "cancelled"
        return HStack(alignment: .top, spacing: 10) {
            Group {
                if active && isWorking && motion != nil {
                    DockActivityIndicator(state: .running, size: 14, tint: Color.dockAccent)
                } else if active {
                    Circle().trim(from: 0, to: 0.7)
                        .stroke(Color.dockAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 12, height: 12)
                } else {
                    let color: Color = completed ? .dockSuccess : (cancelled ? .dockMetadataText : .dockBorderStrong)
                    Circle()
                        .stroke(color, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                        .overlay {
                            if completed || cancelled {
                                DockIcon(completed ? .check : .x, size: 9, color: color)
                            }
                        }
                }
            }
            .frame(width: 16, height: 16)
            .id(item.status)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.content)
                    .dockFont(.body, weight: active ? .semibold : .regular)
                    .foregroundStyle(
                        active
                            ? Color.dockPrimaryText
                            : completed || cancelled ? Color.dockMetadataText : Color.dockSecondaryText
                    )
                    .strikethrough(completed || cancelled, color: .dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(item.status.replacingOccurrences(of: "_", with: " ").capitalized)
                    .dockFont(.metadata, weight: active ? .semibold : .regular)
                    .foregroundStyle(active ? Color.dockAccent : Color.dockMetadataText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .dockPadding(.horizontal, 8)
        .dockPadding(.vertical, 6)
        .dockSelectionBackground(
            RoundedRectangle(cornerRadius: DockThemeStyle.current.controlRadius), active: active, fill: .dockSurface4,
            allowsInvert: false
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.content), \(item.status.replacingOccurrences(of: "_", with: " "))")
    }
}
