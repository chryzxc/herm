import SwiftUI

/// Hour and minute pop-ups that edit one `Date`; replaces the native stepper field.
struct DockTimePicker: View {
    @Binding var time: Date
    private let calendar = Calendar.current

    var body: some View {
        HStack(spacing: 4) {
            DockOptionPicker(selection: part(.hour), options: (0..<24).map { ($0, String(format: "%02d", $0)) })
                .accessibilityLabel("Hour")
            Text(":").foregroundStyle(Color.dockSecondaryText)
            DockOptionPicker(selection: part(.minute), options: (0..<60).map { ($0, String(format: "%02d", $0)) })
                .accessibilityLabel("Minute")
        }
    }

    private func part(_ component: Calendar.Component) -> Binding<Int> {
        Binding(
            get: { calendar.component(component, from: time) },
            set: { time = calendar.date(bySetting: component, value: $0, of: time) ?? time })
    }
}

/// A themed month grid for choosing a day; replaces the native graphical date picker.
struct DockDateGrid: View {
    @Binding var selection: Date
    @State private var month: Date
    private let calendar = Calendar.current

    init(selection: Binding<Date>) {
        _selection = selection
        _month = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).dockFont(.body, weight: .semibold)
                Spacer()
                arrow(.caretLeft, "Previous month", -1)
                arrow(.caretRight, "Next month", 1)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(Array(calendar.veryShortWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day { cell(day) } else { Color.clear.frame(height: 28) }
                }
            }
        }
        .frame(width: 232)
    }

    private func arrow(_ icon: Ph, _ label: String, _ delta: Int) -> some View {
        Button {
            shift(delta)
        } label: {
            DockIcon(icon, size: 12, color: .dockSecondaryText).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.dockHover).help(label).accessibilityLabel(label)
    }

    private func cell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selection)
        let isToday = calendar.isDateInToday(day)
        return Button {
            selection = day
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .dockFont(.body, weight: isSelected || isToday ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.dockCanvas : (isToday ? Color.dockAccent : Color.dockPrimaryText))
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(Circle().fill(isSelected ? Color.dockPrimaryText : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Leading `nil`s pad the first week to the locale's first weekday.
    private var days: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
            let count = calendar.range(of: .day, in: .month, for: month)?.count
        else { return [] }
        let lead = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead)
            + (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    private func shift(_ delta: Int) { month = calendar.date(byAdding: .month, value: delta, to: month) ?? month }
}
