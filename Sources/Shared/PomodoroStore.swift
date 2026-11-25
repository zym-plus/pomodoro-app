import Combine
import Foundation

func monotonicTime() -> TimeInterval {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
}

enum TimerMode: String, Codable, CaseIterable, Identifiable {
    case focus
    case shortBreak
    case longBreak

    var id: String { rawValue }
}

struct TimerSettings: Codable, Equatable {
    static let allowedMinutes = 1...180

    var focus = 25
    var short = 5
    var long = 15
    var sound = true
    var autoBreak = false
    var autoFocus = false

    func minutes(for mode: TimerMode) -> Int {
        switch mode {
        case .focus: focus
        case .shortBreak: short
        case .longBreak: long
        }
    }

    fileprivate mutating func clampDurations() {
        focus = Self.clamped(focus)
        short = Self.clamped(short)
        long = Self.clamped(long)
    }

    private static func clamped(_ minutes: Int) -> Int {
        min(max(minutes, allowedMinutes.lowerBound), allowedMinutes.upperBound)
    }
}

enum TaskDay {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    static func key(for date: Date) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 1, day.month ?? 1, day.day ?? 1)
    }

    static func date(for key: String) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), (1...9999).contains(year),
              let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day) else { return nil }
        let calendar = Self.calendar
        // Noon keeps the requested civil day even where midnight is skipped.
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              Self.key(for: date) == key else { return nil }
        return calendar.startOfDay(for: date)
    }
}

struct FocusTask: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var done = false
    var plannedDay: String?
}

struct FocusSession: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var at: Date
    var minutes: Int
}

struct TimerCompletion: Equatable, Identifiable {
    var id = UUID()
    var mode: TimerMode
    var at: Date
    var notificationDeadline: Date? = nil
}

struct PomodoroSnapshot: Codable, Equatable {
    var mode: TimerMode = .focus
    var duration = 25 * 60
    var deadline: Date?
    var round = 1
    var tasks: [FocusTask] = []
    var history: [FocusSession] = []
    var settings = TimerSettings()
    fileprivate var remainingInterval: TimeInterval = 25 * 60

    var running: Bool { deadline != nil }
    var remaining: Int { Int(ceil(remainingInterval)) }
    var hasElapsed: Bool { remainingInterval < TimeInterval(duration) }
}

@MainActor
final class PomodoroStore: ObservableObject {
    @Published private(set) var snapshot: PomodoroSnapshot
    @Published private(set) var lastCompletion: TimerCompletion?

    var todayTaskDay: String { TaskDay.key(for: now()) }

    private static let storageKey = "Pomodoro.snapshot.v1"
    private static let cycleLength = 4
    private static let deadlineCorrectionThreshold: TimeInterval = 0.25

    private struct Instant {
        let date: Date
        let elapsed: TimeInterval?
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private let elapsed: (() -> TimeInterval)?
    private let runsTicker: Bool
    private var elapsedDeadline: TimeInterval?
    private var ticker: AnyCancellable?

    init(
        defaults: UserDefaults = .standard,
        now: (() -> Date)? = nil,
        runTicker: Bool = true,
        elapsed: (() -> TimeInterval)? = nil
    ) {
        self.defaults = defaults
        self.now = now ?? Date.init
        if let elapsed {
            self.elapsed = elapsed
        } else if now == nil {
            self.elapsed = monotonicTime
        } else {
            self.elapsed = nil
        }
        self.runsTicker = runTicker
        snapshot = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(PomodoroSnapshot.self, from: $0) }
            ?? PomodoroSnapshot()
        var next = snapshot
        next.tasks = validatingTaskDays(next.tasks)
        next.settings.clampDurations()
        let minutes = next.duration / 60
        if !TimerSettings.allowedMinutes.contains(minutes) || next.duration % 60 != 0
            || !next.remainingInterval.isFinite || next.remainingInterval <= 0
            || next.remainingInterval > TimeInterval(next.duration) {
            prepare(&next, for: next.mode)
        }
        commit(next)
        let instant = currentInstant()
        if let deadline = snapshot.deadline, let elapsed = instant.elapsed {
            elapsedDeadline = elapsed + deadline.timeIntervalSince(instant.date)
        }
        refresh(at: instant)
        updateTicker()
    }

    func refresh() {
        guard snapshot.running else { return }
        refresh(at: currentInstant())
    }

    @discardableResult
    private func refresh(at instant: Instant) -> Bool {
        guard let deadline = snapshot.deadline else { return false }
        let wallTimeLeft = deadline.timeIntervalSince(instant.date)
        let timeLeft = remainingTime(until: deadline, at: instant)
        let needsCorrection = abs(wallTimeLeft - timeLeft) >= Self.deadlineCorrectionThreshold
        let correctedDeadline = needsCorrection ? instant.date.addingTimeInterval(timeLeft) : deadline

        if timeLeft <= 0 {
            var next = snapshot
            let finishedMode = next.mode
            if finishedMode == .focus {
                next.history.append(FocusSession(at: correctedDeadline, minutes: next.duration / 60))
            }
            let startsAutomatically = finishedMode == .focus ? next.settings.autoBreak : next.settings.autoFocus
            advance(&next, completed: true)
            if startsAutomatically {
                start(&next, at: instant)
            }
            commit(next)
            lastCompletion = TimerCompletion(mode: finishedMode, at: correctedDeadline, notificationDeadline: deadline)
            return true
        }

        let visibleTimeLeft = min(timeLeft, TimeInterval(snapshot.duration))
        if needsCorrection {
            var next = snapshot
            next.deadline = correctedDeadline
            next.remainingInterval = visibleTimeLeft
            commit(next)
        } else if Int(ceil(visibleTimeLeft)) != snapshot.remaining {
            snapshot.remainingInterval = visibleTimeLeft
        }
        return false
    }

    func toggle() {
        let instant = currentInstant()
        guard !refresh(at: instant) else { return }
        var next = snapshot
        if let deadline = next.deadline {
            next.remainingInterval = min(remainingTime(until: deadline, at: instant), TimeInterval(next.duration))
            next.deadline = nil
        } else {
            start(&next, at: instant)
        }
        commit(next)
    }

    func reset() {
        guard !refresh(at: currentInstant()) else { return }
        var next = snapshot
        prepare(&next, for: next.mode)
        commit(next)
    }

    func skip() {
        guard !refresh(at: currentInstant()) else { return }
        var next = snapshot
        advance(&next, completed: false)
        commit(next)
    }

    func setMode(_ mode: TimerMode) {
        let previousMode = snapshot.mode
        refresh()
        guard mode != previousMode, mode != snapshot.mode else { return }
        var next = snapshot
        prepare(&next, for: mode)
        commit(next)
    }

    func saveSettings(_ settings: TimerSettings) {
        refresh()
        var next = snapshot
        next.settings = settings
        next.settings.clampDurations()
        if !next.running && next.remainingInterval == TimeInterval(next.duration) {
            prepare(&next, for: next.mode)
        }
        commit(next)
    }

    func addTask(_ title: String, plannedDay: String? = nil) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var next = snapshot
        next.tasks.append(FocusTask(title: title, plannedDay: validatedTaskDay(plannedDay) ?? todayTaskDay))
        commit(next)
    }

    func toggleTask(_ id: UUID) {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return }
        var next = snapshot
        next.tasks[index].done.toggle()
        commit(next)
    }

    func deleteTask(_ id: UUID) {
        var next = snapshot
        next.tasks.removeAll { $0.id == id }
        commit(next)
    }

    func editTask(_ id: UUID, title: String, plannedDay: String? = nil) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return }
        var next = snapshot
        next.tasks[index].title = title
        if let day = validatedTaskDay(plannedDay) {
            next.tasks[index].plannedDay = day
        }
        commit(next)
    }

    func replaceTasks(_ tasks: [FocusTask]) {
        var next = snapshot
        next.tasks = validatingTaskDays(tasks)
        commit(next)
    }

    private func validatingTaskDays(_ tasks: [FocusTask]) -> [FocusTask] {
        tasks.map { task in
            var task = task
            task.plannedDay = validatedTaskDay(task.plannedDay)
            return task
        }
    }

    private func validatedTaskDay(_ day: String?) -> String? {
        guard let day, TaskDay.date(for: day) != nil else { return nil }
        return day
    }

    private func advance(_ next: inout PomodoroSnapshot, completed: Bool) {
        switch next.mode {
        case .focus:
            let longBreakDue = completed && next.history.count.isMultiple(of: Self.cycleLength)
            prepare(&next, for: longBreakDue ? .longBreak : .shortBreak)
        case .shortBreak, .longBreak:
            prepare(&next, for: .focus)
        }
    }

    private func prepare(_ next: inout PomodoroSnapshot, for mode: TimerMode) {
        next.mode = mode
        next.duration = next.settings.minutes(for: mode) * 60
        next.remainingInterval = TimeInterval(next.duration)
        next.deadline = nil
        if mode == .focus {
            next.round = next.history.count % Self.cycleLength + 1
        }
    }

    private func currentInstant() -> Instant {
        Instant(date: now(), elapsed: elapsed?())
    }

    private func remainingTime(until deadline: Date, at instant: Instant) -> TimeInterval {
        if let elapsed = instant.elapsed, let elapsedDeadline {
            return elapsedDeadline - elapsed
        }
        return deadline.timeIntervalSince(instant.date)
    }

    private func start(_ next: inout PomodoroSnapshot, at instant: Instant) {
        next.deadline = instant.date.addingTimeInterval(next.remainingInterval)
        elapsedDeadline = instant.elapsed.map { $0 + next.remainingInterval }
    }

    private func commit(_ next: PomodoroSnapshot) {
        guard next != snapshot else { return }
        if !next.running { elapsedDeadline = nil }
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.storageKey)
        }
        snapshot = next
        updateTicker()
    }

    private func updateTicker() {
        guard runsTicker else { return }
        guard snapshot.running else {
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        ticker = Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }
}
