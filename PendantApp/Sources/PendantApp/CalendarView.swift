import SwiftUI

/// A small month grid for the sidebar. Days that have recordings show a dot;
/// click one to show that day's recordings.
struct CalendarView: View {
    /// Day folders that have recordings, e.g. "2026-11-23".
    let daysWithRecordings: Set<String>
    @Binding var selectedDay: String
    @Binding var month: Date
    /// Called from a day's right-click menu to copy that day's transcripts.
    var onCopyDay: (String) -> Void = { _ in }

    private let calendar = Calendar.current
    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button { shiftMonth(-1) } label: { arrow("chevron.left") }
                    .help("Previous month")
                Spacer()
                Text(Self.titleFormatter.string(from: month)).font(.headline)
                Spacer()
                Button { shiftMonth(1) } label: { arrow("chevron.right") }
                    .help("Next month")
            }
            .buttonStyle(.plain)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(weekdaySymbols.indices, id: \.self) { i in
                    Text(weekdaySymbols[i]).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(cells.indices, id: \.self) { i in
                    if let date = cells[i] {
                        dayCell(date)
                    } else {
                        Color.clear.frame(height: 30)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// A month arrow with a generous click area (36 x 30 points), not just the glyph.
    private func arrow(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 36, height: 30)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let key = Self.keyFormatter.string(from: date)
        let hasRecordings = daysWithRecordings.contains(key)
        let isSelected = selectedDay == key
        let isToday = calendar.isDateInToday(date)

        Button {
            selectedDay = key
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.callout)
                    .fontWeight(isToday ? .bold : .regular)
                    .foregroundStyle(isSelected ? Color.white : (hasRecordings ? Color.primary : Color.secondary.opacity(0.6)))
                Circle()
                    .fill(isSelected ? Color.white : Color.accentColor)
                    .frame(width: 5, height: 5)
                    .opacity(hasRecordings ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
                } else if isToday {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasRecordings && !isToday)
        .contextMenu {
            if hasRecordings {
                Button("Copy This Day's Transcripts") { onCopyDay(key) }
            }
        }
        .help(hasRecordings ? "Show recordings from this day" : "No recordings")
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The month's days, padded with nil so the 1st lands under its weekday.
    private var cells: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let dayCount = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var result: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            result.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        return result
    }

    private func shiftMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: month) { month = next }
    }
}
