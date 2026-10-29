import AppKit
import SwiftUI

// MARK: - Window: built when opened, thrown away when closed, so the notch pays nothing while it's shut

/// Lets the notch and menus steer the Planner (open the Plan your day sheet, later: jump to a task).
@Observable final class PlannerRouter {
    static let shared = PlannerRouter()
    var planning = false
    var wrapUp = false
    var focusTask: UUID?   // "Open in Planner" from the notch
}

final class PlannerWindow: NSObject, NSWindowDelegate {
    static let shared = PlannerWindow()
    weak var store: Store?
    private var window: NSWindow?

    func show(planning: Bool = false, wrapUp: Bool = false, task: UUID? = nil) {
        guard let store else { return }
        if planning { PlannerRouter.shared.planning = true }
        if wrapUp { PlannerRouter.shared.wrapUp = true }
        if let task { PlannerRouter.shared.focusTask = task }
        NSApp.setActivationPolicy(.regular) // Dock icon + ⌘Tab while the Planner is open
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Planner"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 860, height: 520)
            w.contentViewController = NSHostingController(rootView: PlannerView(store: store))
            w.delegate = self
            if !w.setFrameUsingName("Planner") { w.center() }
            w.setFrameAutosaveName("Planner")
            window = w
        }
        applyAppearance()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Light unless the user turned on dark mode for the Planner (never follows the system, so nothing flips unexpectedly).
    func applyAppearance() {
        window?.appearance = NSAppearance(named: store?.settings.plannerDark == true ? .darkAqua : .aqua)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil // drops the whole view tree
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Look

extension Palette {
    static let rose = Color(red: 0.82, green: 0.60, blue: 0.62)
    static let sand = Color(red: 0.80, green: 0.71, blue: 0.56)
    // Planner colors follow the Planner window's light/dark setting; the notch keeps its own fixed colors
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
    static let cream = dyn(NSColor(red: 0.965, green: 0.955, blue: 0.93, alpha: 1), NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1))
    static let sidebar = dyn(NSColor(red: 0.935, green: 0.925, blue: 0.895, alpha: 1), NSColor(red: 0.145, green: 0.145, blue: 0.155, alpha: 1))
    static let card = dyn(.white, NSColor(red: 0.19, green: 0.19, blue: 0.2, alpha: 1))
    static let pInk = dyn(.black.withAlphaComponent(0.82), .white.withAlphaComponent(0.88))
    static let pInkSoft = dyn(.black.withAlphaComponent(0.5), .white.withAlphaComponent(0.55))
    static let pWash = dyn(.black.withAlphaComponent(0.07), .white.withAlphaComponent(0.1))
    static func named(_ name: String) -> Color {
        switch name {
        case "lavender": lavender
        case "olive": olive
        case "blue": blue
        case "rose": rose
        case "sand": sand
        default: sage
        }
    }
}

enum PlannerSection: Hashable {
    case today, upcoming, someday, done, goals, notes, calendar, workspace, project(UUID)
}

// MARK: - Root: sidebar | list | detail

struct PlannerView: View {
    @Bindable var store: Store
    @State private var section = PlannerSection.today
    @State private var selected: UUID?
    @State private var showCalendar = true   // Today's calendar column; opens again each time you go to Today
    @Bindable private var router = PlannerRouter.shared
    private static let plannedKey = "planner.plannedDay"

    var body: some View {
        HStack(spacing: 0) {
            PlannerSidebar(store: store, section: $section)
                .frame(width: 220)
                .background(Palette.sidebar)
            if section == .notes {
                NotesView(store: store).frame(maxWidth: .infinity)
            } else if section == .goals {
                GoalsView(store: store).frame(maxWidth: .infinity)
            } else if section == .calendar {
                WeekCalendar(store: store).frame(maxWidth: .infinity)
            } else if section == .workspace {
                WorkspaceSettings(store: store).frame(maxWidth: .infinity)
            } else {
                PlannerList(store: store, section: section, selected: $selected)
                    .frame(minWidth: 320, maxWidth: .infinity)
                if section == .today {
                    if showCalendar {
                        Divider()
                        DayTimeline(store: store) { withAnimation(.snappy) { showCalendar = false } }.frame(width: 270)
                    } else {
                        Button { withAnimation(.snappy) { showCalendar = true } } label: { Label("Calendar", systemImage: "calendar") }
                            .buttonStyle(Pill(fill: Palette.pWash)).padding(.top, 40).padding(.trailing, 14)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .help("Show today's calendar")
                    }
                }
            }
            if section != .notes, section != .goals, section != .calendar, section != .workspace, let id = selected, store.tasks.contains(where: { $0.id == id }) {
                Divider()
                TaskDetail(store: store, id: id, close: { selected = nil })
                    .id(id) // fresh local edit state per task
                    .frame(width: 340)
            }
        }
        .background(Palette.cream)
        .foregroundStyle(Palette.pInk)
        .onChange(of: section) { selected = nil; if section == .today { showCalendar = true } }
        .background(
            Button("") { if let id = selected { store.schedule(id, day: store.today) } }
                .keyboardShortcut("t", modifiers: .command).hidden() // ⌘T: add the selected task to Today
        )
        .sheet(isPresented: $router.planning, onDismiss: {
            UserDefaults.standard.set(isoDay(of: store.today), forKey: Self.plannedKey)
        }) {
            PlanYourDay(store: store) { router.planning = false }
        }
        .sheet(isPresented: $router.wrapUp) {
            WrapUp(store: store) { router.wrapUp = false }
        }
        .onAppear {
            // First open of the day: offer to plan it (unless we came here for something else).
            if !router.wrapUp && router.focusTask == nil
                && UserDefaults.standard.string(forKey: Self.plannedKey) != isoDay(of: store.today) { router.planning = true }
            reveal(router.focusTask)
        }
        .onChange(of: router.focusTask) { reveal(router.focusTask) }
    }
}

extension PlannerView {
    /// Shows the task where it lives and opens its details.
    func reveal(_ id: UUID?) {
        guard let id, let t = store.tasks.first(where: { $0.id == id }) else { return }
        router.focusTask = nil
        section = t.done ? .done
            : store.todo.contains(where: { $0.id == id }) ? .today
            : t.someday == true ? .someday
            : t.projectID.map { .project($0) } ?? .upcoming
        DispatchQueue.main.async { selected = id } // after the section change clears it
    }
}

// MARK: - Sidebar

struct PlannerSidebar: View {
    @Bindable var store: Store
    @Binding var section: PlannerSection
    @State private var newProject = ""
    @State private var renaming: UUID?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer().frame(height: 34) // under the traffic lights
            row(.today, "Today", "sun.max.fill", .orange, store.todo.count)
            row(.upcoming, "Upcoming", "calendar", Palette.blue, store.upcoming.count)
            row(.someday, "Someday", "tray", Palette.olive, store.someday.count)
            row(.done, "Done", "checkmark.circle", Palette.sage, nil)
            row(.calendar, "Calendar", "calendar.day.timeline.left", Palette.blue, nil)
            row(.goals, "Goals", "target", Palette.rose, store.objectives(in: store.thisWeek).filter { !store.isAchieved($0) }.count)
            row(.notes, "Notes", "note.text", Palette.lavender, nil)

            Text("PROJECTS").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
                .padding(.top, 18).padding(.bottom, 4).padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.projects) { p in
                        if renaming == p.id {
                            HStack(spacing: 9) {
                                Image(systemName: "circle.fill").font(.callout.weight(.semibold)).foregroundStyle(Palette.named(p.color)).frame(width: 18)
                                TextField("Project name", text: $renameText)
                                    .textFieldStyle(.plain).font(.body).focused($renameFocused)
                                    .onSubmit { store.renameProject(p.id, to: renameText); renaming = nil }
                                    .onExitCommand { renaming = nil }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 7))
                            .onAppear { renameFocused = true }
                        } else {
                        row(.project(p.id), p.name, "circle.fill", Palette.named(p.color),
                            store.tasks(in: p.id).filter { !$0.done }.count)
                            .contextMenu {
                                Button("Rename…") { renameText = p.name; renaming = p.id }
                                Menu("Color") {
                                    ForEach(["sage", "lavender", "olive", "blue", "rose", "sand"], id: \.self) { c in
                                        Button(c.capitalized) { if let i = store.projects.firstIndex(where: { $0.id == p.id }) { store.projects[i].color = c } }
                                    }
                                }
                                Button("Delete Project", role: .destructive) {
                                    if section == .project(p.id) { section = .today }
                                    store.deleteProject(p.id)
                                }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
                        TextField("New project", text: $newProject)
                            .textFieldStyle(.plain).font(.body)
                            .onSubmit {
                                let name = newProject.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty else { return }
                                section = .project(store.addProject(name))
                                newProject = ""
                            }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
            }
            Spacer(minLength: 0)
            row(.workspace, "Workspace", "rectangle.3.group", Palette.pInkSoft, nil)
            Button {
                store.settings.plannerDark.toggle()
                PlannerWindow.shared.applyAppearance()
            } label: {
                Label(store.settings.plannerDark ? "Light mode" : "Dark mode", systemImage: store.settings.plannerDark ? "sun.max" : "moon")
                    .font(.callout.weight(.medium)).foregroundStyle(Palette.pInkSoft)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .buttonStyle(.plain).padding(.bottom, 8)
        }
        .padding(.horizontal, 10)
    }

    /// A sidebar row; tasks dragged onto it are moved there.
    func row(_ s: PlannerSection, _ title: String, _ icon: String, _ tint: Color, _ count: Int?) -> some View {
        Button { section = s } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.callout.weight(.semibold)).foregroundStyle(tint).frame(width: 18)
                Text(title).font(.body.weight(section == s ? .semibold : .regular)).lineLimit(1)
                Spacer()
                if let count, count > 0 { Text("\(count)").font(.subheadline).foregroundStyle(Palette.pInkSoft) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(section == s ? Palette.pWash : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { ids, _ in
            for id in ids.compactMap(UUID.init(uuidString:)) { drop(id, on: s) }
            return true
        }
    }

    func drop(_ id: UUID, on s: PlannerSection) {
        switch s {
        case .today: store.schedule(id, day: store.today)
        case .upcoming: store.schedule(id, day: Calendar.current.date(byAdding: .day, value: 1, to: store.today))
        case .someday: store.schedule(id, day: nil, someday: true)
        case .done: if store.tasks.first(where: { $0.id == id })?.done == false { store.toggle(id) }
        case .notes, .goals, .calendar, .workspace: break
        case .project(let p): store.update(id) { $0.projectID = p }
        }
    }
}

// MARK: - List

struct PlannerList: View {
    @Bindable var store: Store
    let section: PlannerSection
    @Binding var selected: UUID?
    @State private var newTask = ""
    @FocusState private var adding: Bool

    var title: String {
        switch section {
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .someday: "Someday"
        case .done: "Done"
        case .notes: "Notes"
        case .workspace: "Workspace"
        case .goals: "Goals"
        case .calendar: "Calendar"
        case .project(let id): store.projects.first { $0.id == id }?.name ?? "Project"
        }
    }

    /// (heading, tasks) groups for the current section.
    var groups: [(String?, [TaskItem])] {
        let h = store.settings.dayStartHour
        switch section {
        case .today:
            let earlier = store.stale
            return [(nil, store.todo)] + (earlier.isEmpty ? [] : [("Earlier, unfinished", earlier)])
        case .upcoming:
            return byDay(store.upcoming) { $0.planDayOf(startHour: h) }
        case .someday:
            return [(nil, store.someday)]
        case .done:
            return byDay(store.doneRecent) { Calendar.current.startOfDay(for: $0.completedAt!) }
        case .notes, .goals, .calendar, .workspace: return []
        case .project(let id):
            let all = store.tasks(in: id)
            let done = all.filter(\.done)
            return [(nil, all.filter { !$0.done })] + (done.isEmpty ? [] : [("Done", done)])
        }
    }

    func byDay(_ tasks: [TaskItem], _ key: (TaskItem) -> Date) -> [(String?, [TaskItem])] {
        var order: [Date] = [], map: [Date: [TaskItem]] = [:]
        for t in tasks { let d = key(t); if map[d] == nil { order.append(d) }; map[d, default: []].append(t) }
        return order.map { (dayTitle($0), map[$0]!) }
    }

    func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: store.today) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    var subtitle: String? {
        switch section {
        case .today:
            return Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case .someday: return "No date yet. Drag to Today when you're ready."
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.largeTitle.weight(.bold))
                    Spacer()
                    if section == .today {
                        Button { PlannerRouter.shared.planning = true } label: { Label("Plan your day", systemImage: "sun.horizon") }
                            .buttonStyle(Pill(fill: Palette.pWash))
                        Button { PlannerRouter.shared.wrapUp = true } label: { Label("Wrap up", systemImage: "moon.stars") }
                            .buttonStyle(Pill(fill: Palette.pWash))
                    }
                }
                if let subtitle { Text(subtitle).font(.body).foregroundStyle(Palette.pInkSoft) }
                if section == .today { ThisWeekStrip(store: store).padding(.top, 6); WorkloadMeter(store: store).padding(.top, 4); progress }
            }
            .padding(.horizontal, 28).padding(.top, 38).padding(.bottom, 14)

            if case .project(let id) = section, let p = store.projects.first(where: { $0.id == id }) {
                PlanPage(project: p).id(p.id).padding(.horizontal, 24).padding(.bottom, 12)
            }

            if section != .done {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.callout.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
                    TextField("Add task", text: $newTask).textFieldStyle(.plain).font(.title3).focused($adding)
                        .onSubmit(add)
                }
                .padding(10)
                .background(Palette.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24).padding(.bottom, 10)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        if let heading = group.0 {
                            Text(heading).font(.callout.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
                                .padding(.top, 10).padding(.leading, 4)
                        }
                        ForEach(group.1) { t in
                            PlannerRow(store: store, task: t, selected: selected == t.id)
                                .onTapGesture { selected = t.id }
                                .draggable(t.id.uuidString)
                        }
                    }
                    if groups.allSatisfy({ $0.1.isEmpty }) {
                        Text(section == .today ? "Nothing planned. Add a task, or drag one here from Upcoming or Someday." : "Nothing here yet.")
                            .font(.body).foregroundStyle(Palette.pInkSoft).padding(.top, 20)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .background(
            Button("") { adding = true }.keyboardShortcut("n", modifiers: .command).hidden() // ⌘N: new task
        )
    }

    var progress: some View {
        let all = store.todo.count + store.completed.filter { Calendar.current.isDate($0.completedAt!, inSameDayAs: .now) }.count
        let done = all - store.todo.count
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.pWash)
                Capsule().fill(Palette.sage).frame(width: all == 0 ? 0 : g.size.width * CGFloat(done) / CGFloat(all))
            }
        }
        .frame(height: 5).frame(maxWidth: 320).padding(.top, 6)
    }

    func add() {
        let today = store.today
        let id = store.addTask(newTask) { t in
            switch section {
            case .upcoming: t.day = Calendar.current.date(byAdding: .day, value: 1, to: today)
            case .someday: t.someday = true
            case .project(let p): t.projectID = p
            default: break
            }
        }
        if id != nil { newTask = "" }
    }
}

func estimate(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }

// MARK: - Row (Sunsama-style card)

struct PlannerRow: View {
    @Bindable var store: Store
    let task: TaskItem
    let selected: Bool

    var project: Project? { store.projects.first { $0.id == task.projectID } }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { store.toggle(task.id) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(task.done ? Palette.sage : Palette.pInkSoft)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if let s = task.startTime { chip(s.formatted(date: .omitted, time: .shortened), Palette.named(project?.color ?? "sand")) }
                    Text(task.title).font(.title3).strikethrough(task.done).foregroundStyle(task.done ? Palette.pInkSoft : Palette.pInk)
                }
                let subs = task.subtasks ?? []
                if !subs.isEmpty {
                    Text("\(subs.filter(\.done).count)/\(subs.count) subtasks").font(.subheadline).foregroundStyle(Palette.pInkSoft)
                }
                HStack(spacing: 10) {
                    if let o = store.objectives.first(where: { $0.id == task.objectiveID }) {
                        Label(o.title, systemImage: "target").font(.subheadline.weight(.medium)).foregroundStyle(Palette.rose).brightness(-0.25).lineLimit(1)
                    }
                    if let p = project {
                        Text("# \(p.name)").font(.subheadline.weight(.medium)).foregroundStyle(Palette.named(p.color).opacity(1)).brightness(-0.25)
                    }
                    if let due = task.due {
                        Label(due.formatted(.dateTime.month(.abbreviated).day()), systemImage: "flag")
                            .font(.subheadline).foregroundStyle(due < store.today ? .red : Palette.pInkSoft)
                    }
                    if task.reminder != nil { Image(systemName: "bell").font(.footnote).foregroundStyle(Palette.pInkSoft) }
                    if task.notes?.isEmpty == false { Image(systemName: "note.text").font(.footnote).foregroundStyle(Palette.pInkSoft) }
                }
            }
            Spacer(minLength: 8)
            if !task.done && !store.todo.contains(where: { $0.id == task.id }) {
                Button { store.schedule(task.id, day: store.today) } label: { Label("Today", systemImage: "sun.max.fill") }
                    .buttonStyle(Pill(fill: .orange.opacity(0.15), text: .orange)).help("Add to Today (⌘T)")
            }
            let actual = store.actualMinutes(task.id)
            if task.timeLimit != nil || actual > 0 {
                Text(actual > 0 ? "\(estimate(actual)) / \(task.timeLimit.map(estimate) ?? "–")" : estimate(task.timeLimit!))
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(actual > (task.timeLimit ?? .max) ? Color.orange : Palette.pInk)
                    .help(actual > 0 ? "Actual / planned" : "Planned")
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.pWash, in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(12)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? Palette.pInk.opacity(0.35) : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
    }

    func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Detail

struct TaskDetail: View {
    @Bindable var store: Store
    let id: UUID
    let close: () -> Void
    // Text is edited locally and saved when you pause, so typing never ripples through the notch.
    @State private var title = ""
    @State private var notes = ""
    @State private var newSub = ""
    @State private var commit: DispatchWorkItem?

    var task: TaskItem? { store.tasks.first { $0.id == id } }

    var body: some View {
        if let task {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Button { store.toggle(id) } label: {
                            Label(task.done ? "Done" : "Mark done", systemImage: task.done ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(Pill(fill: task.done ? Palette.sage : Palette.pWash, text: task.done ? Palette.ink : Palette.pInk, size: 12))
                        Spacer()
                        Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Palette.pInkSoft)
                    }
                    .font(.callout)
                    .padding(.top, 30)

                    TextField("Title", text: $title, axis: .vertical)
                        .textFieldStyle(.plain).font(.title.weight(.semibold))
                        .onChange(of: title) { later() }

                    field("Project") {
                        Picker("", selection: Binding(get: { task.projectID }, set: { v in store.update(id) { $0.projectID = v } })) {
                            Text("None").tag(UUID?.none)
                            ForEach(store.projects) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        .labelsHidden().fixedSize()
                    }

                    field("Goal") {
                        let options = store.objectives.filter { $0.week == store.thisWeek || $0.id == task.objectiveID }
                        Picker("", selection: Binding(get: { task.objectiveID }, set: { v in store.update(id) { $0.objectiveID = v } })) {
                            Text("None").tag(UUID?.none)
                            ForEach(options) { Text($0.title).tag(UUID?.some($0.id)) }
                        }
                        .labelsHidden().fixedSize()
                        .help(options.isEmpty ? "Add a goal for this week in Today or Goals" : "Which weekly goal this task moves forward")
                    }

                    field("When") {
                        Menu(whenText(task)) {
                            Button("Today") { store.schedule(id, day: store.today) }
                            Button("Tomorrow") { store.schedule(id, day: Calendar.current.date(byAdding: .day, value: 1, to: store.today)) }
                            Button("Next week") { store.schedule(id, day: Calendar.current.date(byAdding: .day, value: 7, to: store.today)) }
                            Button("Someday") { store.schedule(id, day: nil, someday: true) }
                        }
                        .fixedSize()
                        if task.someday != true {
                            DatePicker("", selection: Binding(get: { task.planDayOf(startHour: store.settings.dayStartHour) },
                                                              set: { store.schedule(id, day: Calendar.current.startOfDay(for: $0)) }),
                                       displayedComponents: .date)
                                .labelsHidden().fixedSize()
                        }
                    }

                    OptionalDate(label: "Due", date: Binding(get: { task.due }, set: { v in store.update(id) { $0.due = v } }), components: .date)
                    OptionalDate(label: "Start time", date: Binding(get: { task.startTime }, set: { v in store.update(id) { $0.startTime = v } }), components: .hourAndMinute)
                    OptionalDate(label: "Reminder", date: Binding(get: { task.reminder }, set: { store.setReminder(id, at: $0) }), components: [.date, .hourAndMinute])

                    field("Estimate") {
                        EstimateControl(store: store, task: task)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Subtasks").font(.callout.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
                        ForEach(task.subtasks ?? []) { s in
                            HStack(spacing: 8) {
                                Button {
                                    store.update(id) { t in if let i = t.subtasks?.firstIndex(where: { $0.id == s.id }) { t.subtasks![i].done.toggle() } }
                                } label: { Image(systemName: s.done ? "checkmark.circle.fill" : "circle") }
                                .buttonStyle(.plain).foregroundStyle(s.done ? Palette.sage : Palette.pInkSoft)
                                Text(s.title).font(.body).strikethrough(s.done)
                                Spacer()
                                Button { store.update(id) { $0.subtasks?.removeAll { $0.id == s.id } } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).foregroundStyle(Palette.pInkSoft)
                            }
                        }
                        TextField("Add subtask", text: $newSub).textFieldStyle(.plain).font(.body)
                            .onSubmit {
                                let t = newSub.trimmingCharacters(in: .whitespaces)
                                guard !t.isEmpty else { return }
                                store.update(id) { $0.subtasks = ($0.subtasks ?? []) + [Subtask(title: t)] }
                                newSub = ""
                            }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notes").font(.callout.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
                        TextEditor(text: $notes)
                            .font(.body).scrollContentBackground(.hidden)
                            .frame(minHeight: 160)
                            .padding(8).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
                            .onChange(of: notes) { later() }
                    }

                    Button(role: .destructive) { save(); store.delete(id); close() } label: { Label("Delete task", systemImage: "trash") }
                        .buttonStyle(.plain).font(.callout).foregroundStyle(.red.opacity(0.8))
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
            .background(Palette.cream)
            .onAppear { title = task.title; notes = task.notes ?? "" }
            .onDisappear(perform: save)
        }
    }

    func whenText(_ t: TaskItem) -> String {
        if t.someday == true { return "Someday" }
        let d = t.planDayOf(startHour: store.settings.dayStartHour)
        if Calendar.current.isDate(d, inSameDayAs: store.today) { return "Today" }
        if Calendar.current.isDateInTomorrow(d) { return "Tomorrow" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    func later() {
        commit?.cancel()
        let w = DispatchWorkItem { save() }
        commit = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func save() {
        commit?.cancel()
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        store.update(id) { task in
            if !t.isEmpty { task.title = t }
            task.notes = notes.isEmpty ? nil : notes
        }
    }

    func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.callout.weight(.semibold)).foregroundStyle(Palette.pInkSoft).frame(width: 74, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

/// "None" until you add one; then a date picker with a clear button.
struct OptionalDate: View {
    let label: String
    @Binding var date: Date?
    let components: DatePickerComponents

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.callout.weight(.semibold)).foregroundStyle(Palette.pInkSoft).frame(width: 74, alignment: .leading)
            if let d = date {
                DatePicker("", selection: Binding(get: { d }, set: { date = $0 }), displayedComponents: components)
                    .labelsHidden().fixedSize()
                Button { date = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Palette.pInkSoft)
            } else {
                Button { date = Calendar.current.date(byAdding: .hour, value: 1, to: .now)!.roundedToHour } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(Pill(fill: Palette.pWash))
            }
            Spacer(minLength: 0)
        }
    }
}

extension Date {
    var roundedToHour: Date { Calendar.current.date(bySettingHour: Calendar.current.component(.hour, from: self), minute: 0, second: 0, of: self) ?? self }
}

// MARK: - Workload meter: planned time vs time left in the workday

struct WorkloadMeter: View {
    @Bindable var store: Store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let planned = store.plannedMinutes, left = store.minutesLeft(now: ctx.date)
            let over = planned > left
            let unestimated = store.todo.filter { $0.timeLimit == nil }.count
            let end = Calendar.current.date(bySettingHour: store.settings.workdayEndHour, minute: 0, second: 0, of: ctx.date)!
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(estimate(planned)) planned · \(estimate(left)) left until \(end.formatted(date: .omitted, time: .shortened))")
                        .font(.callout.weight(.medium).monospacedDigit())
                    if over { Text("Over by \(estimate(planned - left))").font(.subheadline.weight(.semibold)).foregroundStyle(.orange) }
                }
                if unestimated > 0 {
                    Text("\(unestimated) task\(unestimated == 1 ? "" : "s") without an estimate").font(.subheadline).foregroundStyle(Palette.pInkSoft)
                }
            }
            .foregroundStyle(over ? Color.orange : Palette.pInk)
        }
    }
}

// MARK: - Plan your day

struct PlanYourDay: View {
    @Bindable var store: Store
    let done: () -> Void

    var suggestions: [(String, String, [TaskItem])] {
        let onToday = Set(store.todo.map(\.id))
        let soon = Calendar.current.date(byAdding: .day, value: 3, to: store.today)!
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: store.today)!
        let h = store.settings.dayStartHour
        let open = store.tasks.filter { !$0.done && $0.dismissedAt == nil && !onToday.contains($0.id) }
        return [
            ("Due soon", "flag", open.filter { ($0.due ?? .distantFuture) < soon }),
            ("Left from before", "arrow.uturn.backward", store.stale),
            ("Tomorrow", "calendar", open.filter { $0.someday != true && $0.planDayOf(startHour: h) == tomorrow && $0.due == nil }),
            ("Someday", "tray", store.someday),
        ].filter { !$0.2.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Plan your day").font(.title.weight(.bold))
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.body).foregroundStyle(Palette.pInkSoft)
            }
            WorkloadMeter(store: store)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    group("On Today", "sun.max.fill", store.todo, onToday: true)
                    ForEach(suggestions, id: \.0) { s in group(s.0, s.1, s.2, onToday: false) }
                    if suggestions.isEmpty {
                        Text("Nothing else waiting. Add tasks in the Planner and they'll show up here.")
                            .font(.callout).foregroundStyle(Palette.pInkSoft)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Start my day", action: done).keyboardShortcut(.defaultAction)
                    .buttonStyle(Pill(fill: Palette.pInk, text: Palette.card, size: 13))
            }
        }
        .padding(24)
        .frame(width: 520, height: 600)
        .background(Palette.cream)
        .foregroundStyle(Palette.pInk)
    }

    func group(_ title: String, _ icon: String, _ tasks: [TaskItem], onToday: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.callout.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
            if tasks.isEmpty {
                Text("Nothing yet").font(.callout).foregroundStyle(Palette.pInkSoft)
            }
            ForEach(tasks) { t in
                HStack(spacing: 10) {
                    Text(t.title).font(.body).lineLimit(1)
                    if let due = t.due {
                        Text(due < store.today ? "overdue" : "due " + due.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.subheadline).foregroundStyle(due < store.today ? .red : Palette.pInkSoft)
                    }
                    Spacer()
                    EstimateControl(store: store, task: t)
                    if onToday {
                        Button("Tomorrow") { store.schedule(t.id, day: Calendar.current.date(byAdding: .day, value: 1, to: store.today)) }
                            .buttonStyle(Pill(fill: Palette.pWash))
                    } else {
                        Button { store.schedule(t.id, day: store.today) } label: { Label("Today", systemImage: "plus") }
                            .buttonStyle(Pill(fill: .orange, text: .white))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Controls that read as buttons

/// A filled capsule button: obvious to click, in the app's flat style.
struct Pill: ButtonStyle {
    var fill: Color
    var text: Color = Palette.pInk
    var size: CGFloat = 11
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, size + 1).padding(.vertical, size * 0.45)
            .background(fill, in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

/// − 0:30 + in 15-minute steps.
struct EstimateControl: View {
    @Bindable var store: Store
    let task: TaskItem
    var body: some View {
        HStack(spacing: 0) {
            Button { let m = (task.timeLimit ?? 0) - 15; store.setTimeLimit(task.id, minutes: m > 0 ? m : nil) } label: {
                Image(systemName: "minus").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            Text(task.timeLimit.map(estimate) ?? "–:––").font(.subheadline.weight(.medium).monospacedDigit()).frame(minWidth: 34)
            Button { store.setTimeLimit(task.id, minutes: (task.timeLimit ?? 0) + 15) } label: {
                Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain).font(.footnote.weight(.bold)).foregroundStyle(Palette.pInk)
        .background(Palette.pWash, in: Capsule())
        .help("Time estimate")
    }
}

// MARK: - Plan page: a project's Markdown file in iCloud Drive → Notch → Plans

struct PlanPage: View {
    let project: Project
    @State private var text = ""
    @State private var open = true
    @State private var pending: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                Label("Plan", systemImage: open ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain).font(.callout.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
            .help("Saved as \(NoteFiles.planURL(project).lastPathComponent) in iCloud Drive → Notch → Plans")
            if open {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Goals, context, decisions, links… Agents can read this later.")
                            .font(.body).foregroundStyle(Palette.pInkSoft).padding(.horizontal, 13).padding(.vertical, 8)
                    }
                    TextEditor(text: $text).font(.body).scrollContentBackground(.hidden).padding(8)
                }
                .frame(minHeight: 110, maxHeight: 200)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .onAppear { text = NoteFiles.read(NoteFiles.planURL(project)) ?? "" }
        .onChange(of: text) {
            pending?.cancel()
            let (t, url) = (text, NoteFiles.planURL(project))
            let w = DispatchWorkItem { NoteFiles.write(t, to: url) }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
        }
        .onDisappear { pending?.perform() }
    }
}

// MARK: - Notes: dated daily notes (today's is the notch Notepad)

struct NotesView: View {
    @Bindable var store: Store
    @State private var day: String?
    @State private var text = ""
    @State private var pending: DispatchWorkItem?
    @State private var files: [(day: String, url: URL)] = []

    var today: String { isoDay(of: store.today) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Notes").font(.largeTitle.weight(.bold)).padding(.top, 38).padding(.bottom, 10).padding(.horizontal, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach([today] + files.map(\.day).filter { $0 != today }, id: \.self) { d in
                            Button { pick(d) } label: {
                                Text(label(d)).font(.body.weight(day == d ? .semibold : .regular))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(day == d ? Palette.pWash : .clear, in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("iCloud Drive → Notch → Notes").font(.subheadline).foregroundStyle(Palette.pInkSoft).padding(8)
            }
            .frame(width: 210).padding(.horizontal, 12)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(day.map(label) ?? "").font(.title.weight(.semibold)).padding(.top, 38)
                if day == today {
                    Text("Today's note is the notch Notepad. Edits here show up there too.").font(.callout).foregroundStyle(Palette.pInkSoft)
                }
                TextEditor(text: $text).font(.title3).scrollContentBackground(.hidden)
                    .padding(10).background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .onAppear { files = NoteFiles.listNotes(); pick(today) }
        .onChange(of: store.notes) { if day == today, text != store.notes { text = store.notes } }
        .onChange(of: text) { save(later: true) }
        .onDisappear { save(later: false) }
    }

    func label(_ d: String) -> String {
        if d == today { return "Today" }
        guard let date = date(fromDayKey: d) else { return d }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    func pick(_ d: String) {
        save(later: false)
        day = d
        text = d == today ? store.notes : (files.first { $0.day == d }.flatMap { NoteFiles.read($0.url) } ?? "")
    }

    func save(later: Bool) {
        pending?.cancel()
        guard let day else { return }
        let t = text
        let w = DispatchWorkItem {
            if day == today { if store.notes != t { store.notes = t } } // DailyNotes writes the file
            else if let d = date(fromDayKey: day) { NoteFiles.write(t, to: NoteFiles.noteURL(d)) }
        }
        if later { pending = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w) } else { w.perform() }
    }
}

// MARK: - Daily wrap-up

struct WrapUp: View {
    @Bindable var store: Store
    let done: () -> Void
    @State private var highlights = ""

    var finishedToday: [TaskItem] {
        store.completed.filter { Calendar.current.isDate($0.completedAt!, inSameDayAs: .now) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wrap up your day").font(.title.weight(.bold))
                let focus = store.focusLog.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.seconds }
                Text("\(finishedToday.count) done · \(durationText(focus)) focused").font(.body).foregroundStyle(Palette.pInkSoft)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Done today", systemImage: "checkmark.circle.fill").font(.callout.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
                        if finishedToday.isEmpty { Text("Nothing checked off yet. That's okay.").font(.callout).foregroundStyle(Palette.pInkSoft) }
                        ForEach(finishedToday) { t in
                            Text("✓ " + t.title).font(.body).padding(.horizontal, 10).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Still open", systemImage: "circle").font(.callout.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
                        if store.todo.isEmpty { Text("All clear.").font(.callout).foregroundStyle(Palette.pInkSoft) }
                        ForEach(store.todo) { t in
                            HStack(spacing: 8) {
                                Text(t.title).font(.body).lineLimit(1)
                                Spacer()
                                Button("Tomorrow") { store.schedule(t.id, day: Calendar.current.date(byAdding: .day, value: 1, to: store.today)) }
                                    .buttonStyle(Pill(fill: Palette.pWash))
                                Button("Someday") { store.schedule(t.id, day: nil, someday: true) }
                                    .buttonStyle(Pill(fill: Palette.pWash))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Highlights", systemImage: "sparkles").font(.callout.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
                        ZStack(alignment: .topLeading) {
                            if highlights.isEmpty {
                                Text("What went well? What did you learn? Saved to today's note.")
                                    .font(.body).foregroundStyle(Palette.pInkSoft).padding(.horizontal, 13).padding(.vertical, 8)
                            }
                            TextEditor(text: $highlights).font(.body).scrollContentBackground(.hidden).padding(8)
                        }
                        .frame(height: 90).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            HStack {
                Button("Not now", action: done).buttonStyle(Pill(fill: Palette.pWash, size: 13))
                Spacer()
                Button("Finish day") {
                    let h = highlights.trimmingCharacters(in: .whitespacesAndNewlines)
                    var lines = ["## Wrap-up", "Done: " + (finishedToday.isEmpty ? "nothing checked off" : finishedToday.map(\.title).joined(separator: ", "))]
                    if !h.isEmpty { lines.append("Highlights: " + h) }
                    DailyNotes.shared.append(lines.joined(separator: "\n"))
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(Pill(fill: Palette.pInk, text: Palette.card, size: 13))
            }
        }
        .padding(24)
        .frame(width: 520, height: 620)
        .background(Palette.cream)
        .foregroundStyle(Palette.pInk)
    }
}

// MARK: - Weekly objectives

/// Today's "This week" strip: 2–3 goals with progress.
struct ThisWeekStrip: View {
    @Bindable var store: Store
    @State private var adding = false
    @State private var newGoal = ""

    var body: some View {
        let goals = store.objectives(in: store.thisWeek)
        HStack(spacing: 8) {
            Text("This week").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
            ForEach(goals) { o in GoalChip(store: store, objective: o) }
            if adding {
                TextField("New goal", text: $newGoal).textFieldStyle(.plain).font(.callout).frame(width: 160)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(Palette.card, in: Capsule())
                    .onSubmit { store.addObjective(newGoal); newGoal = ""; adding = false }
                    .onExitCommand { adding = false }
            } else if goals.count < 3 {
                Button { adding = true } label: { Label(goals.isEmpty ? "Add a goal" : "Goal", systemImage: "plus") }
                    .buttonStyle(Pill(fill: Palette.pWash))
            }
        }
    }
}

struct GoalChip: View {
    @Bindable var store: Store
    let objective: Objective

    var body: some View {
        let (d, n) = store.progress(objective)
        let achieved = store.isAchieved(objective)
        HStack(spacing: 6) {
            Image(systemName: achieved ? "checkmark.circle.fill" : "target").foregroundStyle(achieved ? Palette.sage : Palette.rose).brightness(-0.15)
            Text(objective.title).lineLimit(1)
            if n > 0 { Text("\(d)/\(n)").monospacedDigit().foregroundStyle(Palette.pInkSoft) }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(alignment: .leading) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.card)
                    Capsule().fill(Palette.rose.opacity(0.35)).frame(width: n == 0 ? 0 : g.size.width * CGFloat(d) / CGFloat(n))
                }
            }
        }
        .contextMenu {
            Button(objective.achieved == true ? "Mark not achieved" : "Mark achieved") {
                if let i = store.objectives.firstIndex(where: { $0.id == objective.id }) {
                    store.objectives[i].achieved = objective.achieved == true ? nil : true
                }
            }
            Button("Delete goal", role: .destructive) { store.deleteObjective(objective.id) }
        }
        .help("\(d) of \(n) linked tasks done. Link tasks from their details. Right-click for options.")
    }
}

/// All weeks: this week's goals to edit, past weeks as achieved / missed.
struct GoalsView: View {
    @Bindable var store: Store
    @State private var newGoal = ""

    var weeks: [String] { Array(Set(store.objectives.map(\.week))).filter { $0 != store.thisWeek }.sorted(by: >) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Goals").font(.largeTitle.weight(.bold))
                    Text("2–3 goals a week. Link tasks to a goal from their details; progress fills as they get done.")
                        .font(.body).foregroundStyle(Palette.pInkSoft)
                }
                .padding(.top, 38)

                week(store.thisWeek, current: true)
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.callout.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
                    TextField("Add a goal for this week", text: $newGoal).textFieldStyle(.plain).font(.title3)
                        .onSubmit { store.addObjective(newGoal); newGoal = "" }
                }
                .padding(10).background(Palette.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))

                ForEach(weeks, id: \.self) { w in week(w, current: false) }
            }
            .padding(.horizontal, 28).padding(.bottom, 24)
        }
    }

    func title(_ w: String) -> String {
        guard let d = date(fromDayKey: w) else { return w }
        return "Week of " + d.formatted(.dateTime.month(.abbreviated).day())
    }

    func week(_ w: String, current: Bool) -> some View {
        let goals = store.objectives(in: w)
        let hit = goals.filter { store.isAchieved($0) }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(current ? "This week" : title(w)).font(.body.weight(.semibold))
                Spacer()
                if !goals.isEmpty { Text("\(hit) of \(goals.count) achieved").font(.callout).foregroundStyle(Palette.pInkSoft) }
            }
            if goals.isEmpty && current { Text("No goals yet.").font(.callout).foregroundStyle(Palette.pInkSoft) }
            ForEach(goals) { o in
                let (d, n) = store.progress(o)
                let achieved = store.isAchieved(o)
                HStack(spacing: 10) {
                    Image(systemName: achieved ? "checkmark.circle.fill" : current ? "target" : "xmark.circle")
                        .foregroundStyle(achieved ? Palette.sage : current ? Palette.rose : Color.red.opacity(0.6))
                    Text(o.title).font(.title3)
                    Spacer()
                    Text(n == 0 ? "no tasks linked" : "\(d)/\(n) tasks").font(.callout.monospacedDigit()).foregroundStyle(Palette.pInkSoft)
                    if current {
                        Button(o.achieved == true ? "Undo" : "Achieved") {
                            if let i = store.objectives.firstIndex(where: { $0.id == o.id }) { store.objectives[i].achieved = o.achieved == true ? nil : true }
                        }
                        .buttonStyle(Pill(fill: Palette.pWash))
                    } else if !achieved {
                        Button("Bring to this week") { store.addObjective(o.title) }.buttonStyle(Pill(fill: Palette.pWash))
                    }
                    Button { store.deleteObjective(o.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(Palette.pInkSoft).help("Delete goal")
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
