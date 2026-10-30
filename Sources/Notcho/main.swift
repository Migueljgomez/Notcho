// Notcho: a day planner that lives in the MacBook notch.
import AppKit
import EventKit
import SwiftUI

// MARK: - Layout (pure, so it can be self-checked)

enum NotchLayout {
    /// Camera housing: the gap between the two auxiliary top areas. Nil on screens without a notch.
    static func notchRect(screen: CGRect, left: CGRect?, right: CGRect?, menuBarHeight: CGFloat) -> CGRect? {
        guard let left, let right, right.minX > left.maxX else { return nil }
        return CGRect(x: left.maxX, y: screen.maxY - menuBarHeight, width: right.minX - left.maxX, height: menuBarHeight)
    }

    /// Expanded workspace hanging from the top edge, centred; never wider than the screen minus 32.
    static func workspaceFrame(screen: CGRect, height: CGFloat = Metrics.panelHeight, width: CGFloat = Metrics.panelWidth) -> CGRect {
        let w = min(max(screen.width - 32, 0), width)
        let h = min(height, max(screen.height - 32, 0))
        return CGRect(x: screen.midX - w / 2, y: screen.maxY - h, width: w, height: h)
    }

    /// Timer capsule 6 pt right of the notch, vertically centred in the menu bar.
    static func pillFrame(notch: CGRect, size: CGSize = CGSize(width: 90, height: 30)) -> CGRect {
        let h = min(size.height, notch.height - 4)
        return CGRect(x: notch.maxX + 6, y: notch.midY - h / 2, width: size.width, height: h)
    }
}

// MARK: - Panel

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }  // needed for typing; .nonactivatingPanel keeps your current app active
    override var canBecomeMain: Bool { false }
}

final class NotchController {
    let model = NotchModel()
    let store = Store()
    let panel = NotchPanel(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
    var notch = CGRect.zero, workspace = CGRect.zero, pill = CGRect.zero
    var monitors: [Any] = []
    var collapseTask: Task<Void, Never>?
    var suppressUntilExit = false  // after ✕, don't reopen until the pointer leaves
    var menuOpen = false
    var pinned = false             // opened by the shortcut: stays open until click-outside, Esc, ✕ or hover-out
    var appliedHeight = 0.0        // the settings height the window was last sized for
    var appliedWidth = 0.0

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        model.setHeight = { [weak self] h in
            guard let self, let screen = panel.screen ?? NSScreen.main else { return }
            store.settings.panelHeight = Double(min(max(h, 240), screen.frame.height - 120))
            layout()
        }
        model.setWidth = { [weak self] w in
            guard let self, let screen = panel.screen ?? NSScreen.main else { return }
            let lo = Metrics.minWidth(cards: store.settings.visibleCards.count)
            store.settings.panelWidth = Double(min(max(w, lo), max(screen.frame.width - 32, lo)))
            layout()
        }
        model.applyLook = { [weak self] in
            guard let self else { return }
            let look = store.settings.notchLook
            Tone.lightLook = look == .light || look == .system
            panel.appearance = NSAppearance(named: .darkAqua) // a change makes the panel re-resolve its colors
            panel.appearance = switch look {
            case .light, .pastel: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            case .system: nil // follows the Mac
            }
        }
        model.applyLook()
        // Increase Contrast swaps Tone colors; re-setting the appearance makes the panel resolve them again.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.panel.appearance = NSAppearance(named: .aqua); self?.panel.appearance = nil; self?.model.applyLook()
        }
        panel.contentView = NSHostingView(rootView: RootView(model: model, store: store) { [weak self] in self?.closeButton() })

        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in self?.trackPointer() } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] e in self?.trackPointer(); return e } as Any)
        // A click anywhere outside the panel closes it.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.model.expanded == true { self?.setExpanded(false) }
        } as Any)

        // Esc closes the panel.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53, self?.model.expanded == true else { return e }
            self?.setExpanded(false)
            return nil
        } as Any)

        _ = NotchCommand.linkKey // create the key now, before any command needs it

        // Apple Reminders sync: any task change, any Reminders change (e.g. from the iPhone), and once a minute.
        if !FileManager.default.fileExists(atPath: Store.fileURL.path(percentEncoded: false)) { store.saveNow() } // one-time move off UserDefaults
        RemindersSync.shared.store = store
        PlannerWindow.shared.store = store
        DailyNotes.shared.start(store)
        ReminderService.shared.paused = store.settings.syncReminders
        store.onTasksChanged = { RemindersSync.shared.schedule(); Timebox.shared.schedule() }
        Timebox.shared.store = store
        HotKey.handler = { [weak self] in self?.toggleFromShortcut() }
        HotKey.register(store.settings.shortcut)
        HotKey.registerPlanner { PlannerWindow.shared.show() } // ⌥⇧N

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.layout() }
        nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuOpen = true }
        nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuOpen = false
            self?.trackPointer()
        }
        nc.addObserver(forName: .EKEventStoreChanged, object: store.eventStore, queue: .main) { [weak self] _ in
            self?.store.loadEvents()
            RemindersSync.shared.schedule()
            Timebox.shared.schedule() // blocks moved or deleted in Calendar (Mac or phone)
        }

        // 1 s tick: finish the focus timer; reload events each minute.
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if store.tick() && store.settings.completionSound { NSSound(named: "Glass")?.play() }
            ticks += 1
            if ticks % 60 == 0 { minuteChores() }
            trackPointer() // pill appears/disappears with the timer state
        }

        // Clicking a reminder notification opens the panel (pinned, like the shortcut).
        ReminderService.shared.setUp()
        ReminderService.shared.onOpen = { [weak self] in
            guard let self, !model.expanded else { return }
            toggleFromShortcut()
        }
        ReminderService.shared.onWrapUp = { PlannerWindow.shared.show(wrapUp: true) }

        minuteChores()
        layout()
    }

    /// Calendar refresh, new-day rollover of unfinished tasks, notification permission status.
    func minuteChores() {
        store.loadEvents()
        store.rollover()
        RemindersSync.shared.schedule()
        checkBreak()
        DailyNotes.shared.tick()
        checkWrapUp()
        ReminderService.shared.status { [weak self] in self?.store.notificationsOn = ($0 == .authorized || $0 == .provisional) }
    }

    /// Once per streak: after `breakAfterMinutes` of unbroken focus, suggest a break.
    private var nudgedStreak = false
    func checkBreak() {
        let limit = store.settings.breakAfterMinutes
        let streak = store.currentStreak
        if streak == 0 { nudgedStreak = false; store.breakSuggested = false; return }
        guard limit > 0, !nudgedStreak, streak >= TimeInterval(limit * 60) else { return }
        nudgedStreak = true
        store.breakSuggested = true
        ReminderService.shared.notifyNow("Ready for a break?", "You've focused for \(durationText(streak)). Stretch, water, eyes off the screen.")
    }

    /// Once a day at "Daily wrap-up at": a banner that opens the wrap-up sheet.
    func checkWrapUp() {
        let hour = store.settings.wrapUpHour, today = isoDay(of: store.today), key = "wrapup.notified"
        guard hour > 0, Calendar.current.component(.hour, from: .now) >= hour,
              UserDefaults.standard.string(forKey: key) != today else { return }
        UserDefaults.standard.set(today, forKey: key)
        ReminderService.shared.notifyNow("Wrap up your day", "Review what got done and move what didn't.", id: "wrapup")
    }

    func layout() {
        // Prefer the screen with a notch (non-zero top safe area), else the main screen.
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        notch = NotchLayout.notchRect(screen: screen.frame, left: screen.auxiliaryTopLeftArea,
                                      right: screen.auxiliaryTopRightArea, menuBarHeight: menuBar)
            ?? CGRect(x: screen.frame.midX - 100, y: screen.frame.maxY - 24, width: 200, height: 24)
        appliedHeight = store.settings.panelHeight
        appliedWidth = store.settings.panelWidth
        workspace = NotchLayout.workspaceFrame(screen: screen.frame, height: CGFloat(appliedHeight), width: CGFloat(appliedWidth))
        pill = NotchLayout.pillFrame(notch: notch)
        model.collapsed = notch.size
        model.workspace = workspace.size
        model.notchOffsetX = notch.midX - workspace.midX
        model.pill = CGRect(x: pill.minX - workspace.minX, y: workspace.maxY - pill.maxY, width: pill.width, height: pill.height)
        // The window stays at the expanded size; SwiftUI draws the visible shape inside it.
        panel.setFrame(workspace, display: true)
        panel.orderFrontRegardless()
        trackPointer()
    }

    /// What the pointer can hit right now, in screen coordinates.
    var surfaces: [CGRect] {
        if model.expanded { return [workspace] }
        return store.focusState == .ready ? [notch] : [notch, pill]
    }

    func trackPointer() {
        let p = NSEvent.mouseLocation
        let inside = surfaces.contains { $0.contains(p) }
        panel.ignoresMouseEvents = !inside && !model.dragging  // clicks outside the shape fall through to apps below
        if !inside { suppressUntilExit = false }
        // The timer pill takes clicks (pause/resume) but doesn't open the notch; only the notch itself does.
        let opens = model.expanded ? inside : notch.contains(p)
        setHover(opens && !suppressUntilExit)
    }

    func setHover(_ inside: Bool) {
        collapseTask?.cancel()
        if inside {
            pinned = false // the pointer is here now, so normal hover rules take over
            if !model.expanded { setExpanded(true) }
        } else if pinned || store.settings.closeAfter >= Settings.stayOpen {
            return
        } else if model.expanded && !model.editing && !model.dragging && !menuOpen && panel.childWindows?.isEmpty != false {
            // menus and popovers (child windows) keep it open
            collapseTask = Task { @MainActor [weak self] in
                // at least 60 ms, to ignore edge jitter; longer if the person chose a slower close
                try? await Task.sleep(for: .milliseconds(max(60, Int((self?.store.settings.closeAfter ?? 0) * 1000))))
                guard !Task.isCancelled else { return }
                self?.setExpanded(false)
            }
        }
    }

    func toggleFromShortcut() {
        if model.expanded { setExpanded(false); return }
        pinned = true
        setExpanded(true)
        panel.makeKey() // so you can type straight away
    }

    func closeButton() {
        suppressUntilExit = true
        setExpanded(false)
    }

    func setExpanded(_ value: Bool) {
        if value && (store.settings.panelHeight != appliedHeight || store.settings.panelWidth != appliedWidth) { layout() } // changed in the Planner
        if !value { panel.makeFirstResponder(nil); model.editing = false; pinned = false }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let anim: Animation? = reduceMotion ? nil : .spring(response: value ? 0.38 : 0.3, dampingFraction: 1.0)
        withAnimation(anim) { model.expanded = value }
        let p = NSEvent.mouseLocation
        panel.ignoresMouseEvents = !surfaces.contains { $0.contains(p) }
    }
}

// MARK: - Entry

if CommandLine.arguments.contains("--selftest") {
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let n = NotchLayout.notchRect(screen: screen, left: CGRect(x: 0, y: 1085, width: 764, height: 32),
                                  right: CGRect(x: 964, y: 1085, width: 764, height: 32), menuBarHeight: 32)!
    precondition(n == CGRect(x: 764, y: 1085, width: 200, height: 32))
    precondition(NotchLayout.notchRect(screen: screen, left: nil, right: nil, menuBarHeight: 24) == nil)
    let w = NotchLayout.workspaceFrame(screen: screen)
    precondition(w.width == Metrics.panelWidth && w.midX == screen.midX && w.maxY == screen.maxY)
    precondition(NotchLayout.workspaceFrame(screen: CGRect(x: 0, y: 0, width: 400, height: 300)).width == 368)
    let narrow = NotchLayout.workspaceFrame(screen: screen, width: 700)
    precondition(narrow.width == 700 && narrow.midX == screen.midX) // resized panels stay centred under the notch
    precondition(Metrics.minWidth(cards: 4) == 640 && Metrics.minWidth(cards: 1) == 184) // 4×140 + 3×12 gaps + 2×22 sides
    let p = NotchLayout.pillFrame(notch: n)
    precondition(p.minX == n.maxX + 6 && p.midY == n.midY && p.height == 28)
    precondition(clock(1500) == "25:00" && clock(59.2) == "01:00" && clock(0) == "00:00")
    precondition(wordCount("  the bee\nflies anyway ") == 4 && wordCount("") == 0)
    precondition(DotMatrix.glyphs.values.allSatisfy { $0.count == 7 && Set($0.map(\.count)).count == 1 })
    let (a, b, c, d) = (TaskItem(title: "a"), TaskItem(title: "b", completedAt: .now), TaskItem(title: "c"), TaskItem(title: "d"))
    precondition(Store.reslot([a, b, c, d], order: [d.id, a.id, c.id]).map(\.title) == ["d", "b", "a", "c"]) // done task b keeps its slot

    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let tue = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!   // a Tuesday
    let mon = cal.date(byAdding: .day, value: -1, to: tue)!
    let tasks = [TaskItem(title: "done mon", completedAt: mon, createdAt: mon),
                 TaskItem(title: "open", createdAt: mon),
                 TaskItem(title: "done tue", completedAt: tue, createdAt: tue)]
    let s = Insights.compute(tasks: tasks, focusLog: [FocusEntry(date: mon, seconds: 1500)], now: tue, calendar: cal)
    precondition(s.days.count == 7 && s.days.last!.completed == 1 && s.days.last!.planned == 2 && s.days[5].planned == 2)
    precondition(s.completed == 2 && s.planned == 3 && s.focusSeconds == 1500 && s.activeDays == 2)
    precondition(s.streak == 2) // Tue + Mon; weekend skipped, Fri breaks it
    precondition(Insights.compute(tasks: tasks, focusLog: [], now: tue, calendar: cal, weekendsInStreak: true).streak == 2)
    precondition(durationText(3000) == "50m" && durationText(4800) == "1h 20m" && durationText(7200) == "2h")
    precondition(Insights.compute(tasks: tasks, focusLog: [], now: tue, calendar: cal, dayStartHour: 13).days.last!.date == cal.startOfDay(for: mon)) // Tue 12:00 still counts as Monday
    precondition(planDay(tue, startHour: 13, calendar: cal) == cal.startOfDay(for: mon))

    var st = Settings()
    st.move(.tasks, onto: .notepad)
    precondition(st.orderedCards == [.focus, .notepad, .tasks, .events])
    st.move(.events, onto: .focus)
    precondition(st.orderedCards == [.events, .focus, .notepad, .tasks])
    st.cardOrder = [.notepad]   // older save missing kinds → appended
    precondition(st.orderedCards == [.notepad, .tasks, .focus, .events])
    let old = try! JSONDecoder().decode(Settings.self, from: Data(#"{"stopwatch":true}"#.utf8))
    precondition(old.stopwatch && old.shortcut == .optN && old.completionSound) // missing fields → defaults

    // Planner fields: a pre-Phase-4 task still loads, and the new fields round-trip.
    let legacy = try! JSONDecoder().decode(TaskItem.self, from: Data(#"{"id":"6BA007C0-92F0-4E89-B469-DC3322651B4F","title":"old"}"#.utf8))
    precondition(legacy.title == "old" && legacy.projectID == nil && legacy.subtasks == nil && legacy.notes == nil)
    var rich = TaskItem(title: "plan", projectID: UUID(), due: Date(timeIntervalSinceReferenceDate: 815_000_000), startTime: Date(timeIntervalSinceReferenceDate: 815_000_000), notes: "context", subtasks: [Subtask(title: "a")])
    rich.subtasks![0].done = true
    precondition(try! JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(rich)) == rich)
    precondition(Project(name: "Work").color == "sage")

    // Break streak: stretches less than 10 min apart join up; a 10+ min gap resets.
    let t0 = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
    let log = [FocusEntry(date: t0.addingTimeInterval(-1800), seconds: 1500),  // 11:05–11:30
               FocusEntry(date: t0, seconds: 1500)]                             // 11:35–12:00 (5-min gap)
    precondition(Store.focusStreak(log: log, live: 300, now: t0.addingTimeInterval(600)) == 300 + 3000) // live joins after a 5-min pause
    precondition(Store.focusStreak(log: log, live: 0, now: t0.addingTimeInterval(1200)) == 0)          // 20-min break → reset
    precondition(Store.focusStreak(log: log, live: 0, now: t0.addingTimeInterval(120)) == 3000)        // 2-min pause → still on
    // Weeks start Monday: Wed Oct 28 and Sun Nov 1 are both in the week of Mon Oct 26.
    precondition(weekKey(t0) == "2026-10-26" && weekKey(t0.addingTimeInterval(4 * 86400)) == "2026-10-26")
    precondition(weekKey(t0.addingTimeInterval(5 * 86400)) == "2026-11-02")
    let legacyTask = try! JSONDecoder().decode(TaskItem.self, from: Data(#"{"title":"x","id":"6BA007C0-92F0-4E89-B469-DC3322651B4F"}"#.utf8))
    precondition(legacyTask.objectiveID == nil)

    // Time blocks find their task from the event's notes tag.
    let tagged = EKEvent(eventStore: EKEventStore())
    let blockTask = UUID()
    tagged.notes = "Planned in Notch\n" + Timebox.tag(blockTask)
    precondition(Timebox.taskID(in: tagged) == blockTask)
    tagged.notes = "no tag"; precondition(Timebox.taskID(in: tagged) == nil)

    // Agents: day words, clock times on a day, the edit link, and task patching. Local time, like the app.
    let lc = Calendar.current, wed = lc.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
    precondition(PlannerActions.parseDay("today", now: wed) == "2026-10-28" && PlannerActions.parseDay("tomorrow", now: wed) == "2026-10-29")
    precondition(PlannerActions.parseDay("friday", now: wed) == "2026-10-30" && PlannerActions.parseDay("wed", now: wed) == "2026-10-28")
    precondition(PlannerActions.parseDay("next week", now: wed) == "2026-11-02" && PlannerActions.parseDay("in 3 days", now: wed) == "2026-10-31")
    precondition(PlannerActions.parseDay("someday", now: wed) == "someday" && PlannerActions.parseDay("2026-12-01", now: wed) == "2026-12-01")
    precondition(PlannerActions.parseDay("blursday", now: wed) == nil)
    let fri2pm = lc.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 14))!
    precondition(PlannerActions.parseClock("2pm", on: "friday", now: wed) == fri2pm)
    precondition(PlannerActions.parseClock("9am", on: nil, now: wed) == lc.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 9))!) // passed, still today
    let editLink = NotchCommand.edit(op: "task.update", fields: ["id": UUID().uuidString, "notes": "a & b = c"])
    precondition(NotchCommand.parse(editLink.url(key: "k"), key: "k") == editLink)
    precondition(NotchCommand.parse(editLink.url(key: "wrong"), key: "k") == nil) // edits need the key
    var patched = TaskItem(title: "p", notes: "old")
    let projID = UUID()
    Store.patch(&patched, ["project": projID.uuidString, "due": "2026-11-03", "day": "someday", "estimate": "45", "notes_append": "new"])
    precondition(patched.projectID == projID && patched.due == date(fromDayKey: "2026-11-03") && patched.someday == true && patched.timeLimit == 45 && patched.notes == "old\n\nnew")
    Store.patch(&patched, ["project": "none", "due": "none", "day": "2026-10-29"])
    var subbed = TaskItem(title: "Subtasks")
    Store.patch(&subbed, ["sub_add": "Sketch\nBuild\nShip"])
    Store.patch(&subbed, ["sub_check": "1\nbuild", "sub_remove": "Ship"])
    precondition(subbed.subtasks?.map(\.title) == ["Sketch", "Build"] && subbed.subtasks?.allSatisfy(\.done) == true)
    Store.patch(&subbed, ["sub_remove": "1\n2"])
    precondition(subbed.subtasks == nil)
    precondition(patched.projectID == nil && patched.due == nil && patched.someday == nil && patched.day == date(fromDayKey: "2026-10-29"))

    // Note and plan file names.
    precondition(NoteFiles.noteURL(t0).lastPathComponent == "2026-10-28.md")
    precondition(NoteFiles.planURL(Project(name: "Eye for Design / Site: v2")).lastPathComponent == "Eye for Design - Site- v2.md")

    // Time by project: logged focus is grouped by the task's project.
    let proj = UUID(), tA = TaskItem(title: "a", projectID: proj), tB = TaskItem(title: "b")
    let byProject = Insights.timeByProject(tasks: [tA, tB], focusLog: [FocusEntry(date: t0, seconds: 600, taskID: tA.id),
        FocusEntry(date: t0, seconds: 300, taskID: tA.id), FocusEntry(date: t0, seconds: 120, taskID: tB.id),
        FocusEntry(date: t0.addingTimeInterval(-30 * 86400), seconds: 999, taskID: tA.id)], since: t0.addingTimeInterval(-86400))
    precondition(byProject.count == 2 && byProject[0].0 == proj && byProject[0].1 == 900 && byProject[1].0 == nil && byProject[1].1 == 120)
    precondition(Store.focusStreak(log: log, live: 300, now: t0.addingTimeInterval(300)) == 300 + 1500 + 1500) // live joins, 5-min gaps
    precondition(Store.focusStreak(log: log, live: 0, now: t0.addingTimeInterval(1200)) == 0)                  // 20 min break → reset
    precondition(Store.focusStreak(log: log, live: 0, now: t0.addingTimeInterval(120)) == 3000)                // 2 min pause → still on

    // Unfinished tasks: from an earlier day, not done/dismissed/moved ahead.
    let today = Calendar.current.startOfDay(for: .now)
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
    precondition(TaskItem(title: "old", createdAt: yesterday).isStale(today: today, startHour: 0))
    precondition(!TaskItem(title: "new", createdAt: .now).isStale(today: today, startHour: 0))
    precondition(!TaskItem(title: "done", completedAt: .now, createdAt: yesterday).isStale(today: today, startHour: 0))
    precondition(!TaskItem(title: "left", createdAt: yesterday, dismissedAt: today).isStale(today: today, startHour: 0))
    precondition(!TaskItem(title: "later", day: tomorrow, createdAt: yesterday).isStale(today: today, startHour: 0))
    precondition(!TaskItem(title: "carried", day: today, createdAt: yesterday).isStale(today: today, startHour: 0))
    precondition(!TaskItem(title: "parked", createdAt: yesterday, someday: true).isStale(today: today, startHour: 0)) // Someday never nags

    // ⌘↩ in the notepad
    let (line, rest) = takeLine("first\n  buy milk \nlast", at: 8)!
    precondition(line == "buy milk" && rest == "first\nlast")
    precondition(takeLine("a\n\nb", at: 2) == nil)
    precondition(takeLine("only", at: 99)! == ("only", ""))

    // notch:// links and times
    let noon = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!
    precondition(parseTime("30m", now: noon, calendar: cal) == noon.addingTimeInterval(1800))
    precondition(parseTime("in 1h30m", now: noon, calendar: cal) == noon.addingTimeInterval(5400))
    precondition(parseTime("5pm", now: noon, calendar: cal) == noon.addingTimeInterval(5 * 3600))
    precondition(parseTime("17:30", now: noon, calendar: cal) == noon.addingTimeInterval(5.5 * 3600))
    precondition(parseTime("9am", now: noon, calendar: cal) == noon.addingTimeInterval(21 * 3600)) // passed → tomorrow
    precondition(parseTime("13pm", now: noon, calendar: cal) == nil && parseTime("soon", now: noon, calendar: cal) == nil)
    let sent = NotchCommand.add(title: "Call dad & mom", remind: noon, limit: 25)
    precondition(NotchCommand.parse(sent.url()) == sent)                       // round-trips, & survives encoding
    precondition(NotchCommand.parse(NotchCommand.note("hi there").url()) == .note("hi there"))
    precondition(NotchCommand.parse(URL(string: "notch://add?title=%20")!) == nil)      // blank title rejected
    precondition(NotchCommand.parse(URL(string: "notch://delete?id=1")!) == nil)        // add-only
    // keyed links: change commands need the key; adds don't
    let tid = UUID()
    for cmd in [NotchCommand.complete(tid), .remind(tid, noon), .remind(tid, nil), .tomorrow(tid)] {
        precondition(NotchCommand.parse(cmd.url(key: "k1"), key: "k1") == cmd)
        precondition(NotchCommand.parse(cmd.url(key: "wrong"), key: "k1") == nil)
    }
    precondition(NotchCommand.parse(URL(string: "notch://done?id=\(tid.uuidString)")!, key: "k1") == nil)

    // task lookup
    let pool = [TaskItem(title: "Call dad"), TaskItem(title: "Call the bank"), TaskItem(title: "Write post", completedAt: .now)]
    precondition((try? findTask(pool[0].shortID, in: pool).get()) == pool[0])
    precondition((try? findTask("call DAD", in: pool).get()) == pool[0])
    precondition((try? findTask("bank", in: pool).get()) == pool[1])
    precondition((try? findTask("call", in: pool).get()) == nil)          // ambiguous
    precondition((try? findTask("post", in: pool).get()) == nil)          // done tasks only match by id

    // MCP protocol
    let initReply = MCP.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])!
    precondition(((initReply["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String == "notch")
    let listReply = MCP.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])!
    precondition(((listReply["result"] as? [String: Any])?["tools"] as? [Any])?.count == MCP.coreTools.count + MCP.plannerTools.count && MCP.tools.count == 22)
    precondition(MCP.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    precondition(MCP.handle(["jsonrpc": "2.0", "id": 3, "method": "nope"])?["error"] != nil)
    precondition(JSONSerialization.isValidJSONObject(listReply))
    var cliArgs = ["Call", "dad", "--remind", "5pm"]
    precondition(CLI.take("--remind", from: &cliArgs) == "5pm" && cliArgs == ["Call", "dad"])

    // Apple Reminders sync decisions (saved = fingerprint at last sync)
    precondition(SyncPlan.decide(saved: nil, notch: "a", phone: nil) == .createPhone)       // new task
    precondition(SyncPlan.decide(saved: "a", notch: "a", phone: "a") == .none)
    precondition(SyncPlan.decide(saved: "a", notch: "b", phone: "a") == .push)              // edited on Mac
    precondition(SyncPlan.decide(saved: "a", notch: "a", phone: "c") == .pull)              // edited on phone
    precondition(SyncPlan.decide(saved: "a", notch: "b", phone: "c") == .push)              // both: notch wins
    precondition(SyncPlan.decide(saved: "a", notch: "a", phone: nil) == .deleteNotch)       // deleted on phone
    precondition(SyncPlan.decide(saved: "a", notch: "b", phone: nil) == .createPhone)       // …but edited here since
    precondition(SyncPlan.decide(saved: "a", notch: nil, phone: "a") == .deletePhone)       // deleted / left on Mac
    precondition(SyncPlan.decide(saved: nil, notch: nil, phone: "p") == .createNotch)       // added on phone
    precondition(SyncPlan.decide(saved: nil, notch: nil, phone: "p", phoneCompleted: true) == .none)
    var st5 = TaskItem(title: "Ship it", day: cal.startOfDay(for: tue))
    precondition(SyncFields(task: st5).dayKey != nil && SyncFields(task: st5).alarm == nil)
    st5.reminder = noon                                                                     // a time wins over a plain day
    precondition(SyncFields(task: st5).dayKey == nil && SyncFields(task: st5).alarm == noon)
    precondition(SyncFields(task: st5).fingerprint != SyncFields(task: TaskItem(title: "Ship it")).fingerprint)
    precondition(date(fromDayKey: isoDay(of: noon, calendar: cal), calendar: cal) == cal.startOfDay(for: noon))
    // Workspace layout: frames fill the row; resizing keeps both cards above the minimum
    let fr = cardFrames([1, 1, 2], width: 424, gap: 12)
    precondition(fr[0] == (0, 100) && fr[1] == (112, 100) && fr[2] == (224, 200))
    var lay = Settings()
    lay.resize(.tasks, .focus, from: (0.36, 0.19), by: 1000, perPoint: 0.001, minWidth: 140)
    precondition(abs(lay.weight(.focus) - 0.14) < 1e-9 && abs(lay.weight(.tasks) - 0.41) < 1e-9)
    lay.panelHeight = 500; lay.resetLayout()
    precondition(lay.cardWeights.isEmpty && lay.panelHeight == Double(Metrics.panelHeight))
    print("selftest ok")
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "cli" {
    exit(CLI.run(Array(CommandLine.arguments.dropFirst(2))))
}

/// Receives notch:// links (from the `notch` command, Shortcuts, scripts…).
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = NotchController()
    func applicationWillTerminate(_ notification: Notification) {
        controller.store.saveNow()
        NoteFiles.flush()
        Store.flushWrites()
    }
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    /// The tilted nacho chip (same shape as Logo/menubar-chip.svg), one color so macOS tints it for light and dark.
    static func chipIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let s = 18.0 / 100, a = -11.0 * .pi / 180
            func pt(_ x: Double, _ y: Double) -> CGPoint {
                let dx = x - 50, dy = y - 50
                return CGPoint(x: (50 + dx * cos(a) - dy * sin(a)) * s, y: (50 + dx * sin(a) + dy * cos(a)) * s)
            }
            let p = [pt(12, 20), pt(88, 20), pt(50, 86)], r = 11 * s
            let path = CGMutablePath()
            path.move(to: CGPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2))
            for i in 1...3 { path.addArc(tangent1End: p[i % 3], tangent2End: p[(i + 1) % 3], radius: r) }
            path.closeSubpath()
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(path); ctx.setFillColor(.black); ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Notcho"
        return image
    }

    /// Menu bar icon: open the notch or the Planner, or quit the app.
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = Self.chipIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Notcho", action: #selector(openNotch), keyEquivalent: "").target = self
        let planner = menu.addItem(withTitle: "Open Planner", action: #selector(openPlanner), keyEquivalent: "n")
        planner.keyEquivalentModifierMask = [.option, .shift]
        planner.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notcho", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        NSApp.mainMenu = mainMenu()
    }

    /// Shown while the Planner is open; also what makes ⌘C/⌘V/⌘Z/⌘W work in its text fields.
    func mainMenu() -> NSMenu {
        let bar = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector, String)]) {
            let m = NSMenu(title: title)
            for (t, a, k) in items { m.addItem(withTitle: t, action: a, keyEquivalent: k) }
            bar.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = m
        }
        submenu("Notcho", [("Quit Notcho", #selector(NSApplication.terminate(_:)), "q")])
        submenu("Edit", [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
                         ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                         ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")])
        submenu("Window", [("Close", #selector(NSWindow.performClose(_:)), "w"), ("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")])
        return bar
    }

    @objc func openPlanner() { PlannerWindow.shared.show() }

    /// Clicking the app in Launchpad or Finder while it's running opens the Planner.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PlannerWindow.shared.show()
        return false
    }

    @objc func openNotch() { if !controller.model.expanded { controller.toggleFromShortcut() } }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { if let command = NotchCommand.parse(url) { controller.store.apply(command) } }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu-bar style, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
