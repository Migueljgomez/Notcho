import AppKit
import EventKit

// MARK: - What gets synced, and how each side is compared

/// The parts of a task that live in Apple Reminders. Equal fingerprints mean "unchanged".
struct SyncFields: Equatable {
    var title: String
    var done: Bool
    var alarm: Date?      // reminder time → due time + alert in Reminders
    var dayKey: String?   // "2026-10-28": a future day with no time (Move to Tomorrow)

    init(title: String, done: Bool, alarm: Date?, dayKey: String?) {
        (self.title, self.done, self.alarm, self.dayKey) = (title, done, alarm, dayKey)
    }

    /// A task's side. A reminder time takes precedence over a plain day, matching how it's written to Reminders.
    init(task t: TaskItem) {
        self.init(title: t.title, done: t.done, alarm: t.reminder, dayKey: t.reminder == nil ? t.day.map { isoDay(of: $0) } : nil)
    }

    var fingerprint: String {
        [title, done ? "1" : "0", alarm.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "", dayKey ?? ""].joined(separator: "\u{1F}")
    }
}

func isoDay(of date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}

func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
    let p = key.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
}

enum SyncAction: Equatable { case none, push, pull, createPhone, createNotch, deleteNotch, deletePhone }

enum SyncPlan {
    /// `saved`: fingerprint at the last sync (nil = never synced). `notch` / `phone`: current fingerprints (nil = missing).
    /// When both sides changed, the notch wins.
    static func decide(saved: String?, notch: String?, phone: String?, phoneCompleted: Bool = false) -> SyncAction {
        switch (notch, phone) {
        case let (n?, p?): return n != saved ? .push : (p != saved ? .pull : .none)
        case let (n?, nil): return saved != nil && n == saved ? .deleteNotch : .createPhone   // deleted on phone, unless edited here since
        case (nil, .some): return saved != nil ? .deletePhone : (phoneCompleted ? .none : .createNotch)
        case (nil, nil): return .none
        }
    }
}

// MARK: - Engine

/// Mirrors tasks into a "Notch" list in Apple Reminders (which iCloud syncs to the iPhone) and pulls changes back.
final class RemindersSync {
    static let shared = RemindersSync()
    weak var store: Store?
    private var running = false
    private var again = false
    private var pending: DispatchWorkItem?
    private let savedKey = "reminders.fingerprints", listKey = "reminders.listID"
    private var es: EKEventStore? { store?.eventStore }

    /// Turn sync on: ask for access, make the list, sync. Reports a problem as a message.
    func enable(_ done: @escaping (String?) -> Void) {
        guard let es else { return }
        Task { @MainActor in
            let granted = (try? await es.requestFullAccessToReminders()) ?? false
            guard granted else { done("Reminders access is off. Allow it in System Settings → Privacy → Reminders."); return }
            guard self.ensureList() != nil else { done(self.store?.syncStatus ?? "Couldn't create the Notch list."); return }
            done(nil)
        }
    }

    /// Debounced: many quick edits become one sync.
    func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func syncNow() {
        guard let store, let es, store.settings.syncReminders else { return }
        // Ad-hoc signing means every rebuild looks like a new app to macOS, which forgets the grant.
        // Ask again instead of silently skipping, and say so if access is off.
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: break
        case .notDetermined:
            Task { @MainActor in
                if (try? await es.requestFullAccessToReminders()) == true { self.syncNow() }
                else { store.syncStatus = "Reminders access is off. Allow it in System Settings → Privacy → Reminders." }
            }
            return
        default:
            store.syncStatus = "Reminders access is off. Allow it in System Settings → Privacy → Reminders."
            return
        }
        guard !running else { again = true; return }
        guard let list = ensureList() else { return }
        running = true
        es.fetchReminders(matching: es.predicateForReminders(in: [list])) { reminders in
            DispatchQueue.main.async {
                self.apply(reminders ?? [], list: list)
                self.running = false
                if self.again { self.again = false; self.syncNow() }
            }
        }
    }

    private func ensureList() -> EKCalendar? {
        guard let es else { return nil }
        if let id = UserDefaults.standard.string(forKey: listKey), let c = es.calendar(withIdentifier: id) { return c }
        if let c = es.calendars(for: .reminder).first(where: { $0.title == "Notch" }) {
            UserDefaults.standard.set(c.calendarIdentifier, forKey: listKey)
            return c
        }
        let c = EKCalendar(for: .reminder, eventStore: es)
        c.title = "Notch"
        // iCloud is what puts it on the phone; Reminders' default account is normally iCloud.
        c.source = es.defaultCalendarForNewReminders()?.source ?? es.sources.first { $0.sourceType == .calDAV }
        do {
            try es.saveCalendar(c, commit: true)
            UserDefaults.standard.set(c.calendarIdentifier, forKey: listKey)
            return c
        } catch {
            store?.syncStatus = "Couldn't create the Notch list: \(error.localizedDescription)"
            return nil
        }
    }

    /// Tasks that belong on the phone: not left in history, and open or completed in the last two days.
    private func inScope(_ t: TaskItem, now: Date) -> Bool {
        t.dismissedAt == nil && (!t.done || (t.completedAt ?? .distantPast) > now.addingTimeInterval(-2 * 86400))
    }

    private func fields(_ r: EKReminder) -> SyncFields {
        let due = r.dueDateComponents
        let timed = due?.hour != nil
        let alarm = r.alarms?.compactMap(\.absoluteDate).first ?? (timed ? due.flatMap { Calendar.current.date(from: $0) } : nil)
        let day = !timed ? due.flatMap { Calendar.current.date(from: $0) }.map { isoDay(of: $0) } : nil
        return SyncFields(title: r.title ?? "", done: r.isCompleted, alarm: alarm, dayKey: alarm == nil ? day : nil)
    }

    private func write(_ f: SyncFields, to r: EKReminder) {
        r.title = f.title
        r.isCompleted = f.done
        r.alarms?.forEach { r.removeAlarm($0) }
        if let a = f.alarm {
            r.addAlarm(EKAlarm(absoluteDate: a))
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: a)
        } else if let key = f.dayKey, let d = date(fromDayKey: key) {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: d)
        } else {
            r.dueDateComponents = nil
        }
    }

    private func read(_ f: SyncFields, into t: inout TaskItem) {
        t.title = f.title.isEmpty ? t.title : f.title
        if f.done != t.done { t.completedAt = f.done ? .now : nil }
        t.reminder = f.alarm
        if f.alarm == nil { t.day = f.dayKey.flatMap { date(fromDayKey: $0) } } // a plain day, or none (= today)
    }

    private func apply(_ reminders: [EKReminder], list: EKCalendar) {
        guard let store, let es else { return }
        let now = Date.now
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) as? [String: String] ?? [:]
        let byID = Dictionary(reminders.map { ($0.calendarItemIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        var tasks = store.tasks
        var linked = Set<String>(), removeTasks = Set<UUID>()
        var created: [(UUID, EKReminder)] = []
        var problems: [String] = []
        func save(_ r: EKReminder) { do { try es.save(r, commit: false) } catch { problems.append(error.localizedDescription) } }

        for i in tasks.indices {
            let t = tasks[i]
            let rid = t.remindersID
            let r = rid.flatMap { byID[$0] }
            if let rid { linked.insert(rid) }
            let notch = inScope(t, now: now) ? SyncFields(task: t) : nil
            switch SyncPlan.decide(saved: rid.flatMap { saved[$0] }, notch: notch?.fingerprint, phone: r.map { fields($0).fingerprint }) {
            case .push:
                write(notch!, to: r!); save(r!); saved[rid!] = notch!.fingerprint
            case .pull:
                let f = fields(r!); read(f, into: &tasks[i]); saved[rid!] = SyncFields(task: tasks[i]).fingerprint
            case .createPhone:
                if let rid { saved[rid] = nil }
                let nr = EKReminder(eventStore: es)
                nr.calendar = list
                write(notch!, to: nr); save(nr); created.append((t.id, nr))
            case .deleteNotch:
                removeTasks.insert(t.id); saved[rid!] = nil
            case .deletePhone:
                if let r { try? es.remove(r, commit: false) }
                tasks[i].remindersID = nil; if let rid { saved[rid] = nil }
            case .createNotch, .none:
                break
            }
        }

        for r in reminders where !linked.contains(r.calendarItemIdentifier) {
            let id = r.calendarItemIdentifier, f = fields(r)
            switch SyncPlan.decide(saved: saved[id], notch: nil, phone: f.fingerprint, phoneCompleted: r.isCompleted) {
            case .deletePhone:
                try? es.remove(r, commit: false); saved[id] = nil
            case .createNotch:
                var t = TaskItem(title: f.title.isEmpty ? "Untitled" : f.title)
                read(f, into: &t)
                t.remindersID = id
                tasks.append(t); saved[id] = SyncFields(task: t).fingerprint
            default:
                break
            }
        }

        do { try es.commit() } catch { problems.append(error.localizedDescription) }
        // Identifiers are final after commit.
        for (taskID, r) in created {
            guard let i = tasks.firstIndex(where: { $0.id == taskID }) else { continue }
            tasks[i].remindersID = r.calendarItemIdentifier
            saved[r.calendarItemIdentifier] = SyncFields(task: tasks[i]).fingerprint
        }
        tasks.removeAll { removeTasks.contains($0.id) }

        if tasks != store.tasks { store.tasks = tasks }
        UserDefaults.standard.set(saved, forKey: savedKey)
        store.syncStatus = problems.isEmpty
            ? "Synced \(now.formatted(date: .omitted, time: .shortened))"
            : "Sync problem: \(problems.first!)"
    }

    /// Turning sync off just pauses it: links and fingerprints are kept, so turning it back on
    /// reconciles whatever changed in between instead of duplicating everything.
    func disable() { store?.syncStatus = "" }
}
