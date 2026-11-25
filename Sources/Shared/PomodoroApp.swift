import Combine
import SwiftUI

@main
struct PomodoroApp: App {
    @StateObject private var session = PomodoroSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        mainScene
            .onChange(of: scenePhase, initial: true) { _, phase in
                session.sceneDidChange(phase)
            }
    }

    private var mainScene: some Scene {
#if os(macOS)
        Window("Pomodoro", id: "main") {
            content
                .frame(minWidth: 760, minHeight: 510)
        }
        .defaultSize(width: 1060, height: 550)
        .windowStyle(.hiddenTitleBar)
#else
        WindowGroup {
            content
        }
#endif
    }

    private var content: some View {
        PomodoroRoot(
            store: session.store,
            reminders: session.reminders,
            obsidian: session.obsidian,
            whiteNoiseEnabled: $session.whiteNoiseEnabled
        )
            .environment(\.locale, Locale(identifier: "en_US"))
    }
}

@MainActor
private final class PomodoroSession: ObservableObject {
    private static let whiteNoiseKey = "Pomodoro.whiteNoise"

    let store: PomodoroStore
    let obsidian: ObsidianSync
    let reminders: TimerReminders
    private let audio: TimerAudio

    @Published var whiteNoiseEnabled = UserDefaults.standard.bool(forKey: whiteNoiseKey) {
        didSet {
            guard whiteNoiseEnabled != oldValue else { return }
            UserDefaults.standard.set(whiteNoiseEnabled, forKey: Self.whiteNoiseKey)
            syncWhiteNoise(for: store.snapshot)
        }
    }

    private var scenePhase = ScenePhase.inactive
    private var subscriptions = Set<AnyCancellable>()

    private struct ReminderConfiguration: Equatable {
        let deadline: Date?
        let mode: TimerMode
        let sound: Bool

        init(_ snapshot: PomodoroSnapshot) {
            deadline = snapshot.deadline
            mode = snapshot.mode
            sound = snapshot.settings.sound
        }
    }

    init() {
        let store = PomodoroStore()
        self.store = store
        obsidian = ObsidianSync(store: store)
        let audio = TimerAudio()
        self.audio = audio
        reminders = TimerReminders(audio: audio)

        store.$snapshot
            .map(ReminderConfiguration.init)
            .removeDuplicates()
            .sink { [weak self] configuration in self?.syncReminder(configuration) }
            .store(in: &subscriptions)

        store.$snapshot
            .map { $0.mode == .focus && $0.running }
            .removeDuplicates()
            .sink { [weak self] focusing in
                guard let self else { return }
                audio.setWhiteNoisePlaying(focusing && whiteNoiseEnabled)
            }
            .store(in: &subscriptions)

        reminders.$status
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                syncReminder(ReminderConfiguration(store.snapshot))
            }
            .store(in: &subscriptions)

        store.$lastCompletion
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] completion in self?.handleCompletion(completion) }
            .store(in: &subscriptions)
    }

    func sceneDidChange(_ phase: ScenePhase) {
        scenePhase = phase
        obsidian.setActive(phase == .active)
        guard phase == .active else { return }
        store.refresh()
        syncWhiteNoise(for: store.snapshot)
        Task { [weak self] in
            guard let self else { return }
            await reminders.refreshAuthorization()
            syncReminder(ReminderConfiguration(store.snapshot))
        }
    }

    private func syncReminder(_ configuration: ReminderConfiguration) {
        reminders.sync(deadline: configuration.deadline, mode: configuration.mode, sound: configuration.sound)
    }

    private func syncWhiteNoise(for snapshot: PomodoroSnapshot) {
        audio.setWhiteNoisePlaying(whiteNoiseEnabled && snapshot.mode == .focus && snapshot.running)
    }

    private func handleCompletion(_ completion: TimerCompletion) {
        guard abs(completion.at.timeIntervalSinceNow) < 4, store.snapshot.settings.sound else { return }
#if os(macOS)
        let shouldPlay = scenePhase == .active || !reminders.authorized
#else
        let shouldPlay = scenePhase == .active
#endif
        if shouldPlay { reminders.playChime(for: completion) }
    }
}

private enum Section: String, CaseIterable, Identifiable {
    case timer, tasks, statistics, calendar

    var id: Self { self }

    var title: String {
        switch self {
        case .timer: "Timer"
        case .tasks: "Tasks"
        case .statistics: "Stats"
        case .calendar: "Calendar"
        }
    }

    var symbol: String {
        switch self {
        case .timer: "timer"
        case .tasks: "checkmark.circle"
        case .statistics: "chart.bar"
        case .calendar: "calendar"
        }
    }
}

#if os(macOS)
private struct DesktopWorkspace {
    let size: CGSize

    private var expansion: CGFloat {
        max(0, min(400, size.width - 976, (size.height - 580) * 1.5))
    }

    var centersTimer: Bool { size.height >= 610 }

    func width(for section: Section) -> CGFloat {
        let margin = 28 + min(24, expansion * 0.08)
        let maximum: CGFloat
        switch section {
        case .timer: maximum = 920 + min(40, expansion)
        case .tasks: maximum = 680
        case .statistics, .calendar: maximum = 920 + min(240, expansion)
        }
        return min(maximum, max(0, size.width - 2 * margin))
    }
}
#endif

private enum PresentedSheet: Identifiable {
    case settings
    case reminders
    case task(FocusTask?, defaultDay: String)

    var id: String {
        switch self {
        case .settings: "settings"
        case .reminders: "reminders"
        case .task(let task, let day): task?.id.uuidString ?? "new-task-\(day)"
        }
    }
}

struct PomodoroRoot: View {
    @ObservedObject var store: PomodoroStore
    @ObservedObject var reminders: TimerReminders
    let obsidian: ObsidianSync
    @Binding var whiteNoiseEnabled: Bool
    @AppStorage(AppearanceTheme.storageKey) private var appearance: AppearanceTheme = .glass
    @State private var section: Section = .timer
    @State private var sheet: PresentedSheet?
    @State private var taskListDay: TaskListDay = .today
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var glassEnabled: Bool { appearance == .glass && !reduceTransparency }

    var body: some View {
        CurrentDashboardTime { now in
#if os(macOS)
            desktopLayout(at: now)
#else
            phoneLayout(at: now)
#endif
        }
        .background {
#if os(macOS)
            AppearanceBackdrop(glassEnabled: glassEnabled, blendsWithDesktop: true)
                .ignoresSafeArea()
#else
            AppearanceBackdrop(glassEnabled: glassEnabled)
                .ignoresSafeArea()
#endif
        }
        .tint(Theme.accentDark)
        .onChange(of: section) { _, section in
            if section == .tasks { taskListDay = .today }
        }
        .sheet(item: $sheet, content: editor)
        .environment(\.usesGlassAppearance, glassEnabled)
        .preferredColorScheme(.light)
    }

#if os(macOS)
    private func desktopLayout(at now: Date) -> some View {
        HStack(spacing: 0) {
            sidebar
            GeometryReader { geometry in
                let workspace = DesktopWorkspace(size: geometry.size)
                let contentWidth = workspace.width(for: section)
                VStack(spacing: 0) {
                    HStack {
                        Text(section.title)
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        toolbar
                    }
                    .frame(width: contentWidth)
                    .padding(.top, 15)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)

                    GeometryReader { pageGeometry in
                        if section == .timer && geometry.size.width >= 710 {
                            wideTimerPage(
                                height: pageGeometry.size.height,
                                contentWidth: contentWidth,
                                now: now,
                                centersContent: workspace.centersTimer,
                                usesOpenLayout: true
                            )
                        } else {
                            page(section, at: now, contentWidth: contentWidth)
                        }
                    }
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 25) {
            brand
                .padding(.leading, 9)
                .padding(.top, 22)

            VStack(spacing: 6) {
                ForEach(Section.allCases) { item in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.17)) {
                            section = item
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 19)
                            Text(item.title)
                                .font(.system(size: 14, weight: section == item ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(section == item ? Theme.accentDark : Theme.muted)
                        .padding(.horizontal, 11)
                        .frame(height: 38)
                        .background(
                            section == item ? Theme.accentSoft.opacity(glassEnabled ? 0.82 : 1) : .clear,
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SoftButtonStyle())
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                    .accessibilityRemoveTraits(section == item ? [] : .isSelected)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .frame(width: 173)
        .frame(maxHeight: .infinity)
        .background {
            if glassEnabled {
                Rectangle().fill(.thinMaterial)
                    .opacity(0.32)
                    .overlay {
                        Rectangle().fill(.white.opacity(0.12))
                    }
                    .ignoresSafeArea()
            } else {
                Theme.sidebar.ignoresSafeArea()
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(glassEnabled ? .white.opacity(0.64) : Theme.line)
                .frame(width: 1)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

#else
    private func phoneLayout(at now: Date) -> some View {
        VStack(spacing: 0) {
            HStack {
                if section == .timer {
                    brand
                } else {
                    Text(section.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer()
                toolbar
            }
            .padding(.horizontal, 20)
            .padding(.top, 3)
            .padding(.bottom, 8)

            TabView(selection: $section) {
                ForEach(Section.allCases) { item in
                    GeometryReader { geometry in
                        if item == .timer && geometry.size.width >= 760 {
                            wideTimerPage(
                                height: geometry.size.height,
                                contentWidth: min(920, geometry.size.width - 40),
                                now: now
                            )
                        } else {
                            page(item, at: now)
                        }
                    }
                    .tabItem { Label(item.title, systemImage: item.symbol) }
                    .tag(item)
                }
            }
            .tint(Theme.accentDark)
        }
    }
#endif

    private func wideTimerPage(
        height: CGFloat,
        contentWidth: CGFloat,
        now: Date,
        centersContent: Bool = false,
        usesOpenLayout: Bool = false
    ) -> some View {
        let spacing: CGFloat = usesOpenLayout ? min(46, contentWidth * 0.045) : 16
        let taskWidth = usesOpenLayout ? min(408, contentWidth * 0.42) : contentWidth * 0.39
        let remainingWidth = contentWidth - taskWidth - spacing
        let dialWidth = remainingWidth - (usesOpenLayout ? 20 : 2 * TimerFace.horizontalPadding)
        let mode = centersContent ? .focus : store.snapshot.mode
        let topInset: CGFloat = usesOpenLayout ? 12 : 0
        let bottomInset: CGFloat = 22
        let dialHeight = height - TimerFace.heightOutsideDial(mode: mode, usesOpenLayout: usesOpenLayout)
            - topInset - bottomInset
        let preferredDiameter: CGFloat = usesOpenLayout ? 410 : 420
        let diameter = min(preferredDiameter, dialWidth, max(204, dialHeight))
        let timerWidth = usesOpenLayout ? min(remainingWidth, diameter + 32) : remainingWidth
        let contentHeight = centersContent ? height : 0
        let extraBottomInset = centersContent ? min(52, max(0, dialHeight - diameter)) : 0

        return HStack(alignment: .top, spacing: spacing) {
            ScrollView {
                timerFace(diameter: diameter, usesOpenLayout: usesOpenLayout)
                    .padding(.top, topInset)
                    .padding(.bottom, bottomInset + extraBottomInset)
                    .frame(minHeight: contentHeight)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: timerWidth)

            ScrollView {
                todayTasks(on: now, usesSoftGlass: usesOpenLayout)
                    .padding(.top, usesOpenLayout && !centersContent ? 32 : topInset)
                    .padding(.bottom, centersContent ? 42 + extraBottomInset : bottomInset)
                    .frame(minHeight: contentHeight)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: taskWidth)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func page(_ item: Section, at now: Date, contentWidth: CGFloat? = nil) -> some View {
        ScrollView {
            Group {
                switch item {
                case .timer:
#if os(macOS)
                    let diameter: CGFloat = 210
#else
                    let diameter: CGFloat = 254
#endif
                    VStack(spacing: 16) {
                        timerFace(diameter: diameter)
                        todayTasks(on: now)
                    }
#if !os(macOS)
                    .frame(maxWidth: 470)
#endif
                case .tasks:
                    taskPage(at: now)
                case .statistics:
                    StatsPanel(history: store.snapshot.history, tasks: tasks(on: now), now: now)
                case .calendar:
                    CalendarPanel(
                        history: store.snapshot.history,
                        tasks: store.snapshot.tasks,
                        now: now,
                        placesRecordsBesideMonth: (contentWidth ?? 0) >= 980
                    )
                }
            }
#if os(macOS)
            .frame(width: contentWidth, alignment: .leading)
#else
            .frame(maxWidth: 680)
            .padding(.horizontal, 20)
#endif
            .padding(.top, 3)
            .padding(.bottom, 35)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func timerFace(diameter: CGFloat, usesOpenLayout: Bool = false) -> some View {
        TimerFace(
            store: store,
            whiteNoiseEnabled: $whiteNoiseEnabled,
            maximumDiameter: diameter,
            keyboardShortcutsEnabled: sheet == nil,
            usesOpenLayout: usesOpenLayout
        )
    }

    private var brand: some View {
        HStack(spacing: 10) {
            TomatoMark().frame(width: 29, height: 29)
            Text("Pomodoro")
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.35)
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            IconButton(symbol: reminders.authorized ? "bell.badge" : "bell", title: "Timer Alerts") {
                sheet = .reminders
            }
            IconButton(symbol: "gearshape", title: "Settings") {
                sheet = .settings
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    private func tasks(on day: Date) -> [FocusTask] {
        let key = TaskDay.key(for: day)
        return store.snapshot.tasks.filter { $0.plannedDay == key }
    }

    private func taskPage(at now: Date) -> some View {
        let hasUndated = store.snapshot.tasks.contains { $0.plannedDay == nil }
        let key: String?
        let emptyMessage: String
        switch taskListDay {
        case .undated:
            key = nil
            emptyMessage = "No undated tasks."
        case .today:
            key = TaskDay.key(for: now)
            emptyMessage = "No tasks today."
        case .date(let date):
            key = date
            emptyMessage = "No tasks planned for this day."
        }

        return taskList(
            store.snapshot.tasks.filter { $0.plannedDay == key },
            defaultDay: key ?? TaskDay.key(for: now),
            dateSelector: TaskDateSelector(selection: $taskListDay, now: now, hasUndatedTasks: hasUndated),
            emptyMessage: emptyMessage,
            allowsAddingTask: key != nil
        )
    }

    private func todayTasks(on now: Date, usesSoftGlass: Bool = false) -> some View {
        taskList(
            tasks(on: now),
            defaultDay: TaskDay.key(for: now),
            headingDate: now,
            usesSoftGlass: usesSoftGlass
        )
    }

    private func taskList(
        _ tasks: [FocusTask],
        defaultDay: String,
        headingDate: Date? = nil,
        dateSelector: TaskDateSelector? = nil,
        emptyMessage: String = "No tasks today.",
        usesSoftGlass: Bool = false,
        allowsAddingTask: Bool = true
    ) -> some View {
        TaskPanel(
            tasks: tasks,
            onAdd: { sheet = .task(nil, defaultDay: defaultDay) },
            onToggle: { store.toggleTask($0.id) },
            onEdit: { sheet = .task($0, defaultDay: defaultDay) },
            onDelete: { store.deleteTask($0.id) },
            headingDate: headingDate,
            dateSelector: dateSelector,
            emptyMessage: emptyMessage,
            usesSoftGlass: usesSoftGlass,
            allowsAddingTask: allowsAddingTask
        )
    }

    @ViewBuilder
    private func editor(_ presented: PresentedSheet) -> some View {
        switch presented {
        case .settings:
            TimerSettingsSheet(
                settings: store.snapshot.settings,
                hasCurrentSession: store.snapshot.running || store.snapshot.hasElapsed,
                obsidian: obsidian,
                onSave: store.saveSettings
            )
        case .reminders:
            TimerRemindersSheet(
                reminders: reminders,
                sound: store.snapshot.settings.sound,
                onSoundChange: { value in
                    var settings = store.snapshot.settings
                    settings.sound = value
                    store.saveSettings(settings)
                }
            )
        case .task(let task, let defaultDay):
            TaskEditorSheet(task: task, defaultDay: defaultDay) { title, plannedDay in
                if let task {
                    store.editTask(task.id, title: title, plannedDay: plannedDay)
                } else {
                    store.addTask(title, plannedDay: plannedDay)
                }
            }
        }
    }

}
