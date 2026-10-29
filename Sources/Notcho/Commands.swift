import AppKit
import EventKit

// MARK: - notch:// links
// Adding is open to any link. Changing a task (complete, remind, move) needs the secret key below,
// which only programs that can read this app's saved settings (the `notch` command, the MCP server) know.

enum NotchCommand: Equatable {
    case add(title: String, remind: Date?, limit: Int?)
    case note(String)
    case complete(UUID)
    case remind(UUID, Date?)        // nil clears the reminder
    case tomorrow(UUID)
    case edit(op: String, fields: [String: String])   // Planner changes from agents: projects, task details, goals, time blocks

    var needsKey: Bool {
        switch self { case .add, .note: false; case .complete, .remind, .tomorrow, .edit: true }
    }

    /// Random key created on first use and kept in the app's settings.
    static var linkKey: String {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication) // the app and the command are separate processes
        if let k = UserDefaults.standard.string(forKey: "link.key") { return k }
        let k = UUID().uuidString + UUID().uuidString
        UserDefaults.standard.set(k, forKey: "link.key")
        return k
    }

    /// notch://add?title=…&remind=5pm&limit=25 · notch://note?text=… · notch://done|remind|tomorrow?id=…&key=…
    static func parse(_ url: URL, now: Date = .now, key: String = NotchCommand.linkKey) -> NotchCommand? {
        guard ["notch", "notcho"].contains(url.scheme ?? ""), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let q = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        func clean(_ s: String?) -> String? {
            let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : String(t.prefix(1000))
        }
        let id = q["id"].flatMap(UUID.init(uuidString:))
        let keyed = q["key"] == key && id != nil
        switch url.host {
        case "add":
            guard let title = clean(q["title"]) else { return nil }
            return .add(title: title, remind: q["remind"].flatMap { parseTime($0, now: now) }, limit: q["limit"].flatMap(Int.init))
        case "note":
            return clean(q["text"]).map { .note($0) }
        case "done" where keyed:
            return .complete(id!)
        case "remind" where keyed:
            if q["at"] == "none" { return .remind(id!, nil) }
            guard let at = q["at"].flatMap({ parseTime($0, now: now) }) else { return nil }
            return .remind(id!, at)
        case "tomorrow" where keyed:
            return .tomorrow(id!)
        case "edit" where q["key"] == key:
            guard let op = q["op"] else { return nil }
            var fields = q; fields["op"] = nil; fields["key"] = nil
            return .edit(op: op, fields: fields.mapValues { String($0.prefix(20_000)) })
        default:
            return nil
        }
    }

    func url(key: String = NotchCommand.linkKey) -> URL {
        var c = URLComponents()
        c.scheme = "notcho"
        let iso = ISO8601DateFormatter()
        func keyed(_ host: String, _ id: UUID, _ extra: [URLQueryItem] = []) {
            c.host = host
            c.queryItems = [URLQueryItem(name: "id", value: id.uuidString), URLQueryItem(name: "key", value: key)] + extra
        }
        switch self {
        case let .add(title, remind, limit):
            c.host = "add"
            c.queryItems = [URLQueryItem(name: "title", value: title)]
                + (remind.map { [URLQueryItem(name: "remind", value: iso.string(from: $0))] } ?? [])
                + (limit.map { [URLQueryItem(name: "limit", value: String($0))] } ?? [])
        case let .note(text):
            c.host = "note"
            c.queryItems = [URLQueryItem(name: "text", value: text)]
        case let .complete(id): keyed("done", id)
        case let .remind(id, at): keyed("remind", id, [URLQueryItem(name: "at", value: at.map { iso.string(from: $0) } ?? "none")])
        case let .tomorrow(id): keyed("tomorrow", id)
        case let .edit(op, fields):
            c.host = "edit"
            c.queryItems = [URLQueryItem(name: "op", value: op), URLQueryItem(name: "key", value: key)]
                + fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return c.url!
    }
}

/// Short id shown next to tasks in `notch today` (first 6 characters of the UUID).
extension TaskItem {
    var shortID: String { String(id.uuidString.prefix(6)).lowercased() }
}

/// Finds a task by short id, full id, exact title, or a unique part of the title (undone tasks first).
func findTask(_ query: String, in tasks: [TaskItem]) -> Result<TaskItem, CLIError> {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return .failure(CLIError("say which task (id or title)")) }
    if let t = tasks.first(where: { $0.id.uuidString.lowercased() == q || ($0.shortID == q) }) { return .success(t) }
    let open = tasks.filter { !$0.done }
    if let t = open.first(where: { $0.title.lowercased() == q }) { return .success(t) }
    let partial = open.filter { $0.title.lowercased().contains(q) }
    switch partial.count {
    case 1: return .success(partial[0])
    case 0: return .failure(CLIError("no open task matches \"\(query)\""))
    default: return .failure(CLIError("\"\(query)\" matches several tasks: " + partial.map { "\($0.title) [\($0.shortID)]" }.joined(separator: ", ")))
    }
}

struct CLIError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// "30m", "in 2h", "1h30m" (from now) · "17:00", "5pm", "5:30pm" (next time it comes round) · ISO 8601.
func parseTime(_ input: String, now: Date = .now, calendar cal: Calendar = .current) -> Date? {
    let t = input.lowercased().replacingOccurrences(of: " ", with: "")
    let rel = t.hasPrefix("in") ? String(t.dropFirst(2)) : t
    if let m = rel.wholeMatch(of: #/(?:(\d+)h)?(?:(\d+)m(?:in)?)?/#), m.1 != nil || m.2 != nil {
        let seconds = (Int(m.1 ?? "0")! * 60 + Int(m.2 ?? "0")!) * 60
        return seconds > 0 ? now.addingTimeInterval(TimeInterval(seconds)) : nil
    }
    if let m = t.wholeMatch(of: #/(\d{1,2})(?::(\d{2}))?(am|pm)?/#) {
        var hour = Int(m.1)!
        let minute = Int(m.2 ?? "0")!
        if let ampm = m.3 {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (ampm == "pm" ? 12 : 0)
        }
        guard hour < 24, minute < 60, let today = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        return today > now ? today : cal.date(byAdding: .day, value: 1, to: today)
    }
    return ISO8601DateFormatter().date(from: input)
}

// MARK: - Actions shared by the `notch` command and the MCP server

/// Every change goes to the app as a link (the app owns all writes), then is confirmed by re-reading saved data.
enum Actions {
    static func add(_ title: String, remind: String?, limit: Int?) -> Result<String, CLIError> {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .failure(CLIError("a task needs a title")) }
        var date: Date?
        if let remind {
            guard let d = parseTime(remind) else { return .failure(CLIError("can't read the time \"\(remind)\" (try 5pm, 17:00, 30m)")) }
            date = d
        }
        let before = Set(fresh().tasks.map(\.id))
        let ok = sendAndConfirm(.add(title: title, remind: date, limit: limit)) { s in s.tasks.contains { !before.contains($0.id) && $0.title == title } }
        guard ok else { return .failure(CLIError("the app didn't confirm the new task — is it running?")) }
        return .success("Added: \(title)" + (date.map { " · reminder \(reminderLabel($0))" } ?? "") + (limit.map { " · \($0)m" } ?? ""))
    }

    static func note(_ text: String) -> Result<String, CLIError> {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(CLIError("a note needs text")) }
        let ok = sendAndConfirm(.note(text)) { $0.notes.contains(text) }
        return ok ? .success("Added to Notepad.") : .failure(CLIError("the app didn't confirm the note — is it running?"))
    }

    static func complete(_ query: String) -> Result<String, CLIError> {
        findTask(query, in: fresh().tasks).flatMap { t in
            guard !t.done else { return .success("Already done: \(t.title)") }
            let ok = sendAndConfirm(.complete(t.id)) { $0.tasks.first { $0.id == t.id }?.done == true }
            return ok ? .success("Done: \(t.title)") : .failure(CLIError("the app didn't confirm — is it running?"))
        }
    }

    /// `at` is a time ("5pm", "30m", …) or "none" to clear.
    static func remind(_ query: String, at: String) -> Result<String, CLIError> {
        let clear = at.lowercased() == "none"
        guard clear || parseTime(at) != nil else { return .failure(CLIError("can't read the time \"\(at)\" (try 5pm, 17:00, 30m)")) }
        let date = clear ? nil : parseTime(at)
        return findTask(query, in: fresh().tasks).flatMap { t in
            let ok = sendAndConfirm(.remind(t.id, date)) { s in
                let r = s.tasks.first { $0.id == t.id }?.reminder
                return clear ? r == nil : r != nil && abs(r!.timeIntervalSince(date!)) < 1
            }
            guard ok else { return .failure(CLIError("the app didn't confirm — is it running?")) }
            return .success(clear ? "Reminder removed: \(t.title)" : "Reminder set: \(t.title) · \(reminderLabel(date!))")
        }
    }

    static func tomorrow(_ query: String) -> Result<String, CLIError> {
        findTask(query, in: fresh().tasks).flatMap { t in
            let ok = sendAndConfirm(.tomorrow(t.id)) { s in
                guard let d = s.tasks.first(where: { $0.id == t.id })?.day else { return false }
                return d > s.today
            }
            return ok ? .success("Moved to tomorrow: \(t.title)") : .failure(CLIError("the app didn't confirm — is it running?"))
        }
    }

    static func today() -> String { CLI.today(fresh()) }
    static func notes() -> String { let n = fresh().notes; return n.isEmpty ? "(Notepad is empty)" : n }

    /// A Store read from the latest saved data (another process — the app — writes it).
    static func fresh() -> Store { Store() } // reads store.json straight from disk

    /// Hands the link to the app (launching it if needed), then waits up to ~3 s for the change to be saved.
    static func sendAndConfirm(_ command: NotchCommand, until check: (Store) -> Bool) -> Bool {
        guard NSWorkspace.shared.open(command.url()) else { return false }
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.1)
            if check(fresh()) { return true }
        }
        return false
    }
}

// MARK: - `notcho` command (same binary, run as `Notcho cli …`)

enum CLI {
    static let help = """
    notcho — send to and read from your notch

      notcho add "Call dad" [--remind 5pm|17:00|30m] [--limit 25]
      notcho note "idea for the landing page"
      notcho done <id or title>
      notcho remind <id or title> --at 5pm        (--at none clears it)
      notcho tomorrow <id or title>
      notcho today        today's tasks (with ids), reminders, events, focus timer
      notcho notes        the Notepad text
      notcho mcp          run as an MCP server (for Claude / Codex)
    """

    static func run(_ args: [String]) -> Int32 {
        var rest = Array(args.dropFirst())
        let result: Result<String, CLIError>
        switch args.first {
        case "add":
            let remind = take("--remind", from: &rest), limit = take("--limit", from: &rest)
            if let limit, Int(limit) == nil { return finish(.failure(CLIError("--limit needs minutes, e.g. 25"))) }
            result = Actions.add(rest.joined(separator: " "), remind: remind, limit: limit.flatMap(Int.init))
        case "note": result = Actions.note(rest.joined(separator: " "))
        case "done": result = Actions.complete(rest.joined(separator: " "))
        case "tomorrow": result = Actions.tomorrow(rest.joined(separator: " "))
        case "remind":
            guard let at = take("--at", from: &rest) else { return finish(.failure(CLIError("remind needs --at <time> (or --at none)"))) }
            result = Actions.remind(rest.joined(separator: " "), at: at)
        case "today": result = .success(Actions.today())
        case "notes": result = .success(Actions.notes())
        case "mcp": MCP.run(); return 0
        case nil, "help", "-h", "--help": result = .success(help)
        default: result = .failure(CLIError("unknown command \"\(args[0])\"\n\n\(help)"))
        }
        return finish(result)
    }

    static func finish(_ result: Result<String, CLIError>) -> Int32 {
        switch result {
        case let .success(text): print(text); return 0
        case let .failure(e): FileHandle.standardError.write(Data("notch: \(e.message)\n".utf8)); return 1
        }
    }

    /// Removes `--flag value` from the arguments and returns the value.
    static func take(_ flag: String, from args: inout [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return value
    }

    /// Plain-text summary for people and agents. Task ids in [brackets] work with done/remind/tomorrow.
    static func today(_ store: Store, now: Date = .now) -> String {
        var out = ["Today — \(now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))", ""]
        let todo = store.todo
        out.append("To do (\(todo.count))")
        out += todo.isEmpty ? ["  (nothing)"] : todo.map { t in
            PlannerActions.line(t, store) + (t.reminder.map { " · reminder \(reminderLabel($0))" } ?? "")
        }
        let done = store.completed.filter { ($0.completedAt ?? .distantPast) >= store.today }
        if !done.isEmpty { out += ["", "Completed today (\(done.count))"] + done.map { "  ✓ \($0.title) [\($0.shortID)]" } }
        if !store.stale.isEmpty { out += ["", "Unfinished from earlier days (\(store.stale.count))"] + store.stale.map { "  · \($0.title) [\($0.shortID)]" } }
        let upcoming = store.upcoming
        if !upcoming.isEmpty { out += ["", "Coming up (\(upcoming.count))"] + upcoming.prefix(25).map { PlannerActions.line($0, store) } }
        let someday = store.someday
        if !someday.isEmpty { out += ["", "Someday (\(someday.count))"] + someday.prefix(10).map { "  · \($0.title) [\($0.shortID)]" } }
        let reminders = store.reminders
        if !reminders.isEmpty { out += ["", "Reminders"] + reminders.map { "  \(reminderLabel($0.reminder!)) — \($0.title) [\($0.shortID)]" } }
        let events = Store.savedEvents()
        out += ["", "Events"] + (events.isEmpty ? ["  (none today, or calendar not connected)"] : events)
        out += ["", "Focus: " + focusLine(store, now: now)]
        let words = wordCount(store.notes)
        out.append("Notepad: \(words) word\(words == 1 ? "" : "s") (notch notes to read it)")
        return out.joined(separator: "\n")
    }

    static func focusLine(_ s: Store, now: Date) -> String {
        let task = s.focusTask.map { " on \"\($0.title)\"" } ?? ""
        let time = clock(s.display(at: now)) + (s.isStopwatch ? " elapsed" : " left")
        switch s.focusState {
        case .ready: return "not running (\(s.isStopwatch ? "stopwatch" : "\(s.focusMinutes) min countdown"))"
        case .running: return "running · \(time)\(task)"
        case .paused: return "paused · \(time)\(task)"
        case .finished: return "time's up\(task)"
        }
    }
}

// MARK: - Store additions used by links and the command

extension Store {
    func addTask(_ title: String, reminder: Date? = nil, timeLimit: Int? = nil) {
        var item = TaskItem(title: title)
        item.timeLimit = timeLimit.map { max(1, min($0, 240)) }
        tasks.append(item)
        if let reminder { remindNow(item.id, at: reminder) }
    }

    /// Saves the reminder immediately; the notification is (re)scheduled once permission is confirmed,
    /// so a slow or pending permission prompt never loses or delays the change.
    func remindNow(_ id: UUID, at date: Date) {
        setReminder(id, at: date)
        ReminderService.shared.requestAccess { [weak self] ok in
            guard let self else { return }
            notificationsOn = ok
            if ok, let task = tasks.first(where: { $0.id == id }) { ReminderService.shared.sync(task) }
        }
    }

    func appendNote(_ text: String) {
        notes = notes.isEmpty ? text : notes + (notes.hasSuffix("\n") ? "" : "\n") + text
    }

    func apply(_ command: NotchCommand) {
        switch command {
        case let .add(title, remind, limit): addTask(title, reminder: remind, timeLimit: limit)
        case let .note(text): appendNote(text)
        case let .complete(id): if tasks.first(where: { $0.id == id })?.done == false { toggle(id) }
        case let .remind(id, at):
            if let at { remindNow(id, at: at) } else { setReminder(id, at: nil) }
        case let .tomorrow(id): moveToTomorrow(id)
        case let .edit(op, fields): applyEdit(op, fields)
        }
    }

    /// Agent edits. Ids are chosen by the caller so it can confirm the result; dates arrive already resolved.
    func applyEdit(_ op: String, _ f: [String: String]) {
        let id = f["id"].flatMap(UUID.init(uuidString:))
        switch op {
        case "project.create":
            guard let id, let name = f["name"], !projects.contains(where: { $0.id == id }) else { return }
            let colors = ["sage", "lavender", "olive", "blue", "rose", "sand"]
            projects.append(Project(id: id, name: name, color: f["color"].flatMap { colors.contains($0) ? $0 : nil } ?? colors[projects.count % colors.count]))
        case "project.update":
            guard let id else { return }
            if let name = f["name"] { renameProject(id, to: name) }
            if let c = f["color"], ["sage", "lavender", "olive", "blue", "rose", "sand"].contains(c), let i = projects.firstIndex(where: { $0.id == id }) { projects[i].color = c }
        case "task.add":
            guard let id, let title = f["title"], !tasks.contains(where: { $0.id == id }) else { return }
            var t = TaskItem(id: id, title: title)
            Self.patch(&t, f)
            tasks.append(t)
            if let r = f["remind"].flatMap({ ISO8601DateFormatter().date(from: $0) }) { remindNow(id, at: r) }
        case "task.update":
            guard let id else { return }
            update(id) { Self.patch(&$0, f) }
            // a new estimate resizes the task's time block to match
            if f["estimate"] != nil, let t = tasks.first(where: { $0.id == id }), t.blockID != nil, let st = t.startTime, let m = t.timeLimit {
                Timebox.shared.place(id, at: st, minutes: m)
            }
            if let r = f["remind"] { if r == "none" { setReminder(id, at: nil) } else if let d = ISO8601DateFormatter().date(from: r) { remindNow(id, at: d) } }
        case "goal.add":
            guard let id, let title = f["title"], !objectives.contains(where: { $0.id == id }) else { return }
            objectives.append(Objective(id: id, title: title, week: f["week"] ?? thisWeek))
        case "block":
            guard let id, let start = f["start"].flatMap({ ISO8601DateFormatter().date(from: $0) }) else { return }
            Timebox.shared.place(id, at: start, minutes: f["minutes"].flatMap(Int.init))
        case "unblock":
            if let id { Timebox.shared.remove(id) }
        case "task.delete":
            guard let id, let t = tasks.first(where: { $0.id == id }) else { return }
            if t.blockID != nil { Timebox.shared.remove(id) }
            delete(id)
        default: break
        }
    }

    /// Applies text fields to a task: title, notes, notes_append, project/goal (id or "none"),
    /// due (YYYY-MM-DD or "none"), day (YYYY-MM-DD or "someday"), estimate (minutes or "none").
    static func patch(_ t: inout TaskItem, _ f: [String: String]) {
        if let v = f["title"], !v.isEmpty { t.title = v }
        if let v = f["notes"] { t.notes = v.isEmpty ? nil : v }
        if let v = f["notes_append"], !v.isEmpty { t.notes = (t.notes.map { $0 + "\n\n" } ?? "") + v }
        if let v = f["project"] { t.projectID = UUID(uuidString: v) }
        if let v = f["goal"] { t.objectiveID = UUID(uuidString: v) }
        if let v = f["due"] { t.due = date(fromDayKey: v) }
        if let v = f["day"] {
            if v == "someday" { t.someday = true; t.day = nil } else if let d = date(fromDayKey: v) { t.someday = nil; t.day = d; t.dismissedAt = nil }
        }
        if let v = f["estimate"] { t.timeLimit = Int(v).map { max(1, min($0, 600)) } }
        let lines = { (k: String) in f[k].map { $0.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? [] }
        var subs = t.subtasks ?? []
        func index(_ q: String) -> Int? {
            if let n = Int(q), subs.indices.contains(n - 1) { return n - 1 }
            let q = q.lowercased()
            return subs.firstIndex { $0.title.lowercased() == q } ?? subs.firstIndex { $0.title.lowercased().contains(q) }
        }
        for q in lines("sub_check") { if let i = index(q) { subs[i].done = true } }
        for q in lines("sub_uncheck") { if let i = index(q) { subs[i].done = false } }
        let gone = Set(lines("sub_remove").compactMap(index))
        subs = subs.enumerated().filter { !gone.contains($0.offset) }.map(\.element)
        subs += lines("sub_add").map { Subtask(title: $0) }
        if f.keys.contains(where: { $0.hasPrefix("sub_") }) { t.subtasks = subs.isEmpty ? nil : subs }
    }

    /// Today's events as text lines, saved by the app so the command can read them without calendar access.
    static let eventsKey = "events.today"
    static func saveEvents(_ events: [EKEvent], now: Date = .now) {
        let lines = events.map { e -> String in
            let time = e.isAllDay ? "All day" : "\(e.startDate.formatted(date: .omitted, time: .shortened))–\(e.endDate.formatted(date: .omitted, time: .shortened))"
            let live = !e.isAllDay && e.startDate <= now && now < e.endDate ? " (happening now)" : ""
            return "  \(time)  \(e.title ?? "Untitled")\(live)"
        }
        UserDefaults.standard.set(lines, forKey: eventsKey)
        UserDefaults.standard.set(now, forKey: eventsKey + ".savedAt")
    }
    /// Empty unless the app saved them today.
    static func savedEvents(now: Date = .now) -> [String] {
        guard let saved = UserDefaults.standard.object(forKey: eventsKey + ".savedAt") as? Date,
              Calendar.current.isDate(saved, inSameDayAs: now) else { return [] }
        return UserDefaults.standard.stringArray(forKey: eventsKey) ?? []
    }
}
