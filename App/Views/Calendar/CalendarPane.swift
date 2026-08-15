import SwiftUI
import InkstoneCore

/// Month calendar for daily notes, plus an agenda built from task lines.
///
/// Days that already have a note get a dot; tapping any day opens (or creates)
/// that day's note, which is the whole point of a daily-notes workflow.
struct CalendarPane: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    @State private var visibleMonth = Date()
    @State private var selectedDate = Date()
    @State private var existingDays: Set<DateComponents> = []

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = workspace.settings.data.weekStartsOnMonday ? 2 : 1
        return calendar
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                monthHeader
                weekdayHeader
                monthGrid
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: 460)

            Divider().overlay(style.divider)

            agenda
        }
        .background(style.background)
        .onAppear { existingDays = workspace.dailyNoteDates() }
        .onChange(of: workspace.index.noteCount) { _, _ in existingDays = workspace.dailyNoteDates() }
    }

    private var monthHeader: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(visibleMonth.formatted(.dateTime.year().month(.wide)))
                .font(style.uiFont.weight(.semibold))
                .foregroundStyle(style.text)
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.plain)
        .foregroundStyle(style.secondaryText)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2)
                    .foregroundStyle(style.faintText)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }

    private var monthGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
            ForEach(Array(daysInGrid.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 40)
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let hasNote = existingDays.contains(components)
        let isToday = calendar.isDateInToday(date)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)

        return VStack(spacing: 3) {
            Text(calendar.component(.day, from: date).formatted())
                .font(style.uiFont)
                .foregroundStyle(isSelected ? style.background : (isToday ? style.accent : style.text))
            Circle()
                .fill(hasNote ? style.accent : .clear)
                .frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? style.accent : (isToday ? style.accent.opacity(0.12) : .clear))
        )
        .contentShape(.rect)
        .onTapGesture {
            selectedDate = date
            workspace.openDailyNote(for: date)
            existingDays = workspace.dailyNoteDates()
        }
    }

    /// The month's days padded with leading/trailing blanks to fill whole weeks.
    private var daysInGrid: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: visibleMonth) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leadingBlanks = (firstWeekday - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: visibleMonth)?.count ?? 0

        var result: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for offset in 0..<dayCount {
            result.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
        visibleMonth = next
    }

    /// Notes created or modified on the selected day, plus their open tasks.
    private var agenda: some View {
        List {
            Section(selectedDate.formatted(date: .complete, time: .omitted)) {
                let notes = notesOn(selectedDate)
                if notes.isEmpty {
                    Text("Nothing recorded for this day.")
                        .font(.caption)
                        .foregroundStyle(style.faintText)
                }
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title).font(style.uiFont)
                        Text("\(note.wordCount) words")
                            .font(.caption2)
                            .foregroundStyle(style.faintText)
                    }
                    .contentShape(.rect)
                    .onTapGesture { workspace.openNote(at: note.url) }
                }
            }

            Section(String(localized: "Open tasks")) {
                let tasks = openTasks()
                if tasks.isEmpty {
                    Text("No open tasks in this vault.")
                        .font(.caption)
                        .foregroundStyle(style.faintText)
                }
                ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "square")
                            .font(.caption)
                            .foregroundStyle(style.faintText)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.text).font(.callout)
                            Text(task.noteTitle).font(.caption2).foregroundStyle(style.faintText)
                        }
                    }
                    .contentShape(.rect)
                    .onTapGesture { workspace.openNote(at: task.url) }
                }
            }
        }
        .listStyle(.inset)
    }

    private func notesOn(_ date: Date) -> [NoteMetadata] {
        workspace.index.notes.values
            .filter { calendar.isDate($0.modified, inSameDayAs: date) }
            .sorted { $0.modified > $1.modified }
    }

    private struct AgendaTask {
        let text: String
        let noteTitle: String
        let url: URL
    }

    /// Scans open notes for unchecked task lines. Deliberately capped: this is a
    /// glance, not a full task manager, and reading every file would be slow.
    private func openTasks(limit: Int = 60) -> [AgendaTask] {
        guard let store = workspace.store else { return [] }
        var results: [AgendaTask] = []
        let recent = workspace.index.notes.values
            .sorted { $0.modified > $1.modified }
            .prefix(40)

        for note in recent {
            guard let text = try? store.read(note.url) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("* [ ]") else { continue }
                results.append(AgendaTask(
                    text: String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces),
                    noteTitle: note.title,
                    url: note.url
                ))
                if results.count >= limit { return results }
            }
        }
        return results
    }
}
