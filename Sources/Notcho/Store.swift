import AppKit
import EventKit
import Observation

struct TaskItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var completedAt: Date?
    var timeLimit: Int?   // minutes; overrides the default focus duration
    var day: Date?        // start of the day it's scheduled for; nil = today
    var createdAt: Date? = .now  // nil for tasks saved before this field existed
    var reminder: Date?
    var dismissedAt: Date?       // "Leave in history": unfinished, no longer on the list
    var remindersID: String?     // linked item in Apple Reminders (Notch list)
    // Planner fields (Phase 4). Optional so older saves still load. `timeLimit` doubles as the time estimate.
    var projectID: UUID?
    var due: Date?               // deadline; separate from `day` (when you plan to work on it)
    var startTime: Date?         // time-block start, shown as a "10:00" pill
    var notes: String?
    var subtasks: [Subtask]?
    var someday: Bool?           // parked with no day; hidden from Today and the notch
    var objectiveID: UUID?       // weekly goal this task moves forward
    var blockID: String?         // its time block: an event in the "Notch" calendar
    var done: Bool { completedAt != nil }

    /// The planning day this task belongs to.
    func planDayOf(startHour: Int) -> Date { day ?? planDay(createdAt ?? .now, startHour: startHour) }

    /// Unfinished from an earlier day and not yet carried over or dismissed.
    func isStale(today: Date, startHour: Int) -> Bool {
        !done && dismissedAt == nil && someday != true && planDayOf(startHour: startHour) < today
    }
}

struct Subtask: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var done = false
}

struct Project: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var color = "sage"   // a Palette name: sage, lavender, olive, blue, rose, sand
}

/// A weekly goal. `week` is the Monday it belongs to ("2026-10-26").
struct Objective: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var week: String
    var achieved: Bool?          // marked done by hand
}

/// The Monday that starts the week containing `date`.
func weekKey(_ date: Date) -> String {
    var cal = Calendar(identifier: .gregorian); cal.firstWeekday = 2; cal.timeZone = .current
    return isoDay(of: cal.dateInterval(of: .weekOfYear, for: date)!.start)
}

struct FocusEntry: Codable, Equatable {
    var date: Date               // when the stretch ended
    var seconds: TimeInterval
    var taskID: UUID? = nil      // which task it was for (nil before Batch 4, or no task picked)
}

enum FocusPhase: String, Codable { case ready, running, paused, finished }

/// Everything the user creates. Saved as JSON to a file in Application Support, batched and off the main thread.
@Observable final class Store {
    var tasks: [TaskItem] = [] { didSet { save(); if !loading { onTasksChanged?() } } }
    var projects: [Project] = [] { didSet { save() } }
    var objectives: [Objective] = [] { didSet { save() } }
    @ObservationIgnored var onTasksChanged: (() -> Void)?   // Apple Reminders sync listens here
    var notes = "" { didSet { save(); if !loading { onNotesChanged?() } } }
    @ObservationIgnored var onNotesChanged: (() -> Void)?  // DailyNotes mirrors the Notepad into today's dated file
    var focusMinutes = 25 { didSet { save() } }

    // Focus session
    var focusState = FocusPhase.ready { didSet { save() } }
    var focusTaskID: UUID? { didSet { save() } }
    var focusEnd: Date? { didSet { save() } }          // set while running
    var focusRemaining: TimeInterval = 25 * 60 { didSet { save() } } // used while ready/paused
    var focusTotal: TimeInterval = 25 * 60 { didSet { save() } }
    var focusLog: [FocusEntry] = [] { didSet { save() } }
    var focusStartedAt: Date? { didSet { save() } }             // stopwatch: current running stretch
    var focusElapsed: TimeInterval = 0 { didSet { save() } }    // stopwatch: time before that stretch
    var settings = Settings() { didSet { save() } }

    // Calendar (not saved)
    @ObservationIgnored let eventStore = EKEventStore()
    var events: [EKEvent] = []
    var calendarAccess = false
    var notificationsOn = false
    var syncStatus = ""
    var breakSuggested = false  // set by the break nudge; the Focus card shows it

    @ObservationIgnored private var loading = true
    private struct Saved: Codable {
        var tasks: [TaskItem], notes: String, focusMinutes: Int
        var focusState: FocusPhase, focusTaskID: UUID?, focusEnd: Date?, focusRemaining: TimeInterval, focusTotal: TimeInterval
        var focusLog: [FocusEntry]?
        var focusStartedAt: Date?, focusElapsed: TimeInterval?, settings: Settings?
        var projects: [Project]?
        var objectives: [Objective]?
    }
    private static let legacyKey = "store.v1"   // pre-Phase-4 home, left in place as a backup
    static let fileURL = URL.applicationSupportDirectory.appending(path: "Notcho/store.json")
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    private static let writer = DispatchQueue(label: "notch.store.writer")

    init() {
        let data = (try? Data(contentsOf: Self.fileURL)) ?? UserDefaults.standard.data(forKey: Self.legacyKey)
        if let data, let s = try? JSONDecoder().decode(Saved.self, from: data) {
            tasks = s.tasks; projects = s.projects ?? []; objectives = s.objectives ?? []; notes = s.notes; focusMinutes = s.focusMinutes
            focusState = s.focusState; focusTaskID = s.focusTaskID; focusEnd = s.focusEnd
            focusRemaining = s.focusRemaining; focusTotal = s.focusTotal
            focusLog = s.focusLog ?? []
            focusStartedAt = s.focusStartedAt; focusElapsed = s.focusElapsed ?? 0; settings = s.settings ?? Settings()
        }
        loading = false
    }

    /// Many quick changes become one write, 0.2 s later, on a background queue. The notch never waits on disk.
    private func save() {
        guard !loading else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Writes immediately (also called when the app quits, so the last change isn't lost).
    func saveNow() {
        pendingSave?.cancel(); pendingSave = nil
        let s = Saved(tasks: tasks, notes: notes, focusMinutes: focusMinutes, focusState: focusState, focusTaskID: focusTaskID,
                      focusEnd: focusEnd, focusRemaining: focusRemaining, focusTotal: focusTotal, focusLog: focusLog,
                      focusStartedAt: focusStartedAt, focusElapsed: focusElapsed, settings: settings, projects: projects, objectives: objectives)
        guard let data = try? JSONEncoder().encode(s) else { return }
        Self.writer.async {
            try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.fileURL, options: .atomic) // atomic: readers never see half a file
        }
    }

    /// Blocks until queued writes are on disk (quit and tests only).
    static func flushWrites() { writer.sync {} }

    // MARK: Tasks

    /// Undone tasks for today: planned for today, or due today / overdue wherever they're planned (like "My Day").
    var todo: [TaskItem] {
        let (today, h) = (self.today, settings.dayStartHour)
        return tasks.filter { !$0.done && $0.dismissedAt == nil && (($0.someday != true && $0.planDayOf(startHour: h) == today) || isDueNow($0)) }
    }

    /// Due today or earlier.
    func isDueNow(_ t: TaskItem) -> Bool {
        guard let due = t.due else { return false }
        return due < Calendar.current.date(byAdding: .day, value: 1, to: today)!
    }

    // MARK: Workload

    /// Estimated minutes on Today (tasks without an estimate count as 0).
    var plannedMinutes: Int { todo.compactMap(\.timeLimit).reduce(0, +) }

    /// Minutes from now until "Workday ends at".
    func minutesLeft(now: Date = .now) -> Int {
        let end = Calendar.current.date(bySettingHour: settings.workdayEndHour, minute: 0, second: 0, of: now) ?? now
        return max(0, Int(end.timeIntervalSince(now) / 60))
    }

    // MARK: Planner

    /// Open tasks planned for a later day, soonest first.
    var upcoming: [TaskItem] {
        let (today, h) = (self.today, settings.dayStartHour)
        return tasks.filter { !$0.done && $0.dismissedAt == nil && $0.someday != true && $0.planDayOf(startHour: h) > today }
            .sorted { $0.planDayOf(startHour: h) < $1.planDayOf(startHour: h) }
    }
    var someday: [TaskItem] { tasks.filter { !$0.done && $0.someday == true } }
    var doneRecent: [TaskItem] { completed.sorted { $0.completedAt! > $1.completedAt! } }
    func tasks(in project: UUID) -> [TaskItem] { tasks.filter { $0.projectID == project && $0.dismissedAt == nil } }

    /// One place for Planner edits.
    func update(_ id: UUID, _ change: (inout TaskItem) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        var t = tasks[i]; change(&t)
        if t != tasks[i] { tasks[i] = t }
    }

    @discardableResult
    func addTask(_ title: String, _ edit: (inout TaskItem) -> Void = { _ in }) -> UUID? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var t = TaskItem(title: title); edit(&t)
        tasks.append(t)
        return t.id
    }

    /// Schedule for a day (nil = today), or park in Someday.
    func schedule(_ id: UUID, day: Date?, someday: Bool = false) {
        update(id) { $0.day = someday ? nil : day; $0.someday = someday ? true : nil; $0.dismissedAt = nil }
    }

    func addProject(_ name: String) -> UUID {
        let colors = ["sage", "lavender", "olive", "blue", "rose", "sand"]
        let p = Project(name: name, color: colors[projects.count % colors.count])
        projects.append(p)
        return p.id
    }

    // MARK: Weekly objectives

    var thisWeek: String { weekKey(today) }
    func objectives(in week: String) -> [Objective] { objectives.filter { $0.week == week } }

    /// (done, total) linked tasks.
    func progress(_ o: Objective) -> (Int, Int) {
        let linked = tasks.filter { $0.objectiveID == o.id && $0.dismissedAt == nil }
        return (linked.filter(\.done).count, linked.count)
    }

    /// Achieved when marked by hand, or when it has linked tasks and all are done.
    func isAchieved(_ o: Objective) -> Bool {
        let (d, n) = progress(o)
        return o.achieved == true || (n > 0 && d == n)
    }

    func addObjective(_ title: String, week: String? = nil) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { objectives.append(Objective(title: t, week: week ?? thisWeek)) }
    }

    /// Deleting a goal keeps its tasks; they just lose the link.
    func deleteObjective(_ id: UUID) {
        objectives.removeAll { $0.id == id }
        tasks = tasks.map { var t = $0; if t.objectiveID == id { t.objectiveID = nil }; return t }
    }

    /// Removing a project keeps its tasks; they just lose the project.
    func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        tasks = tasks.map { var t = $0; if t.projectID == id { t.projectID = nil }; return t }
    }

    /// Renames a project and moves its plan page file to the new name (never over an existing file).
    /// Blank names and names another project already uses are refused.
    @discardableResult
    func renameProject(_ id: UUID, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let i = projects.firstIndex(where: { $0.id == id }) else { return false }
        if projects.contains(where: { $0.id != id && $0.name.lowercased() == name.lowercased() }) { return false }
        let from = NoteFiles.planURL(projects[i])
        projects[i].name = name
        let to = NoteFiles.planURL(projects[i]), fm = FileManager.default
        if from != to, fm.fileExists(atPath: from.path(percentEncoded: false)), !fm.fileExists(atPath: to.path(percentEncoded: false)) {
            try? fm.moveItem(at: from, to: to)
        }
        return true
    }

    /// Yesterday's (or older) unfinished tasks waiting for an "Ask me" answer.
    var stale: [TaskItem] { tasks.filter { $0.isStale(today: today, startHour: settings.dayStartHour) && !isDueNow($0) } } // overdue ones are already on Today

    /// Undone tasks with a reminder from today on, soonest first.
    var reminders: [TaskItem] {
        tasks.filter { !$0.done && ($0.reminder ?? .distantPast) >= today }.sorted { $0.reminder! < $1.reminder! }
    }

    /// New day: apply the "Unfinished tasks" setting to stale tasks. "Ask me" leaves them for the prompt.
    func rollover() {
        switch settings.unfinished {
        case .ask: return
        case .carry: carryStale()
        case .leave: dismissStale()
        }
    }

    func carryStale() {
        let today = self.today
        tasks = tasks.map { t in var t = t; if t.isStale(today: today, startHour: settings.dayStartHour) { t.day = today }; return t }
    }

    func dismissStale() {
        let today = self.today
        tasks = tasks.map { t in var t = t; if t.isStale(today: today, startHour: settings.dayStartHour) { t.dismissedAt = today }; return t }
    }

    func setReminder(_ id: UUID, at date: Date?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].reminder = date
        ReminderService.shared.sync(tasks[i])
    }

    /// Start of the current planning day; a day can start later than midnight ("Day starts at").
    var today: Date { planDay(.now, startHour: settings.dayStartHour) }
    var completed: [TaskItem] { tasks.filter(\.done) }
    var focusTask: TaskItem? { tasks.first { $0.id == focusTaskID } }

    func add(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { tasks.append(TaskItem(title: t)) }
    }

    func toggle(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].completedAt = tasks[i].done ? nil : .now
        ReminderService.shared.sync(tasks[i]) // done → cancelled, undone → rescheduled
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        tasks[i].title = title
    }

    func setTimeLimit(_ id: UUID, minutes: Int?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].timeLimit = minutes.map { max(1, min($0, 240)) }
    }

    func moveToTomorrow(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].day = Calendar.current.date(byAdding: .day, value: 1, to: today)
        if focusTaskID == id { endSession(); focusTaskID = nil }
    }

    func duplicate(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        var copy = tasks[i]
        copy.id = UUID(); copy.completedAt = nil; copy.reminder = nil; copy.createdAt = .now
        tasks.insert(copy, at: i + 1)
    }

    /// Reorder within the To do list (offsets are positions in `todo`).
    func moveTodo(from source: IndexSet, to destination: Int) {
        var order = todo.map(\.id)
        order.move(fromOffsets: source, toOffset: destination)
        tasks = Self.reslot(tasks, order: order)
    }

    /// Puts the tasks named in `order` into that order, using only the slots they already occupy.
    static func reslot(_ tasks: [TaskItem], order: [UUID]) -> [TaskItem] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let slots = tasks.indices.filter { rank[tasks[$0].id] != nil }
        let sorted = slots.map { tasks[$0] }.sorted { rank[$0.id]! < rank[$1.id]! }
        var next = tasks
        for (slot, task) in zip(slots, sorted) { next[slot] = task }
        return next
    }

    // MARK: Focus timer

    func remaining(at now: Date = .now) -> TimeInterval {
        focusState == .running ? max(0, focusEnd?.timeIntervalSince(now) ?? 0) : focusRemaining
    }

    var isStopwatch: Bool { settings.stopwatch }

    /// Seconds shown on the clock: time left (countdown) or time spent (stopwatch).
    func display(at now: Date = .now) -> TimeInterval {
        isStopwatch ? focusElapsed + (focusStartedAt.map { now.timeIntervalSince($0) } ?? 0) : remaining(at: now)
    }

    /// Seconds spent in the current session.
    func spent(at now: Date = .now) -> TimeInterval { isStopwatch ? display(at: now) : focusTotal - remaining(at: now) }

    /// Starting a specific task begins a fresh session using its time limit (or the default).
    func start(task: UUID? = nil) {
        if isStopwatch {
            if let task { logElapsed(); focusTaskID = task }
            if task != nil || focusState != .paused { focusElapsed = 0 }
            focusStartedAt = .now; focusState = .running
            return
        }
        if let task {
            logElapsed() // switching tasks mid-session keeps the time already spent
            focusTaskID = task
            focusRemaining = TimeInterval((focusTask?.timeLimit ?? focusMinutes) * 60); focusTotal = focusRemaining
        } else if focusState == .finished || focusState == .ready {
            focusRemaining = TimeInterval((focusTask?.timeLimit ?? focusMinutes) * 60); focusTotal = focusRemaining
        }
        focusEnd = Date.now.addingTimeInterval(focusRemaining)
        focusState = .running
    }

    func pause() {
        if isStopwatch { focusElapsed = display(); focusStartedAt = nil; focusState = .paused; return }
        focusRemaining = remaining(); focusEnd = nil; focusState = .paused
    }

    func addFiveMinutes() {
        // After "Time's up" the finished session is already logged, so the extra 5 min is a new segment.
        focusTotal = focusState == .finished ? 300 : focusTotal + 300
        focusRemaining = remaining() + 300
        focusEnd = Date.now.addingTimeInterval(focusRemaining)
        focusState = .running
    }

    func endSession() {
        logElapsed()
        focusState = .ready; focusEnd = nil; focusStartedAt = nil; focusElapsed = 0
        focusRemaining = TimeInterval(focusMinutes * 60); focusTotal = focusRemaining
    }

    /// ✓ button: completes the focused task (if any) and ends the session.
    func completeFocus() {
        if let id = focusTaskID, let i = tasks.firstIndex(where: { $0.id == id }) {
            tasks[i].completedAt = .now
            ReminderService.shared.cancel(id)
        }
        endSession() // logs the time to the task first
        focusTaskID = nil
    }

    func setDuration(_ minutes: Int) {
        focusMinutes = max(1, min(minutes, 240))
        if focusState != .running { endSession() }
    }

    /// Called every second by the controller; returns true when a session just finished.
    func tick(now: Date = .now) -> Bool {
        guard !isStopwatch, focusState == .running, remaining(at: now) <= 0 else { return false }
        focusLog.append(FocusEntry(date: now, seconds: focusTotal, taskID: focusTaskID))
        focusState = .finished; focusEnd = nil; focusRemaining = 0
        return true
    }

    /// Records time spent in an unfinished session (running or paused). Sessions under 30 s are ignored.
    private func logElapsed() {
        guard focusState == .running || focusState == .paused else { return }
        let spent = spent()
        if spent >= 30 { focusLog.append(FocusEntry(date: .now, seconds: spent, taskID: focusTaskID)) }
    }

    // MARK: Time tracking

    /// Minutes of focus logged to a task, plus the session running on it right now.
    func actualMinutes(_ id: UUID, now: Date = .now) -> Int {
        let logged = focusLog.filter { $0.taskID == id }.reduce(0) { $0 + $1.seconds }
        let live = focusTaskID == id && (focusState == .running || focusState == .paused) ? spent(at: now) : 0
        return Int((logged + live) / 60)
    }

    /// Unbroken focus up to now: stretches separated by less than 10 minutes count as one streak.
    static func focusStreak(log: [FocusEntry], live: TimeInterval, now: Date, gap: TimeInterval = 600) -> TimeInterval {
        var total = live, start = now.addingTimeInterval(-live)
        for e in log.sorted(by: { $0.date > $1.date }) {
            guard start.timeIntervalSince(e.date) < gap else { break }
            total += e.seconds
            start = e.date.addingTimeInterval(-e.seconds)
        }
        return live == 0 && (log.map(\.date).max().map { now.timeIntervalSince($0) >= gap } ?? true) ? 0 : total
    }

    var currentStreak: TimeInterval {
        Self.focusStreak(log: focusLog, live: focusState == .running ? spent() : 0, now: .now)
    }

    // MARK: Calendar

    func connectCalendar() {
        Task { @MainActor in
            calendarAccess = (try? await eventStore.requestFullAccessToEvents()) ?? false
            loadEvents()
        }
    }

    func loadEvents() {
        calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard calendarAccess else { events = []; return }
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        events = eventStore.events(matching: eventStore.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { $0.status != .canceled }.sorted { $0.startDate < $1.startDate }
        Store.saveEvents(events) // for `notch today`
        Timebox.exportCalendar(eventStore) // for agents: read_day
    }
}

/// The calendar day a moment belongs to when days start at `startHour` (e.g. 2 AM still counts as yesterday if days start at 6).
func planDay(_ date: Date, startHour: Int, calendar: Calendar = .current) -> Date {
    calendar.startOfDay(for: date.addingTimeInterval(-Double(startHour) * 3600))
}

func wordCount(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }

func clock(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded(.up))
    return String(format: "%02d:%02d", s / 60, s % 60)
}
