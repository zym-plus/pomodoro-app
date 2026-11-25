import Combine
import Foundation

@MainActor
final class ObsidianSync: ObservableObject {
    @Published private(set) var vault: ObsidianVault?
    @Published private(set) var isSyncing = false
    @Published private(set) var errorMessage: String?

    private static let connectionKey = "Pomodoro.obsidian.connection.v1"
    private static let baselinesKey = "Pomodoro.obsidian.baselines.v1"

    private let store: PomodoroStore
    private let defaults: UserDefaults
    private var baselines: [String: [FocusTask]]
    private var changes: AnyCancellable?
    private var polling: AnyCancellable?
    private var needsSync = false

    init(store: PomodoroStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.connectionKey) {
            vault = try? JSONDecoder().decode(ObsidianVault.self, from: data)
        }
        baselines = defaults.data(forKey: Self.baselinesKey)
            .flatMap { try? JSONDecoder().decode([String: [FocusTask]].self, from: $0) } ?? [:]
        changes = store.$snapshot
            .map { Content(tasks: $0.tasks, history: $0.history) }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
    }

    func setActive(_ active: Bool) {
        if active {
            sync()
            if polling == nil {
                polling = Timer.publish(every: 5, on: .main, in: .common)
                    .autoconnect()
                    .sink { [weak self] _ in self?.sync() }
            }
        } else {
            polling = nil
        }
    }

    func connect(_ folder: URL) {
        do {
            let selection = try ObsidianVault(folder: folder)
            let data = try JSONEncoder().encode(selection)
            defaults.set(data, forKey: Self.connectionKey)
            vault = selection
            errorMessage = nil
            sync()
        } catch {
            showError(error)
        }
    }

    func disconnect() {
        defaults.removeObject(forKey: Self.connectionKey)
        vault = nil
        errorMessage = nil
    }

    func showError(_ error: any Error) {
        errorMessage = error.localizedDescription
    }

    func sync() {
        guard let vault else { return }
        guard !isSyncing else {
            needsSync = true
            return
        }

        let input = Content(tasks: store.snapshot.tasks, history: store.snapshot.history)
        let base = baselines[vault.path] ?? []
        let today = store.todayTaskDay
        isSyncing = true
        Task {
            let result = await Task.detached(priority: .utility) {
                Self.syncFiles(vault: vault, base: base, input: input, today: today)
            }.value

            if self.vault == vault {
                if let merged = result.tasks {
                    let latest = ObsidianNotes.merge(base: input.tasks, local: store.snapshot.tasks, remote: merged)
                    store.replaceTasks(latest)
                    if baselines[vault.path] != merged {
                        baselines[vault.path] = merged
                        if let data = try? JSONEncoder().encode(baselines) {
                            defaults.set(data, forKey: Self.baselinesKey)
                        }
                    }
                }
                if errorMessage != result.error { errorMessage = result.error }
            }
            isSyncing = false
            if needsSync {
                needsSync = false
                sync()
            }
        }
    }

    private struct Content: Equatable, Sendable {
        let tasks: [FocusTask]
        let history: [FocusSession]
    }

    private struct SyncResult: Sendable {
        var tasks: [FocusTask]?
        var error: String?
    }

    nonisolated private static func syncFiles(
        vault: ObsidianVault,
        base: [FocusTask],
        input: Content,
        today: String
    ) -> SyncResult {
        do {
            return try vault.withFolder { folder in
                var result = SyncResult()
                var errors: [String] = []
                do {
                    result.tasks = try ObsidianNotes.syncTasks(in: folder, base: base, local: input.tasks, today: today)
                } catch {
                    errors.append(error.localizedDescription)
                }
                do {
                    try ObsidianNotes.exportHistory(input.history, in: folder)
                } catch {
                    errors.append(error.localizedDescription)
                }
                if !errors.isEmpty { result.error = errors.joined(separator: "\n") }
                return result
            }
        } catch {
            return SyncResult(error: error.localizedDescription)
        }
    }
}
