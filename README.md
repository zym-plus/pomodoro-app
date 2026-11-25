# Pomodoro

A native SwiftUI focus timer for macOS, iPhone, and iPad. Use it as a standalone timer or connect it to an Obsidian vault.

- Set focus, short-break, and long-break durations and choose which sessions start automatically.
- Plan tasks by date, check today’s completion, and review scheduled tasks and focus activity in Calendar.
- Choose the Glass or Classic appearance and optionally play white noise during focus sessions.

## Build and run

Open `Pomodoro.xcodeproj` in Xcode, select the **Pomodoro** scheme, and choose **My Mac** or an iOS destination. Use Xcode 26 or later with the platform SDK installed. The deployment targets are macOS 14 and iOS 17. Select your own signing team under **Signing & Capabilities** before running on a physical iOS device.

To build for macOS from the command line:

```sh
xcodebuild -project Pomodoro.xcodeproj -scheme Pomodoro -configuration Release -destination 'platform=macOS' -derivedDataPath Build/DerivedData build
```

The app bundle is then at `Build/DerivedData/Build/Products/Release/Pomodoro.app`.

## Plan by date

The Timer always shows tasks scheduled for today. Open **Tasks** to browse another date, and set the planned date when creating or editing a task. Existing tasks from versions without dates are available under **Tasks → Task Date → Undated** and can be scheduled there.

## Connect Obsidian

In Pomodoro, open **Settings → Obsidian → Choose Vault** and select the vault folder. Pomodoro creates a `Pomodoro/` subfolder with two Markdown notes.

- **Tasks.md** syncs checkboxes in both directions. Keep task rows between the two markers in the note. A new checkbox added there defaults to today. To reschedule in Obsidian, edit the task marker’s `date:YYYY-MM-DD` field in Source mode.
- **Focus Log.md** receives completed focus sessions. If the vault is temporarily unavailable, sessions stay in the app and can be written on the next successful sync.

The Obsidian connection is optional. The app stores timer settings and data locally and can run without an account.
