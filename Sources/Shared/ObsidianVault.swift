import Foundation

enum ObsidianVaultError: LocalizedError {
    case unavailable
    case invalidVault
    case invalidNote(String)
    case changedDuringSync(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The Obsidian vault is unavailable. Check its location or choose it again."
        case .invalidVault: "Choose the root folder of an Obsidian vault."
        case .invalidNote(let name): "\(name) has an invalid format or location. Check the note in Obsidian."
        case .changedDuringSync(let name): "\(name) changed during sync. Pomodoro will retry."
        }
    }
}

struct ObsidianVault: Codable, Equatable, Sendable {
    let path: String
    var bookmark: Data?

    init(folder: URL) throws {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        path = folder.standardizedFileURL.path
#if os(iOS)
        guard scoped else { throw ObsidianVaultError.unavailable }
        bookmark = try folder.bookmarkData()
#else
        try Self.validate(folder)
#endif
    }

    func withFolder<T>(_ operation: (URL) throws -> T) throws -> T {
#if os(iOS)
        guard let bookmark else { throw ObsidianVaultError.unavailable }
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        guard folder.startAccessingSecurityScopedResource() else { throw ObsidianVaultError.unavailable }
        defer { folder.stopAccessingSecurityScopedResource() }
#else
        let folder = URL(fileURLWithPath: path, isDirectory: true)
#endif
        try Self.validate(folder)
        let directory = folder.appendingPathComponent("Pomodoro", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // Another sync may have created the directory already.
        }
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw ObsidianVaultError.invalidNote("Pomodoro")
        }
        return try operation(directory)
    }

    private static func validate(_ folder: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ObsidianVaultError.unavailable }
#if os(macOS)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(".obsidian").path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ObsidianVaultError.invalidVault }
#endif
    }
}

enum ObsidianNotes {
    static let taskFile = "Tasks.md"
    static let logFile = "Focus Log.md"
    private static let tasksStart = "<!-- pomodoro:tasks:start -->"
    private static let tasksEnd = "<!-- pomodoro:tasks:end -->"
    private static let taskTemplate = """
    # Tasks

    Edit the checkboxes between the two markers to sync with Pomodoro. Change a task's date in Pomodoro or edit its `date:YYYY-MM-DD` field in Obsidian's source mode.

    \(tasksStart)
    \(tasksEnd)

    """
    private static let logHeading = "# Focus Log"
    private static let logMarker = "<!-- pomodoro:focus-log -->"
    private static let logTemplate = "\(logHeading)\n\n\(logMarker)\n\n"

    private struct TaskRow {
        let task: FocusTask
        let leadingComment: Substring
        let prefix: String
        let suffix: String
        let hasID: Bool
        let markerDay: String?
    }

    private struct Fence {
        let character: Character
        let length: Int

        init?(_ line: Substring) {
            let trimmed = line.drop(while: { $0 == " " })
            guard line.count - trimmed.count <= 3, let first = trimmed.first,
                  first == "\u{0060}" || first == "~" else { return nil }
            let length = trimmed.prefix(while: { $0 == first }).count
            guard length >= 3 else { return nil }
            self.character = first
            self.length = length
        }

        func closes(on line: Substring) -> Bool {
            let trimmed = line.drop(while: { $0 == " " })
            return line.count - trimmed.count <= 3
                && trimmed.prefix(while: { $0 == character }).count >= length
                && trimmed.drop(while: { $0 == character }).allSatisfy(\.isWhitespace)
        }
    }

    private struct MarkdownVisibility {
        private var fence: Fence?
        private var commentEnd: String?

        var blockIsOpen: Bool { fence != nil || commentEnd != nil }

        mutating func visibleText(of line: Substring) -> Substring? {
            if let activeFence = fence {
                if activeFence.closes(on: line) { fence = nil }
                return nil
            }
            if let commentEnd {
                guard let closing = line.range(of: commentEnd) else { return nil }
                self.commentEnd = nil
                return commentEnd == "%%" ? line[closing.upperBound...] : nil
            }
            if let newFence = Fence(line) {
                fence = newFence
                return nil
            }

            let trimmed = line.drop(while: \.isWhitespace)
            if trimmed.hasPrefix("%%") {
                let rest = trimmed.dropFirst(2)
                if let closing = rest.range(of: "%%") { return rest[closing.upperBound...] }
                commentEnd = "%%"
                return nil
            }
            if trimmed.hasPrefix("<!--"), !trimmed.dropFirst(4).contains("-->") {
                commentEnd = "-->"
                return nil
            }
            return line
        }
    }

    private static func markdownBody(_ lines: [Substring], note: String) throws -> ArraySlice<Substring> {
        guard lines.first == "---" else { return lines[...] }
        guard let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else {
            throw ObsidianVaultError.invalidNote(note)
        }
        return lines[(end + 1)...]
    }

    static func syncTasks(
        in folder: URL,
        base: [FocusTask],
        local: [FocusTask],
        today: String = TaskDay.key(for: Date())
    ) throws -> [FocusTask] {
        let taskPattern = /^([ \t]*(?:[-*+]|[0-9]{1,9}[.)])[ \t]+)\[([ xX])\][ \t]+(.+)$/
        let taskID = /[ \t]+<!-- pomodoro-task:([0-9A-Fa-f-]{36})(?=[ \t]|-->)(.*?)-->/
        let dateMetadata = /[ \t]+(?:✅|❌|📅|⏳|🛫|➕)[ \t]*[0-9]{4}-[0-9]{2}-[0-9]{2}(?=[ \t]|$)/
        return try updateNote(folder.appendingPathComponent(taskFile)) { original in
            let document = original ?? taskTemplate
            let lines = document.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            let body = try markdownBody(lines, note: taskFile)
            let starts = body.indices.filter { body[$0] == tasksStart }
            let ends = body.indices.filter { body[$0] == tasksEnd }
            guard starts.count == 1, ends.count == 1, starts[0] < ends[0] else {
                throw ObsidianVaultError.invalidNote(taskFile)
            }
            let section = (starts[0] + 1)..<ends[0]
            let newline = String(document[lines[starts[0]].endIndex])
            let knownIDs = Set(base.map(\.id) + local.map(\.id))
            // A missing date in a legacy row is not a change to the last synced date.
            var knownDays: [UUID: String] = [:]
            for task in local + base {
                if let day = task.plannedDay, TaskDay.date(for: day) != nil {
                    knownDays[task.id] = day
                }
            }
            var rows: [Int: TaskRow] = [:]
            var ids = Set<UUID>()
            var preservedIDs = Set<UUID>()
            var visibility = MarkdownVisibility()

            for row in body.indices {
                let line = body[row]
                let visible = visibility.visibleText(of: line)
                if visible == nil && (row == starts[0] || row == ends[0]) {
                    throw ObsidianVaultError.invalidNote(taskFile)
                }
                guard section.contains(row), let visible else {
                    if let hidden = line.matches(of: taskID).last,
                       let id = UUID(uuidString: String(hidden.1)) {
                        preservedIDs.insert(id)
                    }
                    continue
                }

                let marker = visible.matches(of: taskID).last { UUID(uuidString: String($0.1)) != nil }
                let existingID = marker.flatMap { UUID(uuidString: String($0.1)) }
                var content = String(visible)
                var suffix = ""
                if let marker {
                    content = String(visible[..<marker.range.lowerBound])
                    let tail = visible[marker.range.upperBound...]
                    var titleStart = tail.startIndex
                    for metadata in tail.matches(of: dateMetadata) {
                        content += tail[titleStart..<metadata.range.lowerBound]
                        suffix += metadata.0
                        titleStart = metadata.range.upperBound
                    }
                    content += tail[titleStart...]
                }
                guard let match = content.wholeMatch(of: taskPattern),
                      existingID != nil || !match.1.hasPrefix("    ") && !match.1.hasPrefix("\t"),
                      !match.3.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    if let existingID { preservedIDs.insert(existingID) }
                    continue
                }
                let id = existingID ?? UUID()
                let fields = marker?.2.trimmingCharacters(in: .whitespaces) ?? ""
                let explicitDay: String?
                if fields.isEmpty {
                    explicitDay = nil
                } else {
                    let day = String(fields.dropFirst("date:".count))
                    guard fields.hasPrefix("date:"), TaskDay.date(for: day) != nil else {
                        throw ObsidianVaultError.invalidNote(taskFile)
                    }
                    explicitDay = day
                }
                guard ids.insert(id).inserted else { throw ObsidianVaultError.invalidNote(taskFile) }
                rows[row] = TaskRow(
                    task: FocusTask(
                        id: id,
                        title: match.3.trimmingCharacters(in: .whitespacesAndNewlines),
                        done: match.2 != " ",
                        plannedDay: explicitDay ?? (existingID == nil ? today : knownDays[id])
                    ),
                    leadingComment: line[..<visible.startIndex],
                    prefix: String(match.1),
                    suffix: suffix,
                    hasID: existingID != nil,
                    markerDay: explicitDay
                )
            }

            // A present but unreadable task is different from a deleted checkbox.
            if !preservedIDs.subtracting(ids).isDisjoint(with: knownIDs) {
                throw ObsidianVaultError.invalidNote(taskFile)
            }

            let remote = original == nil ? base : section.compactMap { rows[$0]?.task }
            let merged = merge(base: base, local: local.map(singleLineTask), remote: remote)
            let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
            let start = document.index(after: lines[starts[0]].endIndex)
            let end = lines[ends[0]].startIndex
            var replacement = ""
            for row in section {
                let line = lines[row]
                if let entry = rows[row] {
                    if let updated = byID[entry.task.id] {
                        let canReuseLine = updated == entry.task && entry.hasID && updated.plannedDay == entry.markerDay
                        replacement += canReuseLine
                            ? String(line)
                            : String(entry.leadingComment) + taskLine(updated, prefix: entry.prefix, suffix: entry.suffix)
                    } else {
                        guard !entry.leadingComment.isEmpty else { continue }
                        replacement += entry.leadingComment
                    }
                } else {
                    replacement += line
                }
                replacement.append(document[line.endIndex])
            }
            for task in merged where !ids.contains(task.id) {
                replacement += taskLine(task) + newline
            }
            guard original == nil || !replacement.utf8.elementsEqual(document[start..<end].utf8) else {
                return (nil, merged)
            }
            return (String(document[..<start]) + replacement + document[end...], merged)
        }
    }

    // Reconcile each field against the last shared version. A deletion wins over an edit to the same task.
    static func merge(base: [FocusTask], local: [FocusTask], remote: [FocusTask]) -> [FocusTask] {
        let baseline = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let localTasks = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let remoteTasks = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        let orderedIDs = remote.map(\.id) + local.map(\.id).filter { remoteTasks[$0] == nil }
        return orderedIDs.compactMap { id in
            let before = baseline[id]
            let here = localTasks[id]
            let there = remoteTasks[id]
            if here == before { return there }
            if there == before { return here }
            guard var here, let there else { return nil }
            if here.title == before?.title { here.title = there.title }
            if here.done == before?.done { here.done = there.done }
            if here.plannedDay == before?.plannedDay { here.plannedDay = there.plannedDay }
            return here
        }
    }

    static func exportHistory(_ sessions: [FocusSession], in folder: URL) throws {
        let sessionID = /<!-- pomodoro-session:([0-9A-Fa-f-]{36}) -->[ \t]*$/
        try updateNote(folder.appendingPathComponent(logFile)) { original in
            let text = original ?? logTemplate
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            let body = try markdownBody(lines, note: logFile).filter { !$0.allSatisfy(\.isWhitespace) }
            guard let heading = body.first, heading == logHeading else {
                throw ObsidianVaultError.invalidNote(logFile)
            }
            var visibility = MarkdownVisibility()
            var known = Set(body.compactMap { line -> UUID? in
                guard let visible = visibility.visibleText(of: line), visible.hasPrefix("- "),
                      let marker = visible.firstMatch(of: sessionID) else { return nil }
                return UUID(uuidString: String(marker.1))
            })
            let isManagedLog = body.dropFirst().first.map { $0 == logMarker } ?? false
            guard isManagedLog || body.count == 1 || !known.isEmpty else {
                throw ObsidianVaultError.invalidNote(logFile)
            }
            let lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX")
            date.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            let entries = sessions.filter { known.insert($0.id).inserted }.map { session in
                let unit = session.minutes == 1 ? "minute" : "minutes"
                return "- \(date.string(from: session.at)) · \(session.minutes) \(unit) <!-- pomodoro-session:\(session.id) -->\(lineEnding)"
            }
            guard original == nil || !entries.isEmpty else { return (nil, ()) }
            guard !visibility.blockIsOpen else { throw ObsidianVaultError.invalidNote(logFile) }
            var content = text
            if !isManagedLog {
                content.insert(contentsOf: lineEnding + lineEnding + logMarker, at: heading.endIndex)
            }
            let separator = content.last?.isNewline == true ? "" : lineEnding
            return (content + separator + entries.joined(), ())
        }
    }

    private static func singleLineTask(_ task: FocusTask) -> FocusTask {
        var normalized = task
        normalized.title = task.title.components(separatedBy: .newlines).joined(separator: " ")
        return normalized
    }

    private static func taskLine(_ task: FocusTask, prefix: String = "- ", suffix: String = "") -> String {
        let dayField = task.plannedDay.map { " date:\($0)" } ?? ""
        return "\(prefix)[\(task.done ? "x" : " ")] \(task.title) <!-- pomodoro-task:\(task.id)\(dayField) -->\(suffix)"
    }

    private static func updateNote<T>(
        _ url: URL,
        transform: (String?) throws -> (replacement: String?, result: T)
    ) throws -> T {
        try rejectSymlink(url)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result {
                let originalData = try readNote(coordinatedURL)
                let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
                let hasBOM = originalData?.starts(with: bom) ?? false
                let original = try originalData.map { data in
                    guard let text = String(bytes: data.dropFirst(hasBOM ? bom.count : 0), encoding: .utf8) else {
                        throw ObsidianVaultError.invalidNote(url.lastPathComponent)
                    }
                    return text
                }
                let change = try transform(original)
                if let replacement = change.replacement {
                    guard try readNote(coordinatedURL) == originalData else {
                        throw ObsidianVaultError.changedDuringSync(url.lastPathComponent)
                    }
                    var data = Data(hasBOM ? bom : [])
                    data.append(contentsOf: replacement.utf8)
                    try data.write(to: coordinatedURL, options: .atomic)
                }
                return change.result
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ObsidianVaultError.unavailable }
        return try result.get()
    }

    private static func rejectSymlink(_ url: URL) throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw ObsidianVaultError.invalidNote(url.lastPathComponent)
        }
    }

    private static func readNote(_ url: URL) throws -> Data? {
        try rejectSymlink(url)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ObsidianVaultError.invalidNote(url.lastPathComponent)
            }
            return try Data(contentsOf: url)
        } catch let error as CocoaError where [.fileReadNoSuchFile, .fileNoSuchFile].contains(error.code) {
            return nil
        }
    }
}
