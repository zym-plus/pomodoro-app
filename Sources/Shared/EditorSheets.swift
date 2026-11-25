import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

private struct PanelSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.usesGlassAppearance) private var usesGlassAppearance
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        Group {
#if os(macOS)
            form.frame(width: 440)
#else
            ScrollView {
                form
                    .frame(maxWidth: 460)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .presentationDragIndicator(.visible)
#endif
        }
        .background(AppearanceBackdrop(glassEnabled: usesGlassAppearance).ignoresSafeArea())
        .tint(Theme.accentDark)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.vertical, 6)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                IconButton(symbol: "xmark", title: "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            content
        }
        .padding(24)
    }
}

private struct SheetAction: View {
    let title: String
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 47)
                .background(Theme.action, in: RoundedRectangle(cornerRadius: 14))
                .opacity(disabled ? 0.46 : 1)
        }
        .buttonStyle(SoftButtonStyle())
        .disabled(disabled)
    }
}

struct TaskEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var fieldFocused: Bool
    @State private var title: String
    @State private var plannedDay: String?
    @State private var showsDatePicker = false
    let task: FocusTask?
    let defaultDay: String
    var onSave: (String, String?) -> Void

    init(task: FocusTask?, defaultDay: String, onSave: @escaping (String, String?) -> Void) {
        self.task = task
        self.defaultDay = defaultDay
        self.onSave = onSave
        _title = State(initialValue: task?.title ?? "")
        _plannedDay = State(initialValue: task == nil ? defaultDay : task?.plannedDay)
    }

    private var scheduledDate: Date? { plannedDay.flatMap(TaskDay.date(for:)) }

    var body: some View {
        PanelSheet(title: task == nil ? "New Task" : "Edit Task") {
            TextField("Task name", text: $title, prompt: Text("Enter a task name").foregroundStyle(Theme.subtle))
                .font(.body)
                .foregroundStyle(Theme.ink)
                .textFieldStyle(.plain)
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(fieldFocused ? Theme.accent.opacity(0.55) : Theme.line, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit(save)

            Button {
                showsDatePicker = true
            } label: {
                HStack(spacing: 9) {
                    Label("Planned Date", systemImage: "calendar")
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 8)
                    Text(scheduledDate?.formatted(dashboardFormatStyle.month().day().year()) ?? "Set Date")
                        .foregroundStyle(scheduledDate == nil ? Theme.accentDark : Theme.ink)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                        .accessibilityHidden(true)
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Theme.card.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(SoftButtonStyle())
            .accessibilityLabel("Planned Date")
            .accessibilityValue(scheduledDate?.formatted(dashboardFormatStyle.month().day().year()) ?? "Undated")
            .popover(isPresented: $showsDatePicker, arrowEdge: .top) {
                TaskCalendarPicker(initialDate: scheduledDate ?? TaskDay.date(for: defaultDay) ?? .now) { date in
                    plannedDay = TaskDay.key(for: date)
                    showsDatePicker = false
                }
                .presentationCompactAdaptation(.popover)
            }

            SheetAction(title: task == nil ? "Add" : "Save", disabled: trimmed.isEmpty, action: save)
        }
        .onAppear { fieldFocused = true }
#if os(iOS)
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
#endif
    }

    private var trimmed: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        let newDay = plannedDay != task?.plannedDay ? plannedDay : nil
        onSave(trimmed, newDay)
        dismiss()
    }
}

struct TimerSettingsSheet: View {
    @AppStorage(AppearanceTheme.storageKey) private var appearance: AppearanceTheme = .glass
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var durationFieldWidth: CGFloat = 62
    @State private var draft: TimerSettings
    @ObservedObject private var obsidian: ObsidianSync
    @State private var durations: [TimerMode: String]
    @FocusState private var focusedDuration: TimerMode?
    let hasCurrentSession: Bool
    var onSave: (TimerSettings) -> Void

    private var stacksControls: Bool { dynamicTypeSize >= .xxLarge }

    init(
        settings: TimerSettings,
        hasCurrentSession: Bool,
        obsidian: ObsidianSync,
        onSave: @escaping (TimerSettings) -> Void
    ) {
        _draft = State(initialValue: settings)
        _durations = State(initialValue: Dictionary(uniqueKeysWithValues: TimerMode.allCases.map {
            ($0, String(settings.minutes(for: $0)))
        }))
        self.hasCurrentSession = hasCurrentSession
        self.obsidian = obsidian
        self.onSave = onSave
    }

    private var validatedSettings: TimerSettings? {
        guard let focus = minutes(for: .focus),
              let shortBreak = minutes(for: .shortBreak),
              let longBreak = minutes(for: .longBreak) else { return nil }
        var settings = draft
        settings.focus = focus
        settings.short = shortBreak
        settings.long = longBreak
        return settings
    }

    var body: some View {
        PanelSheet(title: "Settings") {
#if os(macOS)
            ScrollView {
                configuration
            }
            .frame(height: 320)
#else
            configuration
#endif
            SheetAction(title: "Save", disabled: validatedSettings == nil, action: save)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            appearanceSection

            VStack(alignment: .leading, spacing: 9) {
                let headingLayout = stacksControls
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                headingLayout {
                    Text("Durations")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    if !stacksControls { Spacer(minLength: 4) }
                    Text("\(TimerSettings.allowedMinutes.lowerBound)–\(TimerSettings.allowedMinutes.upperBound) minutes")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                durationRow(.focus)
                Divider()
                durationRow(.shortBreak)
                Divider()
                durationRow(.longBreak)
                if validatedSettings == nil {
                    Label("Use a whole number within the range for each duration.", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(Theme.accentDark)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .dashboardCard()

            if hasCurrentSession {
                Text("New durations take effect with the next session.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 13) {
                settingsToggle("Auto-start breaks", isOn: $draft.autoBreak)
                settingsToggle("Auto-start focus sessions", isOn: $draft.autoFocus)
                settingsToggle("Play a sound", isOn: $draft.sound)
            }
            .foregroundStyle(Theme.ink)
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .dashboardCard()

            ObsidianSettings(obsidian: obsidian)
        }
    }

    private func settingsToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var appearanceSection: some View {
        let layout = stacksControls
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))

        return VStack(alignment: .leading, spacing: 8) {
            Text("Appearance")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)

            layout {
                ForEach(AppearanceTheme.allCases) { option in
                    appearanceButton(option)
                }
            }
        }
        .padding(16)
        .dashboardCard()
    }

    private func appearanceButton(_ option: AppearanceTheme) -> some View {
        let isSelected = appearance == option
        let border = RoundedRectangle(cornerRadius: 10)

        return Button {
            appearance = option
        } label: {
            HStack(spacing: 8) {
                appearanceSwatch(option)
                Text(option.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accentDark)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .background(isSelected ? Theme.accentSoft.opacity(0.58) : Theme.surface, in: border)
            .overlay {
                border.strokeBorder(isSelected ? Theme.accent.opacity(0.7) : Theme.line)
                    .allowsHitTesting(false)
            }
            .contentShape(border)
        }
        .buttonStyle(SoftButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityRemoveTraits(isSelected ? [] : .isSelected)
    }

    private func appearanceSwatch(_ option: AppearanceTheme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        return ZStack {
            if option == .glass {
                shape.fill(.linearGradient(
                    colors: [Color(red: 0.92, green: 0.97, blue: 1), Color(red: 0.57, green: 0.77, blue: 0.94)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.3))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.linearGradient(
                                colors: [.white, .white.opacity(0.48)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                    }
                    .frame(width: 18, height: 13)
                    .shadow(color: Color(red: 0.16, green: 0.37, blue: 0.62).opacity(0.16), radius: 1, y: 1)
                shape.strokeBorder(Color(red: 0.16, green: 0.37, blue: 0.62).opacity(0.22))
            } else {
                shape.fill(Color(red: 1, green: 0.96, blue: 0.94))
                Circle().strokeBorder(Theme.tomatoBase.opacity(0.85), lineWidth: 1.4)
                    .frame(width: 13, height: 13)
                shape.strokeBorder(.black.opacity(0.12))
            }
        }
        .frame(width: 27, height: 24)
        .accessibilityHidden(true)
    }

    private func durationRow(_ mode: TimerMode) -> some View {
        let text = Binding(
            get: { durations[mode, default: ""] },
            set: { durations[mode] = $0 }
        )
        let number = Binding(
            get: { minutes(for: mode) ?? draft.minutes(for: mode) },
            set: { durations[mode] = String($0) }
        )
        let isValid = minutes(for: mode) != nil
        let layout = stacksControls
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))

        return layout {
            Text(mode.title)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                TextField("Minutes", text: text, prompt: Text("—"))
#if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
#endif
                    .focused($focusedDuration, equals: mode)
                    .textFieldStyle(.plain)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 8)
                    .frame(width: min(132, durationFieldWidth))
#if os(iOS)
                    .frame(minHeight: 44)
#else
                    .frame(minHeight: 34)
#endif
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(focusedDuration == mode || !isValid ? Theme.accent : Theme.line)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel("\(mode.title) duration in minutes")
                    .accessibilityHint(isValid ? "" : "Enter a whole number from \(TimerSettings.allowedMinutes.lowerBound) to \(TimerSettings.allowedMinutes.upperBound).")
                    .submitLabel(mode == .longBreak ? .done : .next)
                    .onSubmit { advanceFocus(after: mode) }
                Stepper(value: number, in: TimerSettings.allowedMinutes) {
                    Text("Adjust \(mode.title) duration")
                }
                .labelsHidden()
                .accessibilityValue("\(number.wrappedValue) minutes")
            }
        }
    }

    private func advanceFocus(after mode: TimerMode) {
        guard minutes(for: mode) != nil else { return }
        focusedDuration = switch mode {
        case .focus: .shortBreak
        case .shortBreak: .longBreak
        case .longBreak: nil
        }
    }

    private func minutes(for mode: TimerMode) -> Int? {
        let text = durations[mode, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        guard let minutes = Int(normalized), TimerSettings.allowedMinutes.contains(minutes) else { return nil }
        return minutes
    }

    private func save() {
        guard let settings = validatedSettings else { return }
        onSave(settings)
        dismiss()
    }
}

private struct ObsidianSettings: View {
    @ObservedObject var obsidian: ObsidianSync
    @State private var choosingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Obsidian")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)

            if let vault = obsidian.vault {
                Label(URL(fileURLWithPath: vault.path).lastPathComponent + " / Pomodoro", systemImage: "folder")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .help(vault.path)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Sync Now", action: obsidian.sync)
                    Button("Disconnect", action: obsidian.disconnect)
                }
                .buttonStyle(.bordered)
                .disabled(obsidian.isSyncing)
            } else {
                Text("Sync tasks and save focus sessions in your vault.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Choose Vault…") { choosingFolder = true }
                    .buttonStyle(.bordered)
            }

            if let error = obsidian.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.accentDark)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .dashboardCard()
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let folder): obsidian.connect(folder)
            case .failure(let error): obsidian.showError(error)
            }
        }
    }
}

struct TimerRemindersSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
#if os(iOS)
    @Environment(\.openURL) private var openURL
#endif
    @ObservedObject var reminders: TimerReminders
    @State var sound: Bool
    @State private var requestingAuthorization = false
    var onSoundChange: (Bool) -> Void

    var body: some View {
        PanelSheet(title: "Timer Alerts") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Play a sound", isOn: $sound)
                    .toggleStyle(.switch)
                    .onChange(of: sound) { _, value in onSoundChange(value) }
                Divider()
                let statusLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                statusLayout {
                    Text("Notifications")
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
                    Text(reminders.authorized ? "On" : "Off")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
                .accessibilityElement(children: .combine)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.ink)
            .padding(16)
            .dashboardCard()

            if let message = reminders.errorMessage {
                Label(message, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.accentDark)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if reminders.status == .notDetermined {
                SheetAction(title: requestingAuthorization ? "Requesting…" : "Enable Notifications", disabled: requestingAuthorization) {
                    requestingAuthorization = true
                    Task {
                        await reminders.requestAuthorization()
                        requestingAuthorization = false
                    }
                }
            }
#if os(iOS)
            if reminders.status == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                SheetAction(title: "Open Settings") { openURL(url) }
            }
#endif
        }
#if os(iOS)
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
#endif
    }

    private var description: String {
        switch reminders.status {
        case .denied:
            "Allow Pomodoro to send notifications in your device’s settings."
        default:
            "Get an alert when the timer ends, even while using another app."
        }
    }
}
