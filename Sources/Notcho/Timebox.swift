import EventKit
import SwiftUI

// MARK: - Engine: time blocks are events in a separate "Notch" calendar (never any other calendar)

/// Each block's event carries `notch:<task id>` in its notes, so blocks and tasks can always be matched up again.
final class Timebox {
    static let shared = Timebox()
    weak var store: Store?
    private let calendarKey = "blocks.calendarID"
    private var pending: DispatchWorkItem?
    private var es: EKEventStore? { store?.eventStore }

    static func tag(_ id: UUID) -> String { "notch:" + id.uuidString }
    static func taskID(in event: EKEvent) -> UUID? {
        guard let n = event.notes, let r = n.range(of: #"notch:[0-9A-F-]{36}"#, options: .regularExpression) else { return nil }
        return UUID(uuidString: String(n[r].dropFirst(6)))
    }

    var calendarID: String? { UserDefaults.standard.string(forKey: calendarKey) }

    /// The Notch calendar, created on first use in the default (normally iCloud) account so blocks reach the phone.
    func calendar() -> EKCalendar? {
        guard let es, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        if let id = calendarID, let c = es.calendar(withIdentifier: id) { return c }
        if let c = es.calendars(for: .event).first(where: { $0.title == "Notch" && $0.allowsContentModifications }) {
            UserDefaults.standard.set(c.calendarIdentifier, forKey: calendarKey); return c
        }
        let c = EKCalendar(for: .event, eventStore: es)
        c.title = "Notch"
        c.cgColor = NSColor(Palette.lavender).cgColor
        c.source = es.defaultCalendarForNewEvents?.source ?? es.sources.first { $0.sourceType == .calDAV }
        do { try es.saveCalendar(c, commit: true) } catch { return nil }
        UserDefaults.standard.set(c.calendarIdentifier, forKey: calendarKey)
        return c
    }

    func isBlock(_ e: EKEvent) -> Bool { e.calendar?.calendarIdentifier == calendarID }

    /// Agents run without calendar permission, so the app saves yesterday → +14 days for them.
    struct SavedEvent: Codable {
        var title: String, start: Date, end: Date, allDay: Bool, calendar: String
        var task: UUID?   // set for Notch blocks
    }
    static let exportURL = Store.fileURL.deletingLastPathComponent().appending(path: "calendar.json")
    static func exportCalendar(_ es: EKEventStore) {
        let from = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now))!
        let to = Calendar.current.date(byAdding: .day, value: 15, to: from)!
        let saved = es.events(matching: es.predicateForEvents(withStart: from, end: to, calendars: nil))
            .filter { $0.status != .canceled }
            .map { SavedEvent(title: $0.title ?? "Untitled", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                              calendar: $0.calendar.title, task: shared.isBlock($0) ? taskID(in: $0) : nil) }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        DispatchQueue.global(qos: .utility).async { try? data.write(to: exportURL, options: .atomic) }
    }

    func event(for task: TaskItem) -> EKEvent? {
        task.blockID.flatMap { es?.event(withIdentifier: $0) }
    }

    /// Puts the task on the calendar at `start` (or moves its block there). Length = its estimate, else 30 min.
    func place(_ id: UUID, at start: Date, minutes: Int? = nil) {
        guard let store, let es, let cal = calendar(), let t = store.tasks.first(where: { $0.id == id }) else { return }
        let length = minutes ?? t.timeLimit ?? 30
        let e = event(for: t) ?? EKEvent(eventStore: es)
        e.calendar = cal
        e.title = title(t)
        e.startDate = start
        e.endDate = start.addingTimeInterval(TimeInterval(length * 60))
        e.notes = Self.tag(id)
        do { try es.save(e, span: .thisEvent, commit: true) } catch { return }
        store.update(id) {
            $0.blockID = e.eventIdentifier; $0.startTime = start; $0.timeLimit = length
            if $0.someday == true || ($0.day ?? start) != Calendar.current.startOfDay(for: start) {
                $0.someday = nil; $0.day = Calendar.current.startOfDay(for: start) // a block puts the task on that day
            }
        }
    }

    func remove(_ id: UUID) {
        guard let store, let t = store.tasks.first(where: { $0.id == id }) else { return }
        if let e = event(for: t) { try? es?.remove(e, span: .thisEvent, commit: true) }
        store.update(id) { $0.blockID = nil; $0.startTime = nil }
    }

    func title(_ t: TaskItem) -> String { (t.done ? "✓ " : "") + t.title }

    func schedule() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reconcile() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    /// Keeps blocks and tasks in step: done → "✓", renamed → retitled, deleted task → block removed,
    /// block moved/resized/deleted in Calendar (Mac or phone) → task updated.
    func reconcile() {
        guard let store, let es, let cal = calendar() else { return }
        let from = Calendar.current.date(byAdding: .day, value: -14, to: .now)!, to = Calendar.current.date(byAdding: .day, value: 60, to: .now)!
        let blocks = es.events(matching: es.predicateForEvents(withStart: from, end: to, calendars: [cal]))
        var seen = Set<UUID>()
        for e in blocks {
            guard let id = Self.taskID(in: e) else { continue }
            guard let t = store.tasks.first(where: { $0.id == id }) else {
                try? es.remove(e, span: .thisEvent, commit: false); continue  // task deleted
            }
            seen.insert(id)
            if e.title != title(t) { e.title = title(t); try? es.save(e, span: .thisEvent, commit: false) }
            let minutes = Int(e.endDate.timeIntervalSince(e.startDate) / 60)
            if t.blockID != e.eventIdentifier || t.startTime != e.startDate || t.timeLimit != minutes {
                store.update(id) { $0.blockID = e.eventIdentifier; $0.startTime = e.startDate; $0.timeLimit = minutes }
            }
        }
        try? es.commit()
        // Blocks deleted in Calendar: the task stays, just unscheduled.
        for t in store.tasks where t.blockID != nil && !seen.contains(t.id) && event(for: t) == nil {
            store.update(t.id) { $0.blockID = nil; $0.startTime = nil }
        }
    }
}

// MARK: - Timeline pieces (shared by the Today column and the Calendar tab)

enum TimelineScale {
    static let firstHour = 6, lastHour = 23
    static let hourHeight: CGFloat = 52
    static var height: CGFloat { CGFloat(lastHour - firstHour + 1) * hourHeight }
}

/// Hour labels down the left edge.
struct HourLabels: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(TimelineScale.firstHour...TimelineScale.lastHour, id: \.self) { h in
                Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now)!.formatted(.dateTime.hour()))
                    .font(.footnote).foregroundStyle(Palette.pInkSoft)
                    .frame(width: 36, height: TimelineScale.hourHeight, alignment: .topTrailing)
                    .id(h)
            }
        }
    }
}

/// One day: grid lines, read-only events, Notch blocks you can move/resize, drop a task to block time.
struct DayColumn: View {
    @Bindable var store: Store
    let day: Date
    let events: [EKEvent]
    @State private var resizing: (UUID, CGFloat)?   // task, extra height while dragging the bottom edge

    var dayStart: Date { Calendar.current.startOfDay(for: day) }
    var hourHeight: CGFloat { TimelineScale.hourHeight }

    func y(_ date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(dayStart) / 3600 - Double(TimelineScale.firstHour)) * hourHeight
    }

    /// Drop point → time on this day, snapped to 15 minutes.
    func time(at y: CGFloat) -> Date {
        let minutes = (Double(y / hourHeight) + Double(TimelineScale.firstHour)) * 60
        let snapped = (minutes / 15).rounded(.down) * 15
        return dayStart.addingTimeInterval(max(Double(TimelineScale.firstHour) * 60, snapped) * 60)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(TimelineScale.firstHour...TimelineScale.lastHour, id: \.self) { _ in
                    Rectangle().fill(Palette.pWash).frame(height: 1).frame(height: hourHeight, alignment: .top)
                }
            }
            ForEach(events.filter { !$0.isAllDay }, id: \.eventIdentifier) { e in
                if Timebox.shared.isBlock(e), let id = Timebox.taskID(in: e), let t = store.tasks.first(where: { $0.id == id }) {
                    block(e, t)
                } else {
                    other(e)
                }
            }
            if Calendar.current.isDateInToday(day) { nowLine }
        }
        .frame(height: TimelineScale.height)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, point in
            guard let id = ids.compactMap(UUID.init(uuidString:)).first else { return false }
            Timebox.shared.place(id, at: time(at: point.y))
            return true
        }
    }

    var nowLine: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            HStack(spacing: 0) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Rectangle().fill(.red).frame(height: 1.5)
            }
            .offset(x: -3, y: y(ctx.date) - 3.5)
        }
        .allowsHitTesting(false)
    }

    func frame(_ e: EKEvent, extra: CGFloat = 0) -> (CGFloat, CGFloat) {
        (y(e.startDate), max(18, y(e.endDate) - y(e.startDate) + extra))
    }

    /// Someone else's event: read-only.
    func other(_ e: EKEvent) -> some View {
        let (top, h) = frame(e)
        return Text(e.title ?? "").font(.subheadline).lineLimit(h > 30 ? 2 : 1)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(cgColor: e.calendar.cgColor).opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            .frame(height: h).padding(.horizontal, 3)
            .offset(y: top)
            .help("\(e.calendar.title) · read-only")
    }

    /// A Notch block: drag to move, drag the bottom edge to resize, right-click to remove.
    func block(_ e: EKEvent, _ t: TaskItem) -> some View {
        let extra = resizing?.0 == t.id ? resizing!.1 : 0
        let (top, h) = frame(e, extra: extra)
        let color = Palette.named(store.projects.first { $0.id == t.projectID }?.color ?? "lavender")
        return VStack(alignment: .leading, spacing: 1) {
            Text(t.title).font(.subheadline.weight(.semibold)).strikethrough(t.done).lineLimit(h > 34 ? 2 : 1)
            if h > 30 {
                Text((e.startDate..<max(e.startDate, e.endDate.addingTimeInterval(Double(extra / hourHeight) * 3600))).formatted(date: .omitted, time: .shortened))
                    .font(.footnote.monospacedDigit()).opacity(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .foregroundStyle(Palette.ink) // dark text on the pastel block in both modes
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: h)
        .background(color, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottom) {
            Capsule().fill(.white.opacity(0.7)).frame(width: 24, height: 4).padding(.bottom, 2)
                .frame(maxWidth: .infinity).frame(height: 10).contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { resizing = (t.id, $0.translation.height) }
                    .onEnded { v in
                        let minutes = Int(((e.endDate.timeIntervalSince(e.startDate) / 60) + Double(v.translation.height / hourHeight) * 60) / 15) * 15
                        resizing = nil
                        Timebox.shared.place(t.id, at: e.startDate, minutes: max(15, minutes))
                    })
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        }
        .draggable(t.id.uuidString)
        .contextMenu {
            Button(t.done ? "Mark not done" : "Mark done") { store.toggle(t.id) }
            Button("Remove from calendar", role: .destructive) { Timebox.shared.remove(t.id) }
        }
        .padding(.horizontal, 3)
        .offset(y: top)
        .help("Drag to move · drag the bottom edge to resize · right-click to remove")
    }
}

struct ConnectCalendar: View {
    @Bindable var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drag tasks onto your day. Blocks go into a separate “Notch” calendar; your other calendars are only read.")
                .font(.callout).foregroundStyle(Palette.pInkSoft)
            Button("Connect Calendar") { store.connectCalendar() }.buttonStyle(Pill(fill: Palette.pInk, text: Palette.card, size: 12))
        }
        .padding(14)
    }
}

// MARK: - Today's Calendar column (collapsible)

struct DayTimeline: View {
    @Bindable var store: Store
    let collapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Calendar").font(.body.weight(.semibold))
                Spacer()
                Text(Date.now.formatted(.dateTime.weekday(.abbreviated).day())).font(.callout).foregroundStyle(Palette.pInkSoft)
                Button(action: collapse) { Image(systemName: "sidebar.trailing") }
                    .buttonStyle(.plain).foregroundStyle(Palette.pInkSoft).help("Hide the calendar")
            }
            .padding(.horizontal, 14).padding(.top, 40).padding(.bottom, 8)

            if !store.calendarAccess {
                ConnectCalendar(store: store)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        HStack(alignment: .top, spacing: 4) {
                            HourLabels()
                            DayColumn(store: store, day: .now, events: store.events)
                        }
                        .padding(.trailing, 8)
                    }
                    .onAppear { proxy.scrollTo(max(TimelineScale.firstHour, Calendar.current.component(.hour, from: .now) - 1), anchor: .top) }
                }
            }
        }
        .background(Palette.card.opacity(0.45))
    }
}

// MARK: - Calendar tab: the week, plus tasks to drag onto it

struct WeekCalendar: View {
    @Bindable var store: Store
    @State private var weekStart = WeekCalendar.monday(of: .now)
    @State private var events: [EKEvent] = []

    static func monday(of day: Date) -> Date { date(fromDayKey: weekKey(day))! }
    var days: [Date] { (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: weekStart)! } }

    /// Open tasks without a block yet: today's first, then upcoming, then someday.
    var toSchedule: [TaskItem] {
        (store.todo + store.upcoming + store.someday).filter { $0.blockID == nil }
    }

    func load() {
        guard store.calendarAccess else { events = []; return }
        let end = Calendar.current.date(byAdding: .day, value: 7, to: weekStart)!
        events = store.eventStore.events(matching: store.eventStore.predicateForEvents(withStart: weekStart, end: end, calendars: nil))
            .filter { $0.status != .canceled }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("To schedule").font(.body.weight(.semibold)).padding(.top, 40)
                Text("Drag onto a day.").font(.subheadline).foregroundStyle(Palette.pInkSoft)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(toSchedule) { t in
                            HStack(spacing: 6) {
                                if let p = store.projects.first(where: { $0.id == t.projectID }) {
                                    Circle().fill(Palette.named(p.color)).frame(width: 7, height: 7)
                                }
                                Text(t.title).font(.callout).lineLimit(2)
                                Spacer(minLength: 0)
                                if let m = t.timeLimit { Text(estimate(m)).font(.footnote.monospacedDigit()).foregroundStyle(Palette.pInkSoft) }
                            }
                            .padding(8).background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
                            .draggable(t.id.uuidString)
                        }
                        if toSchedule.isEmpty { Text("Everything open is scheduled.").font(.callout).foregroundStyle(Palette.pInkSoft) }
                    }
                }
            }
            .frame(width: 200).padding(.horizontal, 14)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(weekStart.formatted(.dateTime.month(.wide).year())).font(.title.weight(.bold))
                    Spacer()
                    Button { weekStart = Calendar.current.date(byAdding: .day, value: -7, to: weekStart)! } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(Pill(fill: Palette.pWash))
                    Button("This week") { weekStart = Self.monday(of: .now) }.buttonStyle(Pill(fill: Palette.pWash))
                    Button { weekStart = Calendar.current.date(byAdding: .day, value: 7, to: weekStart)! } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(Pill(fill: Palette.pWash))
                }
                .padding(.horizontal, 20).padding(.top, 36).padding(.bottom, 10)

                if !store.calendarAccess {
                    ConnectCalendar(store: store); Spacer()
                } else {
                    HStack(spacing: 0) {
                        Spacer().frame(width: 40)
                        ForEach(days, id: \.self) { d in
                            VStack(spacing: 1) {
                                Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.subheadline).foregroundStyle(Palette.pInkSoft)
                                Text(d.formatted(.dateTime.day())).font(.title3.weight(Calendar.current.isDateInToday(d) ? .bold : .regular))
                                    .foregroundStyle(Calendar.current.isDateInToday(d) ? Tone.alert : Palette.pInk)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.bottom, 6)
                    ScrollViewReader { proxy in
                        ScrollView {
                            HStack(alignment: .top, spacing: 4) {
                                HourLabels()
                                ForEach(days, id: \.self) { d in
                                    DayColumn(store: store, day: d, events: events.filter { Calendar.current.isDate($0.startDate, inSameDayAs: d) })
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.trailing, 10)
                        }
                        .onAppear { proxy.scrollTo(8, anchor: .top) }
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: weekStart) { load() }
        .onChange(of: store.events) { load() } // reloads whenever Calendar changes
    }
}
