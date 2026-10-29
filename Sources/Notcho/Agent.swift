import Foundation

// MARK: - Planner actions for agents (MCP). Same rules as `Actions`: the app owns every write; we send a keyed
// link and confirm by re-reading the saved data. Plan pages are plain files, so those are written directly.

enum PlannerActions {
    typealias R = Result<String, CLIError>
    static let iso = ISO8601DateFormatter()

    // MARK: Resolving words to things

    /// "today", "tomorrow", "someday", "friday", "next week", "in 3 days", "2026-10-30" → "YYYY-MM-DD" or "someday".
    static func parseDay(_ input: String, now: Date = .now, calendar cal: Calendar = .current) -> String? {
        let s = input.lowercased().trimmingCharacters(in: .whitespaces)
        let today = cal.startOfDay(for: now)
        func day(_ n: Int) -> String { isoDay(of: cal.date(byAdding: .day, value: n, to: today)!) }
        switch s {
        case "today": return day(0)
        case "tomorrow": return day(1)
        case "someday", "later": return "someday"
        case "next week": return weekKey(cal.date(byAdding: .day, value: 7, to: today)!)
        default: break
        }
        if let m = s.wholeMatch(of: #/in (\d+) days?/#) { return day(Int(m.1)!) }
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let i = names.firstIndex(where: { $0.hasPrefix(s) && s.count >= 3 }) {
            let ahead = (i + 1 - cal.component(.weekday, from: today) + 7) % 7
            return day(ahead)
        }
        return date(fromDayKey: s) != nil ? s : nil
    }

    /// A start/end time, optionally on a given day: "2pm" + "friday" → Friday 14:00. Also ISO 8601 or "in 30m".
    static func parseClock(_ time: String, on dayWord: String?, now: Date = .now) -> Date? {
        if let d = iso.date(from: time) { return d }
        if let dayWord {
            guard let key = parseDay(dayWord, now: now), let day = date(fromDayKey: key) else { return nil }
            return parseTime(time, now: day.addingTimeInterval(-1)) // the clock time on that day
        }
        // No day given: a clock time means today (even if it's passed), a relative time means from now.
        if let t = parseTime(time, now: Calendar.current.startOfDay(for: now).addingTimeInterval(-1)),
           time.range(of: #"^\s*(in\s*)?\d+\s*(h|m)"#, options: [.regularExpression, .caseInsensitive]) == nil { return t }
        return parseTime(time, now: now)
    }

    static func findProject(_ query: String, in store: Store) -> Result<Project, CLIError> {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if let p = store.projects.first(where: { $0.name.lowercased() == q || $0.id.uuidString.lowercased().hasPrefix(q) && q.count >= 6 }) { return .success(p) }
        let partial = store.projects.filter { $0.name.lowercased().contains(q) }
        if partial.count == 1 { return .success(partial[0]) }
        let names = store.projects.map(\.name).joined(separator: ", ")
        return .failure(CLIError(partial.isEmpty ? "no project matches \"\(query)\". Projects: \(names.isEmpty ? "none yet" : names)"
                                                 : "\"\(query)\" matches several projects: \(partial.map(\.name).joined(separator: ", "))"))
    }

    static func findGoal(_ query: String, in store: Store) -> Result<Objective, CLIError> {
        let q = query.lowercased(), goals = store.objectives(in: store.thisWeek)
        if let o = goals.first(where: { $0.title.lowercased() == q }) { return .success(o) }
        let partial = goals.filter { $0.title.lowercased().contains(q) }
        return partial.count == 1 ? .success(partial[0])
            : .failure(CLIError("no single goal this week matches \"\(query)\". Goals: \(goals.map(\.title).joined(separator: ", "))"))
    }

    static func edit(_ op: String, _ fields: [String: String], until check: (Store) -> Bool) -> Bool {
        Actions.sendAndConfirm(.edit(op: op, fields: fields), until: check)
    }

    static let noConfirm = CLIError("the app didn't confirm — is it running?")

    // MARK: Projects and plan pages

    static func listProjects() -> String {
        let s = Actions.fresh()
        guard !s.projects.isEmpty else { return "No projects yet. Use create_project." }
        return s.projects.map { p in
            let all = s.tasks(in: p.id), open = all.filter { !$0.done }.count
            let plan = NoteFiles.read(NoteFiles.planURL(p)).map { $0.isEmpty ? "empty" : "\($0.count) chars" } ?? "none"
            return "• \(p.name) [\(p.color)]: \(open) open, \(all.count - open) done · plan page: \(plan)"
        }.joined(separator: "\n")
    }

    static func getProject(_ query: String) -> R {
        let s = Actions.fresh()
        return findProject(query, in: s).map { p in
            let all = s.tasks(in: p.id)
            let plan = NoteFiles.read(NoteFiles.planURL(p)) ?? ""
            var out = ["# \(p.name)", "", "## Plan page", plan.isEmpty ? "(empty)" : plan, "", "## Open tasks"]
            out += all.filter { !$0.done }.map { line($0, s) }
            if all.allSatisfy(\.done) { out.append("(none)") }
            let done = all.filter(\.done)
            if !done.isEmpty { out += ["", "## Done"] + done.map { "  ✓ \($0.title)" } }
            return out.joined(separator: "\n")
        }
    }

    static func line(_ t: TaskItem, _ s: Store) -> String {
        var bits = ["  ○ \(t.title) [\(t.shortID)]"]
        if t.someday == true { bits.append("someday") } else { bits.append("day " + isoDay(of: t.planDayOf(startHour: s.settings.dayStartHour))) }
        if let d = t.due { bits.append("due " + isoDay(of: d)) }
        if let m = t.timeLimit { bits.append("est \(m)m") }
        if let st = t.startTime { bits.append("block " + st.formatted(date: .omitted, time: .shortened)) }
        if let g = s.objectives.first(where: { $0.id == t.objectiveID }) { bits.append("goal: \(g.title)") }
        if let subs = t.subtasks, !subs.isEmpty {
            let list = subs.prefix(12).enumerated().map { "\($0.offset + 1). \($0.element.done ? "✓ " : "")\($0.element.title)" }.joined(separator: "; ")
            bits.append("subtasks \(subs.filter(\.done).count)/\(subs.count): \(list)\(subs.count > 12 ? "; …" : "")")
        }
        if let n = t.notes?.split(whereSeparator: \.isNewline).joined(separator: " / "), !n.isEmpty {
            bits.append("notes: \(n.prefix(120))\(n.count > 120 ? "…" : "")")
        }
        return bits.joined(separator: " · ")
    }

    static func createProject(_ name: String, color: String?) -> R {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .failure(CLIError("a project needs a name")) }
        if let p = Actions.fresh().projects.first(where: { $0.name.lowercased() == name.lowercased() }) { return .success("Already exists: \(p.name)") }
        let id = UUID()
        var f = ["id": id.uuidString, "name": name]
        if let color { f["color"] = color }
        return edit("project.create", f) { $0.projects.contains { $0.id == id } } ? .success("Created project: \(name)") : .failure(noConfirm)
    }

    static func updateProject(_ query: String, name: String?, color: String?) -> R {
        let s = Actions.fresh()
        return findProject(query, in: s).flatMap { p in
            var f = ["id": p.id.uuidString]
            if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                if s.projects.contains(where: { $0.id != p.id && $0.name.lowercased() == name.lowercased() }) { return .failure(CLIError("another project is already called \(name)")) }
                f["name"] = name
            }
            if let color { f["color"] = color.lowercased() }
            guard f.count > 1 else { return .failure(CLIError("nothing to change: pass name or color")) }
            return edit("project.update", f) { st in
                st.projects.first { $0.id == p.id }.map { q in f["name"].map { q.name == $0 } ?? true && f["color"].map { q.color == $0 } ?? true } ?? false
            } ? .success("Updated project: \(f["name"] ?? p.name)") : .failure(CLIError("not saved (unknown color, or the app isn't running)"))
        }
    }

    /// Plan pages are files in iCloud Drive → Notch → Plans, so they're written directly.
    static func updatePlan(_ query: String, text: String, append: Bool) -> R {
        findProject(query, in: Actions.fresh()).map { p in
            let url = NoteFiles.planURL(p)
            let old = NoteFiles.read(url) ?? ""
            let new = append && !old.isEmpty ? old + "\n\n" + text : text
            NoteFiles.write(new, to: url)
            NoteFiles.flush()
            return "\(append ? "Added to" : "Replaced") the plan page for \(p.name) (\(new.count) chars)."
        }
    }

    // MARK: Tasks

    /// Turns tool arguments into edit fields, resolving names and day words. Unknown values fail loudly.
    static func fields(_ a: [String: Any], _ s: Store) -> Result<[String: String], CLIError> {
        var f: [String: String] = [:]
        if let v = a["title"] as? String { f["title"] = v }
        if let v = a["notes"] as? String { f["notes"] = v }
        if let v = a["append_notes"] as? String { f["notes_append"] = v }
        // subtasks: one per line (or a JSON array); check/uncheck/remove match by number (1 = first) or title
        for (key, field) in [("add_subtasks", "sub_add"), ("check_subtasks", "sub_check"), ("uncheck_subtasks", "sub_uncheck"), ("remove_subtasks", "sub_remove")] {
            let v = (a[key] as? [String])?.joined(separator: "\n") ?? a[key] as? String
            if let v, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { f[field] = v }
        }
        if let v = a["project"] as? String {
            if v.lowercased() == "none" { f["project"] = "none" } else {
                switch findProject(v, in: s) { case let .success(p): f["project"] = p.id.uuidString; case let .failure(e): return .failure(e) }
            }
        }
        if let v = a["goal"] as? String {
            if v.lowercased() == "none" { f["goal"] = "none" } else {
                switch findGoal(v, in: s) { case let .success(o): f["goal"] = o.id.uuidString; case let .failure(e): return .failure(e) }
            }
        }
        if let v = a["due"] as? String {
            if v.lowercased() == "none" { f["due"] = "none" }
            else if let d = parseDay(v), d != "someday" { f["due"] = d }
            else { return .failure(CLIError("can't read the due date \"\(v)\" (try friday, 2026-11-03, tomorrow)")) }
        }
        if let v = a["day"] as? String {
            guard let d = parseDay(v) else { return .failure(CLIError("can't read the day \"\(v)\" (try today, tomorrow, someday, friday)")) }
            f["day"] = d
        }
        if let v = (a["estimate_minutes"] ?? a["time_limit_minutes"]) as? NSNumber { f["estimate"] = String(v.intValue) }
        if let v = a["remind"] as? String {
            if v.lowercased() == "none" { f["remind"] = "none" }
            else if let d = parseTime(v) { f["remind"] = iso.string(from: d) }
            else { return .failure(CLIError("can't read the time \"\(v)\" (try 5pm, 17:00, 30m)")) }
        }
        return .success(f)
    }

    static func addTask(_ a: [String: Any]) -> R {
        let s = Actions.fresh()
        guard let title = (a["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return .failure(CLIError("a task needs a title")) }
        return fields(a, s).flatMap { f in
            let id = UUID()
            var f = f; f["id"] = id.uuidString; f["title"] = title
            return edit("task.add", f) { $0.tasks.contains { $0.id == id } }
                ? .success("Added: " + line(Actions.fresh().tasks.first { $0.id == id }!, Actions.fresh()).trimmingCharacters(in: .whitespaces))
                : .failure(noConfirm)
        }
    }

    static func updateTask(_ a: [String: Any]) -> R {
        let s = Actions.fresh()
        return findTask(a["task"] as? String ?? "", in: s.tasks).flatMap { t in
            fields(a, s).flatMap { f in
                guard !f.isEmpty else { return .failure(CLIError("nothing to change: pass title, notes, append_notes, subtasks, project, goal, due, day, estimate_minutes or remind")) }
                var f = f; f["id"] = t.id.uuidString
                let before = t
                return edit("task.update", f) { $0.tasks.first { $0.id == t.id } != before }
                    ? .success("Updated: " + line(Actions.fresh().tasks.first { $0.id == t.id }!, Actions.fresh()).trimmingCharacters(in: .whitespaces))
                    : .failure(CLIError("no change was saved (already like that, or the app isn't running)"))
            }
        }
    }

    static func addToToday(_ query: String) -> R {
        let s = Actions.fresh()
        return findTask(query, in: s.tasks).flatMap { t in
            if s.todo.contains(where: { $0.id == t.id }) { return .success("Already on Today: \(t.title)") }
            return edit("task.update", ["id": t.id.uuidString, "day": isoDay(of: s.today)]) { $0.todo.contains { $0.id == t.id } }
                ? .success("On Today: \(t.title)") : .failure(noConfirm)
        }
    }

    // MARK: Goals

    static func listGoals() -> String {
        let s = Actions.fresh()
        let goals = s.objectives(in: s.thisWeek)
        guard !goals.isEmpty else { return "No goals for the week of \(s.thisWeek) yet. Use add_goal." }
        return "Goals, week of \(s.thisWeek):\n" + goals.map { o in
            let (d, n) = s.progress(o)
            return "• \(o.title): \(s.isAchieved(o) ? "achieved" : "in progress") · \(d)/\(n) linked tasks done"
        }.joined(separator: "\n")
    }

    static func addGoal(_ title: String) -> R {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return .failure(CLIError("a goal needs a title")) }
        let id = UUID()
        return edit("goal.add", ["id": id.uuidString, "title": title]) { $0.objectives.contains { $0.id == id } }
            ? .success("Goal added for this week: \(title)") : .failure(noConfirm)
    }

    // MARK: Calendar

    static func savedEvents() -> [Timebox.SavedEvent]? {
        (try? Data(contentsOf: Timebox.exportURL)).flatMap { try? JSONDecoder().decode([Timebox.SavedEvent].self, from: $0) }
    }

    static func readDay(_ word: String?) -> R {
        guard let key = parseDay(word ?? "today"), key != "someday", let day = date(fromDayKey: key) else {
            return .failure(CLIError("can't read the day \"\(word ?? "")\""))
        }
        let s = Actions.fresh()
        var out = ["\(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))", "", "Calendar:"]
        if let events = savedEvents() {
            let today = events.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }.sorted { $0.start < $1.start }
            out += today.isEmpty ? ["  (nothing)"] : today.map { e in
                let time = e.allDay ? "all day" : "\(e.start.formatted(date: .omitted, time: .shortened))–\(e.end.formatted(date: .omitted, time: .shortened))"
                return "  \(time)  \(e.title)" + (e.task != nil ? "  [Notch block]" : "  (\(e.calendar))")
            }
        } else {
            out.append("  (calendar not shared yet: open the app with Calendar connected)")
        }
        let planned = s.tasks.filter { !$0.done && $0.dismissedAt == nil && $0.someday != true && isoDay(of: $0.planDayOf(startHour: s.settings.dayStartHour)) == key }
        out += ["", "Tasks planned that day:"] + (planned.isEmpty ? ["  (none)"] : planned.map { line($0, s) })
        return .success(out.joined(separator: "\n"))
    }

    /// Blocks time for a task (creating the task if nothing matches). Reports clashes with other events.
    static func blockTime(_ a: [String: Any]) -> R {
        let dayWord = a["date"] as? String
        guard let startText = a["start"] as? String, let start = parseClock(startText, on: dayWord) else {
            return .failure(CLIError("can't read the start time (try 2pm, 14:00, with date: friday)"))
        }
        var minutes = (a["minutes"] as? NSNumber)?.intValue
        if let endText = a["end"] as? String {
            guard let end = parseClock(endText, on: dayWord ?? isoDay(of: start)), end > start else { return .failure(CLIError("the end time must be after the start")) }
            minutes = Int(end.timeIntervalSince(start) / 60)
        }
        let query = a["task"] as? String ?? ""
        var s = Actions.fresh()
        var task: TaskItem
        switch findTask(query, in: s.tasks) {
        case let .success(t): task = t
        case .failure:
            guard !query.isEmpty else { return .failure(CLIError("say which task to block time for")) }
            let id = UUID()
            guard edit("task.add", ["id": id.uuidString, "title": query, "day": isoDay(of: start)], until: { $0.tasks.contains { $0.id == id } }) else { return .failure(noConfirm) }
            s = Actions.fresh(); task = s.tasks.first { $0.id == id }!
        }
        let length = minutes ?? task.timeLimit ?? 30
        let end = start.addingTimeInterval(TimeInterval(length * 60))
        var f = ["id": task.id.uuidString, "start": iso.string(from: start)]
        if let minutes { f["minutes"] = String(minutes) }
        guard edit("block", f, until: { st in
            st.tasks.first { $0.id == task.id }.map { $0.blockID != nil && $0.timeLimit == length && $0.startTime.map { abs($0.timeIntervalSince(start)) < 1 } == true } ?? false
        }) else { return .failure(CLIError("the block wasn't confirmed: is the app running with Calendar connected?")) }
        let clashes = (savedEvents() ?? []).filter { !$0.allDay && $0.task != task.id && $0.start < end && start < $0.end }
        let when = "\(start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) \(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
        return .success("Blocked \(when) for \(task.title) (Notch calendar)."
            + (clashes.isEmpty ? "" : "\nHeads-up, overlaps: " + clashes.map { "\($0.title) \($0.start.formatted(date: .omitted, time: .shortened))" }.joined(separator: ", ")))
    }

    static func removeBlock(_ query: String) -> R {
        findTask(query, in: Actions.fresh().tasks).flatMap { t in
            guard t.blockID != nil else { return .success("\(t.title) has no time block.") }
            return edit("unblock", ["id": t.id.uuidString]) { $0.tasks.first { $0.id == t.id }?.blockID == nil }
                ? .success("Removed the block for \(t.title). The task stays.") : .failure(noConfirm)
        }
    }

    static func deleteTask(_ query: String) -> R {
        findTask(query, in: Actions.fresh().tasks).flatMap { t in
            edit("task.delete", ["id": t.id.uuidString]) { !$0.tasks.contains { $0.id == t.id } }
                ? .success("Deleted: \(t.title)") : .failure(noConfirm)
        }
    }

    // MARK: Search and notes

    static func search(_ query: String) -> R {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return .failure(CLIError("search needs at least 2 characters")) }
        let s = Actions.fresh()
        var out: [String] = []
        let tasks = s.tasks.filter { $0.title.lowercased().contains(q) || ($0.notes?.lowercased().contains(q) ?? false) }
        if !tasks.isEmpty { out += ["Tasks:"] + tasks.prefix(20).map { $0.done ? "  ✓ \($0.title) [\($0.shortID)]" : line($0, s) } }
        func hits(_ title: String, _ files: [(String, URL)]) {
            var lines: [String] = []
            for (name, url) in files {
                for l in (NoteFiles.read(url) ?? "").split(separator: "\n") where l.lowercased().contains(q) { lines.append("  \(name): \(l.prefix(160))") }
            }
            if !lines.isEmpty { out += ["", title] + lines.prefix(20) }
        }
        hits("Daily notes:", NoteFiles.listNotes().map { ($0.day, $0.url) })
        hits("Plan pages:", s.projects.map { ($0.name, NoteFiles.planURL($0)) })
        return .success(out.isEmpty ? "Nothing matches \"\(query)\"." : out.joined(separator: "\n"))
    }

    static func readNote(_ word: String?) -> R {
        guard let word else { return .success(Actions.notes()) }
        guard let key = parseDay(word), let d = date(fromDayKey: key) else { return .failure(CLIError("can't read the day \"\(word)\"")) }
        return .success(NoteFiles.read(NoteFiles.noteURL(d)).map { $0.isEmpty ? "(empty)" : $0 } ?? "(no note for \(key))")
    }
}

// MARK: - MCP tools for the Planner

extension MCP {
    static let projectArg = ["type": "string", "description": "Project name (or a unique part of it)"]
    static let dayArg = ["type": "string", "description": "today, tomorrow, someday, a weekday (friday), next week, in 3 days, or YYYY-MM-DD"]

    static let plannerTools: [Tool] = [
        Tool(name: "list_projects", description: "List the user's Planner projects with open/done counts and whether each has a plan page.",
             properties: [:], required: []) { _ in .success(PlannerActions.listProjects()) },
        Tool(name: "get_project", description: "A project's full context: its plan page (goals, decisions, notes) and all its tasks with ids, days, due dates, estimates and notes. Read this before helping with a project.",
             properties: ["project": projectArg], required: ["project"]) { a in PlannerActions.getProject(a["project"] as? String ?? "") },
        Tool(name: "update_project", description: "Rename a project and/or change its color. Its plan page keeps working under the new name.",
             properties: ["project": projectArg, "name": ["type": "string", "description": "New name"],
                          "color": ["type": "string", "description": "sage, lavender, olive, blue, rose or sand"]],
             required: ["project"]) { a in PlannerActions.updateProject(a["project"] as? String ?? "", name: a["name"] as? String, color: a["color"] as? String) },
        Tool(name: "create_project", description: "Create a Planner project.",
             properties: ["name": ["type": "string", "description": "Project name"],
                          "color": ["type": "string", "description": "sage, lavender, olive, blue, rose or sand (optional)"]],
             required: ["name"]) { a in PlannerActions.createProject(a["name"] as? String ?? "", color: a["color"] as? String) },
        Tool(name: "update_plan", description: "Write a project's plan page (Markdown). mode \"append\" adds to the end (default); \"replace\" overwrites. Use it to record decisions and context.",
             properties: ["project": projectArg, "text": ["type": "string", "description": "Markdown text"],
                          "mode": ["type": "string", "description": "append (default) or replace"]],
             required: ["project", "text"]) { a in
            PlannerActions.updatePlan(a["project"] as? String ?? "", text: a["text"] as? String ?? "", append: (a["mode"] as? String) != "replace")
        },
        Tool(name: "update_task", description: "Change a task: title, notes (replace), append_notes, subtasks (add, check off, uncheck, remove; list_today shows them numbered), project, goal, due date, day it's planned for, estimate (also resizes its time block), reminder. Use \"none\" to clear project, goal, due or remind.",
             properties: ["task": taskArg, "title": ["type": "string", "description": "New title"],
                          "notes": ["type": "string", "description": "Replace the task's notes (wipes what the user wrote; prefer append_notes)"],
                          "append_notes": ["type": "string", "description": "Add to the task's notes"],
                          "project": projectArg, "goal": ["type": "string", "description": "This week's goal title"],
                          "due": dayArg, "day": dayArg,
                          "estimate_minutes": ["type": "integer", "description": "Time estimate in minutes"], "remind": timeArg,
                          "add_subtasks": ["type": "string", "description": "Subtasks to add, one per line"],
                          "check_subtasks": ["type": "string", "description": "Subtasks to check off: numbers (1 = first) or titles, one per line"],
                          "uncheck_subtasks": ["type": "string", "description": "Subtasks to mark not done, one per line"],
                          "remove_subtasks": ["type": "string", "description": "Subtasks to remove: numbers or titles, one per line"]],
             required: ["task"]) { a in PlannerActions.updateTask(a) },
        Tool(name: "add_to_today", description: "Put an existing task on Today (it then shows in the notch).",
             properties: ["task": taskArg], required: ["task"]) { a in PlannerActions.addToToday(a["task"] as? String ?? "") },
        Tool(name: "list_goals", description: "This week's goals with progress (linked tasks done / total).",
             properties: [:], required: []) { _ in .success(PlannerActions.listGoals()) },
        Tool(name: "add_goal", description: "Add a goal for this week (keep it to 2–3 a week). Link tasks with update_task goal.",
             properties: ["title": ["type": "string", "description": "Goal"]], required: ["title"]) { a in PlannerActions.addGoal(a["title"] as? String ?? "") },
        Tool(name: "read_day", description: "A day's calendar events (including Notch time blocks) and the tasks planned for it. Check this before blocking time.",
             properties: ["date": dayArg], required: []) { a in PlannerActions.readDay(a["date"] as? String) },
        Tool(name: "block_time", description: "Block time on the calendar for a task (creates the task if no open task matches). Goes into the separate \"Notch\" calendar. Give end or minutes; otherwise the task's estimate or 30 min. Reports overlaps.",
             properties: ["task": taskArg, "start": ["type": "string", "description": "Start time: 2pm, 14:00, or ISO 8601"],
                          "end": ["type": "string", "description": "End time (optional)"],
                          "minutes": ["type": "integer", "description": "Length in minutes (optional)"],
                          "date": dayArg],
             required: ["task", "start"]) { a in PlannerActions.blockTime(a) },
        Tool(name: "remove_block", description: "Take a task's time block off the calendar (the task stays).",
             properties: ["task": taskArg], required: ["task"]) { a in PlannerActions.removeBlock(a["task"] as? String ?? "") },
        Tool(name: "delete_task", description: "Permanently delete a task (and its time block; it also leaves the phone). Only when the user asks to delete or remove tasks; for finished work use complete_task.",
             properties: ["task": taskArg], required: ["task"]) { a in PlannerActions.deleteTask(a["task"] as? String ?? "") },
        Tool(name: "search", description: "Search task titles and notes, daily notes, and project plan pages.",
             properties: ["query": ["type": "string", "description": "Words to find"]], required: ["query"]) { a in PlannerActions.search(a["query"] as? String ?? "") },
        Tool(name: "read_note", description: "Read the daily note for a day (today's is the notch Notepad).",
             properties: ["date": dayArg], required: []) { a in PlannerActions.readNote(a["date"] as? String) },
    ]
}
