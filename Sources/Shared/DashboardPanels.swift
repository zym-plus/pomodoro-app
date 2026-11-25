import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

private struct TaskProgress {
    let completed: Int
    let total: Int

    init(_ tasks: [FocusTask]) {
        completed = tasks.count(where: \.done)
        total = tasks.count
    }

    var remaining: Int { total - completed }
    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
    var percentage: String {
        guard total > 0 else { return "—" }
        let percent = min(Int((fraction * 100).rounded()), completed == total ? 100 : 99)
        return "\(percent)%"
    }
    var description: String {
        "\(completed.formatted(.number.locale(dashboardLocale))) of \(countWithUnit(total, unit: "task")) complete"
    }
}

struct TaskPanel: View {
    let tasks: [FocusTask]
    let onAdd: () -> Void
    let onToggle: (FocusTask) -> Void
    let onEdit: (FocusTask) -> Void
    let onDelete: (FocusTask) -> Void
    var headingDate: Date?
    var dateSelector: TaskDateSelector?
    var emptyMessage = "No tasks today."
    var usesSoftGlass = false
    var allowsAddingTask = true

    @ScaledMetric(relativeTo: .body) private var taskFontSize: CGFloat = 15
    @ScaledMetric(relativeTo: .title3) private var titleFontSize: CGFloat = 17
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let progress = TaskProgress(tasks)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let dateSelector {
                    dateSelector
                } else if let headingDate {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tasks")
                            .font(.system(size: titleFontSize, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text("Today · \(headingDate.formatted(dashboardFormatStyle.month().day()))")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }

                Spacer(minLength: 8)

                if allowsAddingTask {
                    IconButton(symbol: "plus", title: "Add Task", fill: Theme.accentSoft, action: onAdd)
                }
            }
            .padding(.bottom, tasks.isEmpty ? 2 : 5)

            if tasks.isEmpty {
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
            } else {
                taskRows

                if headingDate != nil {
                    completionFooter(progress)
                        .padding(.top, 14)
                }
            }
        }
        .padding(20)
        .dashboardCard(usesGlassLens: !usesSoftGlass)
    }

    private var taskRows: some View {
        LazyVStack(spacing: 0) {
            ForEach(tasks) { task in
                taskRow(task)

                if task.id != tasks.last?.id {
                    Rectangle()
                        .fill(Theme.line)
                        .frame(height: 1)
                        .padding(.leading, 48)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func taskRow(_ task: FocusTask) -> some View {
        HStack(spacing: 4) {
            Button {
                onToggle(task)
            } label: {
                ZStack {
                    let box = Circle()
                    if task.done {
                        box.fill(Theme.action)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    } else {
                        box.strokeBorder(Theme.subtle.opacity(0.72), lineWidth: 1.4)
                    }
                }
                .frame(width: 18, height: 18)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(SoftButtonStyle())
            .accessibilityLabel(task.done ? "Mark \(task.title) incomplete" : "Mark \(task.title) complete")
            .help(task.done ? "Mark Incomplete" : "Mark Complete")

            Button {
                onEdit(task)
            } label: {
                Text(task.title)
                    .font(.system(size: taskFontSize))
                    .foregroundStyle(task.done ? Theme.subtle : Theme.ink)
                    .strikethrough(task.done)
                    .lineLimit(headingDate != nil && !dynamicType.isAccessibilitySize ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SoftButtonStyle())
            .accessibilityValue(task.done ? "Complete" : "Incomplete")
            .accessibilityHint("Edit Task")
            .help("Edit Task")
            .contextMenu { taskActions(task) }

            Menu {
                taskActions(task)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
#if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
#endif
            .tint(Theme.muted)
            .accessibilityLabel("More actions for \(task.title)")
            .help("More Task Actions")
        }
    }

    @ViewBuilder
    private func taskActions(_ task: FocusTask) -> some View {
        Button { onEdit(task) } label: { Label("Edit Task", systemImage: "pencil") }
        Button(role: .destructive) { onDelete(task) } label: { Label("Delete Task", systemImage: "trash") }
    }

    private func completionFooter(_ progress: TaskProgress) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Completed")
                Spacer(minLength: 8)
                Text("\(progress.completed) / \(progress.total)")
                    .monospacedDigit()
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.muted)

            progressTrack(progress.fraction)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.description)
    }

    private func progressTrack(_ completion: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: proxy.size.width * completion)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: completion)
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

enum TaskListDay: Equatable {
    case today
    case date(String)
    case undated

    func date(at now: Date) -> Date? {
        switch self {
        case .today: now
        case .date(let key): TaskDay.date(for: key)
        case .undated: nil
        }
    }

    func title(at now: Date) -> String {
        guard let date = date(at: now) else {
            if case .date(let key) = self { return key }
            return "Undated"
        }
        let calendar = dashboardCalendar
        let style = calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? dashboardFormatStyle.month().day()
            : dashboardFormatStyle.month().day().year()
        let formatted = date.formatted(style)
        if calendar.isDate(date, inSameDayAs: now) { return "Today · \(formatted)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday · \(formatted)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow · \(formatted)"
        }
        return formatted
    }
}

struct TaskDateSelector: View {
    @Binding var selection: TaskListDay
    let now: Date
    let hasUndatedTasks: Bool

    @State private var isPresented = false
    @State private var showsCalendar = false

    var body: some View {
        Button {
            showsCalendar = false
            isPresented = true
        } label: {
            HStack(spacing: 7) {
                Text(selection.title(at: now))
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftButtonStyle())
        .accessibilityLabel("Task Date")
        .accessibilityValue(selection.title(at: now))
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Group {
                if showsCalendar {
                    TaskCalendarPicker(initialDate: selection.date(at: now) ?? now, onBack: { showsCalendar = false }) {
                        select(date: $0)
                    }
                } else {
                    choices
                }
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 3) {
            option("Today", isSelected: matches(now)) { select(.today) }
            if let yesterday = dashboardCalendar.date(byAdding: .day, value: -1, to: now) {
                option("Yesterday", isSelected: matches(yesterday)) { select(date: yesterday) }
            }
            if let tomorrow = dashboardCalendar.date(byAdding: .day, value: 1, to: now) {
                option("Tomorrow", isSelected: matches(tomorrow)) { select(date: tomorrow) }
            }
            Divider().padding(.vertical, 3)
            option("Choose Date…", symbol: "calendar") { showsCalendar = true }
            if hasUndatedTasks {
                option("Undated", isSelected: selection == .undated) { select(.undated) }
            }
        }
        .padding(9)
        .frame(minWidth: 205)
    }

    private func option(
        _ title: String,
        isSelected: Bool = false,
        symbol: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                if isSelected || symbol != nil {
                    Image(systemName: isSelected ? "checkmark" : (symbol ?? ""))
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 34)
            .foregroundStyle(isSelected ? Theme.accentDark : Theme.ink)
            .background(isSelected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func matches(_ date: Date) -> Bool {
        selection.date(at: now).map { dashboardCalendar.isDate($0, inSameDayAs: date) } ?? false
    }

    private func select(date: Date) {
        let isToday = dashboardCalendar.isDate(now, inSameDayAs: date)
        select(isToday ? .today : .date(TaskDay.key(for: date)))
    }

    private func select(_ day: TaskListDay) {
        selection = day
        isPresented = false
    }
}

struct TaskCalendarPicker: View {
    @State private var selection: Date
    var onBack: (() -> Void)?
    let onSelect: (Date) -> Void

    init(initialDate: Date, onBack: (() -> Void)? = nil, onSelect: @escaping (Date) -> Void) {
        _selection = State(initialValue: initialDate)
        self.onBack = onBack
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            DatePicker("Date", selection: $selection, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .environment(\.calendar, dashboardCalendar)
                .environment(\.timeZone, dashboardCalendar.timeZone)

            HStack {
                if let onBack {
                    Button("Back", action: onBack)
                }
                Spacer()
                Button("Select Date") { onSelect(selection) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(idealWidth: 300, maxWidth: 340)
    }
}

struct StatsPanel: View {
    let history: [FocusSession]
    let tasks: [FocusTask]
    let now: Date

    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .body) private var wideMetricWidth: CGFloat = 540
    @ScaledMetric(relativeTo: .body) private var pairedMetricWidth: CGFloat = 300
    @ScaledMetric(relativeTo: .body) private var pairedChartWidth: CGFloat = 630

    private func week(ending today: Date, calendar: Calendar) -> [DayTotal] {
        let minutes = history.reduce(into: [Date: Int]()) { grouped, session in
            grouped[calendar.startOfDay(for: session.at), default: 0] += session.minutes
        }

        return (-6...0).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let start = calendar.startOfDay(for: date)
            return DayTotal(date: start, minutes: minutes[start, default: 0])
        }
    }

    var body: some View {
        let calendar = dashboardCalendar
        let todayDate = calendar.startOfDay(for: now)
        let days = week(ending: todayDate, calendar: calendar)
        let todayCount = history.count { calendar.isDate($0.at, inSameDayAs: todayDate) }
        let progress = TaskProgress(tasks)
        let today = focusMetric(title: "Focus Today", minutes: days.last?.minutes ?? 0, count: todayCount)
        let total = focusMetric(title: "Total Focus", minutes: totalMinutes, count: history.count)
        let plan = metric(
            title: "Today’s Plan",
            value: Text(progress.percentage),
            detail: Text(progress.total == 0 ? "No tasks today" : progress.description)
        )
        let weekly = weeklyCard(days, today: todayDate)
        let breakdown = TaskBreakdownCard(progress: progress)

        return VStack(spacing: 16) {
            ViewThatFits(in: .horizontal) {
                if !dynamicType.isAccessibilitySize {
                    HStack(spacing: 12) {
                        today
                        total
                        plan
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: wideMetricWidth)

                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            today
                            total
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        plan.fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(minWidth: pairedMetricWidth)
                }
                VStack(spacing: 12) {
                    today
                    total
                    plan
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                if !dynamicType.isAccessibilitySize {
                    HStack(alignment: .top, spacing: 14) {
                        weekly
                        breakdown
                    }
                    .frame(minWidth: pairedChartWidth)
                }

                VStack(spacing: 14) {
                    weekly
                    breakdown
                }
            }
        }
    }

    private func weeklyCard(_ days: [DayTotal], today: Date) -> some View {
        let maxMinutes = days.map(\.minutes).max() ?? 0

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Last 7 Days")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if maxMinutes > 0 && !dynamicType.isAccessibilitySize {
                    Text("Minutes")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }

            if maxMinutes == 0 {
                Text("No focus sessions in the last 7 days.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            } else if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(days) { day in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(day.date == today ? "Today" : day.date.formatted(dashboardDateStyle))
                                .foregroundStyle(Theme.ink)

                            Spacer(minLength: 0)

                            Text(countWithUnit(day.minutes, unit: "minute"))
                                .monospacedDigit()
                                .foregroundStyle(Theme.muted)
                                .multilineTextAlignment(.trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(days) { day in
                        dayBar(day, scale: maxMinutes, isToday: day.date == today)
                    }
                }
            }
        }
        .padding(20)
        .dashboardCard()
    }

    private var totalMinutes: Int { history.reduce(0) { $0 + $1.minutes } }

    private func focusMetric(title: LocalizedStringKey, minutes: Int, count: Int) -> some View {
        let number = Text(minutes, format: .number.locale(dashboardLocale))
        let unit = Text(minutes == 1 ? "minute" : "minutes")
            .font(.subheadline.weight(.medium))
            .foregroundColor(Theme.muted)

        return metric(
            title: title,
            value: Text("\(number) \(unit)"),
            detail: Text(countWithUnit(count, unit: "session"))
        )
    }

    private func metric(title: LocalizedStringKey, value: Text, detail: Text) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.muted)
            value
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(dynamicType.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.75)
            detail
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .dashboardCard()
        .accessibilityElement(children: .combine)
    }

    private func dayBar(_ day: DayTotal, scale: Int, isToday: Bool) -> some View {
        let height = 102 * CGFloat(day.minutes) / CGFloat(scale)

        return VStack(spacing: 7) {
            VStack(spacing: 4) {
                if day.minutes > 0 {
                    Text(day.minutes, format: .number)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)

                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.accent)
                        .frame(maxWidth: 31)
                        .frame(height: max(3, height))
                } else {
                    Capsule().fill(Theme.track).frame(maxWidth: 31).frame(height: 3)
                }
            }
            .frame(height: 125, alignment: .bottom)

            Text(isToday ? "Today" : day.date.formatted(dashboardFormatStyle.weekday(.abbreviated)))
                .font(.caption2.weight(isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? Theme.accentDark : Theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.date.formatted(dashboardDateStyle))
        .accessibilityValue(countWithUnit(day.minutes, unit: "minute"))
    }

    private struct DayTotal: Identifiable {
        let date: Date
        let minutes: Int
        var id: Date { date }
    }
}

private struct TaskBreakdownCard: View {
    let progress: TaskProgress

    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Today’s Tasks")
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)

            if progress.total == 0 {
                Text("No tasks to chart yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            } else {
                ViewThatFits(in: .horizontal) {
                    if !dynamicType.isAccessibilitySize {
                        HStack(spacing: 18) {
                            donut
                            legend.fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(minHeight: 143)
                    }
                    VStack(spacing: 16) {
                        donut
                        legend
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .dashboardCard()
    }

    private var donut: some View {
        let lineWidth: CGFloat = 16

        return ZStack {
            ZStack {
                Circle().strokeBorder(Theme.track, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: progress.fraction)
                    .stroke(Theme.accent, lineWidth: lineWidth)
                    .rotationEffect(.degrees(-90))
                    .padding(lineWidth / 2)
            }
            .accessibilityHidden(true)

            VStack(spacing: 1) {
                Text(progress.total, format: .number.locale(dashboardLocale))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Text(progress.total == 1 ? "task" : "tasks")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .padding(.horizontal, 25)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(countWithUnit(progress.total, unit: "task"))
        }
        .frame(width: 118, height: 118)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 12) {
            entry("Completed", count: progress.completed, swatch: Theme.accent)
            entry("Remaining", count: progress.remaining, swatch: Theme.track)
        }
    }

    private func entry(_ title: String, count: Int, swatch: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(swatch)
                .overlay { Circle().strokeBorder(Theme.muted.opacity(0.2)) }
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            Text(title).foregroundStyle(Theme.muted)
            Spacer(minLength: 4)
            Text(count, format: .number.locale(dashboardLocale))
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

struct CalendarPanel: View {
    let history: [FocusSession]
    let tasks: [FocusTask]
    let now: Date
    var placesRecordsBesideMonth = false

    @State private var selectedDate: DateComponents?
    @ScaledMetric(relativeTo: .body) private var dayHeight: CGFloat = 44
    @Environment(\.dynamicTypeSize) private var dynamicType

    private let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 3), count: 7)
    private let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        monthView(CalendarMonth(now: now, selectedDate: selectedDate))
    }

    private func monthView(_ month: CalendarMonth) -> some View {
        let byDay = Dictionary(grouping: history) { month.calendar.startOfDay(for: $0.at) }
        let tasksByDay = Dictionary(grouping: tasks, by: \.plannedDay)
        let days = month.days
        let entries = byDay[month.selectedDay, default: []].sorted { $0.at > $1.at }
        let dayTasks = tasksByDay[TaskDay.key(for: month.selectedDay), default: []]
        let split = placesRecordsBesideMonth && !dynamicType.isAccessibilitySize
        let layout = split
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            : AnyLayout(VStackLayout(spacing: 16))

        return layout {
            VStack(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        monthHeading(month).fixedSize(horizontal: true, vertical: false)
                        Spacer()
                        monthControls(month)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        monthHeading(month)
                        monthControls(month).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(weekdays, id: \.self) { day in
                        Text(day)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    }

                    ForEach(days.indices, id: \.self) { index in
                        if let day = days[index] {
                            dayButton(
                                day,
                                sessions: byDay[day, default: []].count,
                                taskCount: tasksByDay[TaskDay.key(for: day), default: []].count,
                                in: month
                            )
                        } else {
                            Color.clear.frame(height: dayHeight).accessibilityHidden(true)
                        }
                    }
                }
            }
            .padding(18)
            .dashboardCard()

            records(entries, tasks: dayTasks, on: month.selectedDay)
                .frame(maxWidth: split ? 344 : .infinity)
        }
    }

    private func monthHeading(_ month: CalendarMonth) -> some View {
        Text(month.start.formatted(dashboardFormatStyle.month(.wide).year()))
            .font(.headline)
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private func monthControls(_ month: CalendarMonth) -> some View {
        HStack(spacing: 4) {
            if selectedDate != nil {
                Button {
                    selectedDate = nil
                } label: {
                    Text("Today")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accentDark)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftButtonStyle())
                .accessibilityLabel("Back to Today")
                .help("Back to Today")
            }

            monthControl(-1, symbol: "chevron.left", label: "Previous Month", in: month)
            monthControl(1, symbol: "chevron.right", label: "Next Month", in: month)
        }
    }

    private func monthControl(_ offset: Int, symbol: String, label: LocalizedStringKey, in month: CalendarMonth) -> some View {
        Button {
            if let next = month.selection(afterMovingBy: offset) {
                selectedDate = month.components(for: next)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SoftButtonStyle())
        .accessibilityLabel(Text(label))
        .help(Text(label))
    }

    private func dayButton(_ date: Date, sessions: Int, taskCount: Int, in month: CalendarMonth) -> some View {
        let isSelected = date == month.selectedDay
        let isToday = date == month.today
        let fullDate = date.formatted(dashboardDateStyle.year())
        let outline = RoundedRectangle(cornerRadius: 12)

        return Button {
            selectedDate = month.components(for: date)
        } label: {
            VStack(spacing: 4) {
                Text(month.calendar.component(.day, from: date), format: .number)
                    .font(.subheadline.weight(isSelected || isToday ? .semibold : .regular))
                    .foregroundStyle(isSelected || isToday ? Theme.accentDark : Theme.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                Circle()
                    .fill(sessions > 0 || taskCount > 0 ? Theme.accentDark : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: dayHeight)
            .background(isSelected ? Theme.accentSoft : .clear, in: outline)
            .overlay {
                if isToday && !isSelected {
                    outline.strokeBorder(Theme.accent.opacity(0.68))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftButtonStyle())
        .accessibilityLabel(isToday ? Text("Today, \(fullDate)") : Text(fullDate))
        .accessibilityValue("\(countWithUnit(taskCount, unit: "task")), \(countWithUnit(sessions, unit: "focus session"))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func records(_ sessions: [FocusSession], tasks: [FocusTask], on day: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(day.formatted(dashboardDateStyle))
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)

            if !tasks.isEmpty {
                Text("Tasks")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                ForEach(tasks) { task in
                    Label(task.title, systemImage: task.done ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline)
                        .foregroundStyle(task.done ? Theme.muted : Theme.ink)
                        .accessibilityValue(task.done ? "Complete" : "Incomplete")
                }

                Divider()

                Text("Focus Sessions")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }

            if sessions.isEmpty {
                Text("No focus sessions on this day.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }

            ForEach(sessions) { session in
                HStack(spacing: 9) {
                    Image(systemName: "timer")
                        .foregroundStyle(Theme.accentDark)
                        .accessibilityHidden(true)

                    Text(session.at, style: .time)
                        .foregroundStyle(Theme.ink)

                    Spacer()

                    Text(countWithUnit(session.minutes, unit: "minute"))
                        .foregroundStyle(Theme.muted)
                }
                .font(.subheadline.monospacedDigit())
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(19)
        .dashboardCard()
    }
}

private struct CalendarMonth {
    let calendar: Calendar
    let today: Date
    let selectedDay: Date
    let start: Date

    init(now: Date, selectedDate: DateComponents?, calendar: Calendar = dashboardCalendar) {
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
        selectedDay = selectedDate.flatMap { calendar.date(from: $0) }
            .map { calendar.startOfDay(for: $0) } ?? today
        start = calendar.dateInterval(of: .month, for: selectedDay)?.start ?? selectedDay
    }

    var days: [Date?] {
        let weekday = calendar.component(.weekday, from: start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        guard let monthRange = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let leadingDays = Array<Date?>(repeating: nil, count: leading)
        var dateParts = calendar.dateComponents([.year, .month], from: start)

        return leadingDays + monthRange.map { day in
            dateParts.day = day
            guard let date = calendar.date(from: dateParts), calendar.component(.day, from: date) == day else { return nil }
            return calendar.startOfDay(for: date)
        }
    }

    func selection(afterMovingBy offset: Int) -> Date? {
        guard let next = calendar.date(byAdding: .month, value: offset, to: start),
              let nextStart = calendar.dateInterval(of: .month, for: next)?.start else { return nil }
        return calendar.isDate(next, equalTo: today, toGranularity: .month) ? today : nextStart
    }

    func components(for day: Date) -> DateComponents? {
        day == today ? nil : calendar.dateComponents([.year, .month, .day], from: day)
    }
}

struct CurrentDashboardTime<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = Date.now

    @ViewBuilder let content: (Date) -> Content

    private let calendarChanges = Publishers.Merge3(
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged),
        NotificationCenter.default.publisher(for: .NSSystemClockDidChange),
        NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
    )

    var body: some View {
        content(now)
            .onAppear { now = .now }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { now = .now }
            }
            .onReceive(calendarChanges.receive(on: RunLoop.main)) { _ in now = .now }
#if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                now = .now
            }
#endif
            .task(id: now) {
                guard let midnight = dashboardCalendar.dateInterval(of: .day, for: now)?.end else { return }
                do {
                    try await Task.sleep(for: .seconds(max(0, midnight.timeIntervalSinceNow)))
                    if !Task.isCancelled { now = .now }
                } catch {
                    return
                }
            }
    }
}

private let dashboardLocale = Locale(identifier: "en_US")

var dashboardCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = dashboardLocale
    calendar.timeZone = .autoupdatingCurrent
    calendar.firstWeekday = 2
    return calendar
}

private var dashboardDateStyle: Date.FormatStyle {
    dashboardFormatStyle.month().day().weekday(.wide)
}

var dashboardFormatStyle: Date.FormatStyle {
    let calendar = dashboardCalendar
    return Date.FormatStyle(locale: dashboardLocale, calendar: calendar, timeZone: calendar.timeZone)
}

private func countWithUnit(_ count: Int, unit: String) -> String {
    "\(count.formatted(.number.locale(dashboardLocale))) \(unit)\(count == 1 ? "" : "s")"
}
