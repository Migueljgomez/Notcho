import AppKit
import EventKit
import SwiftUI

// MARK: - UI state shared with the controller

enum Page: String, CaseIterable { case workspace = "Workspace", insights = "Insights", customize = "Customize" }

@Observable final class NotchModel {
    var expanded = false
    var editing = false            // a text field has focus: don't collapse on hover-out
    var page = Page.workspace
    var collapsed = CGSize(width: 200, height: 32)
    var workspace = CGSize(width: 820, height: 330)
    var notchOffsetX: CGFloat = 0  // notch centre relative to panel centre
    var pill = CGRect(x: 0, y: 0, width: 90, height: 30) // relative to panel top-left
}

// MARK: - Palette (flat, no paper texture)

enum Palette {
    static let sage = Color(red: 0.56, green: 0.68, blue: 0.58)
    static let lavender = Color(red: 0.60, green: 0.57, blue: 0.75)
    static let olive = Color(red: 0.69, green: 0.66, blue: 0.38)
    static let blue = Color(red: 0.55, green: 0.66, blue: 0.77)
    static let ink = Color.black.opacity(0.82)
    static let inkSoft = Color.black.opacity(0.5)
    static let wash = Color.black.opacity(0.07)
}

// MARK: - Metrics: one spacing scale, tuned for a 16" MacBook Pro (1728 × 1117 pt)

enum Metrics {
    static let panelWidth: CGFloat = 940   // the 16" has room for a wide panel
    static let panelHeight: CGFloat = 360
    static let outer: CGFloat = 16         // panel edge → cards
    static let cardGap: CGFloat = 12       // between cards, and header → cards
    static let cardPadding: CGFloat = 16   // card edge → content
    static let cardRadius: CGFloat = 22
    static let stack: CGFloat = 10         // between blocks inside a card
}

// MARK: - Shape: flat top, inward-curving top "ears", rounded bottom

struct NotchShape: Shape {
    func path(in r: CGRect) -> Path {
        let top = min(r.width * 0.125, 10), bottom = min(r.height * 0.5, 18)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.minY + top), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + top + bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.maxY - bottom), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: r.minX + top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Dot-matrix digits (5×7 glyphs)

struct DotMatrix: View {
    let text: String
    var dot: CGFloat = 4
    var color: Color = Palette.ink

    static let glyphs: [Character: [String]] = [
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
        ":": ["0", "0", "1", "0", "1", "0", "0"],
    ]

    var body: some View {
        let glyphs = text.compactMap { Self.glyphs[$0] }
        let pitch = dot * 1.5
        let cols = glyphs.reduce(0) { $0 + $1[0].count } + max(glyphs.count - 1, 0)
        Canvas { ctx, _ in
            var x: CGFloat = 0
            for g in glyphs {
                for (row, line) in g.enumerated() {
                    for (col, bit) in line.enumerated() where bit == "1" {
                        let r = CGRect(x: x + CGFloat(col) * pitch, y: CGFloat(row) * pitch, width: dot, height: dot)
                        ctx.fill(Path(ellipseIn: r), with: .color(color))
                    }
                }
                x += CGFloat(g[0].count + 1) * pitch
            }
        }
        .frame(width: CGFloat(cols) * pitch - (pitch - dot), height: 7 * pitch - (pitch - dot))
        .accessibilityLabel(text)
    }
}

// MARK: - Root

struct RootView: View {
    let model: NotchModel
    let store: Store
    let close: () -> Void

    var body: some View {
        let size = model.expanded ? model.workspace : model.collapsed
        ZStack(alignment: .topLeading) {
            WorkspaceView(model: model, store: store, close: close)
                .frame(width: model.workspace.width, height: model.workspace.height)
                .opacity(model.expanded ? 1 : 0)
                .animation(model.expanded ? .easeOut(duration: 0.12).delay(0.2) : .easeOut(duration: 0.08), value: model.expanded)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(.black, in: NotchShape())
                .clipShape(NotchShape())
                .offset(x: model.expanded ? 0 : model.notchOffsetX)
                .frame(maxWidth: .infinity, alignment: .top)

            if store.focusState != .ready {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    DotMatrix(text: clock(store.display(at: ctx.date)), dot: 1.9, color: .white.opacity(0.9))
                }
                .frame(width: model.pill.width, height: model.pill.height)
                .background(.black, in: Capsule())
                .offset(x: model.pill.minX, y: model.pill.minY)
                .opacity(model.expanded ? 0 : 1)
                .animation(.easeOut(duration: 0.12), value: model.expanded)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Workspace shell

enum Field: Hashable { case add, rename(UUID), notes }

struct WorkspaceView: View {
    @Bindable var model: NotchModel
    let store: Store
    let close: () -> Void
    @FocusState private var field: Field?

    var body: some View {
        VStack(spacing: Metrics.cardGap) {
            HStack(spacing: 10) {
                Spacer()
                PagePicker(page: $model.page)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(.white.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain).help("Close")
            }
            .frame(height: 30)

            switch model.page {
            case .workspace:
                GeometryReader { geo in
                    let cards = store.settings.visibleCards
                    let w = geo.size.width - CGFloat(cards.count - 1) * Metrics.cardGap
                    let total = cards.reduce(0) { $0 + $1.weight }
                    HStack(spacing: Metrics.cardGap) {
                        ForEach(cards) { kind in
                            card(kind)
                                .frame(width: w * kind.weight / total)
                                .dropDestination(for: String.self) { items, _ in
                                    guard let raw = items.first, let dragged = CardKind(rawValue: raw) else { return false }
                                    withAnimation(.spring(response: 0.3, dampingFraction: 1)) { store.settings.move(dragged, onto: kind) }
                                    return true
                                }
                        }
                    }
                }
            case .insights: InsightsView(store: store)
            case .customize: CustomizeView(store: store)
            }
        }
        .padding(.horizontal, Metrics.outer).padding(.top, 6).padding(.bottom, Metrics.outer)
        .onChange(of: field) { model.editing = field != nil }
        .onChange(of: model.expanded) { if !model.expanded { field = nil } }
    }

    @ViewBuilder func card(_ kind: CardKind) -> some View {
        switch kind {
        case .tasks: TasksCard(store: store, field: $field)
        case .focus: FocusCard(store: store)
        case .notepad: NotepadCard(store: store, field: $field)
        case .events: EventsCard(store: store)
        }
    }
}

struct PagePicker: View {
    @Binding var page: Page
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Page.allCases, id: \.self) { p in
                Button { withAnimation(.spring(response: 0.28, dampingFraction: 1)) { page = p } } label: {
                    Text(p.rawValue).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(page == p ? .white : .white.opacity(0.5))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(page == p ? .white.opacity(0.16) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3).background(.white.opacity(0.08), in: Capsule())
    }
}

struct Card<Content: View>: View {
    let color: Color
    var drag: CardKind? = nil   // set on Workspace cards: the top handle drags the card
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(.black.opacity(0.15)).frame(width: 30, height: 4)
                .frame(width: 70, height: 14).contentShape(Rectangle())
                .draggable(drag?.rawValue ?? "") {
                    Text(drag?.title ?? "").font(.system(size: 13, weight: .semibold)).padding(8)
                        .background(color, in: RoundedRectangle(cornerRadius: 8))
                }
                .disabled(drag == nil)
                .help(drag == nil ? "" : "Drag to move this card")
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: Metrics.stack) { content }
                .padding(.horizontal, Metrics.cardPadding).padding(.bottom, Metrics.cardPadding).padding(.top, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(Palette.ink)
        .background(color, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

struct Placeholder: View {
    let title: String, note: String, color: Color
    var body: some View {
        Card(color: color) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(note).foregroundStyle(Palette.inkSoft)
        }
    }
}

struct CardHeader: View {
    let icon: String?, title: String
    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).font(.system(size: 15, weight: .semibold)) }
            Text(title).font(.system(size: 16, weight: .semibold))
        }
    }
}

struct Dotted: View {
    var body: some View {
        Line().stroke(style: StrokeStyle(lineWidth: 1, dash: [1, 3])).foregroundStyle(.black.opacity(0.25)).frame(height: 1)
    }
    struct Line: Shape {
        func path(in r: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } }
    }
}

// MARK: - Tasks

struct TasksCard: View {
    let store: Store
    var field: FocusState<Field?>.Binding
    @State private var showCompleted = false
    @State private var draft = ""
    @State private var renameText = ""
    @State private var limitTaskID: UUID?
    @State private var reminderTaskID: UUID?

    var body: some View {
        Card(color: Palette.sage, drag: .tasks) {
            HStack {
                CardHeader(icon: nil, title: "Today's tasks")
                Spacer()
                Text(Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
            }
            HStack(spacing: 2) {
                tab("To do", count: store.todo.count, selected: !showCompleted) { showCompleted = false }
                tab("Completed", count: store.completed.count, selected: showCompleted) { showCompleted = true }
            }
            .padding(2).background(Palette.wash, in: RoundedRectangle(cornerRadius: 9))

            if !showCompleted && store.settings.unfinished == .ask && !store.stale.isEmpty {
                stalePrompt
            }

            let list = showCompleted ? store.completed : store.todo
            List {
                if list.isEmpty {
                    Text(showCompleted ? "Nothing completed yet." : "Add your first task below.")
                        .font(.system(size: 13)).foregroundStyle(Palette.inkSoft).padding(.vertical, 8)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(list) { task in
                    row(task)
                        .overlay(alignment: .bottom) { Dotted() }
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                .onMove(perform: showCompleted ? nil : { store.moveTodo(from: $0, to: $1) })
            }
            .listStyle(.plain).scrollContentBackground(.hidden).scrollIndicators(.never)
            .environment(\.defaultMinListRowHeight, 1)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                    TextField("Add a task…", text: $draft)
                        .textFieldStyle(.plain).font(.system(size: 13)).focused(field, equals: .add)
                        .onSubmit { store.add(draft); draft = ""; field.wrappedValue = .add }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9))
                if !showCompleted && store.todo.count > 1 {
                    Text("Drag to reorder").font(.system(size: 11)).foregroundStyle(Palette.inkSoft).fixedSize()
                }
            }
        }
    }

    func tab(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).fontWeight(selected ? .semibold : .regular)
                Text("\(count)").font(.system(size: 11)).foregroundStyle(Palette.inkSoft)
            }
            .font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 4)
            .background(selected ? .white.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    func row(_ task: TaskItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 1)) { store.toggle(task.id) } } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle").font(.system(size: 17))
            }
            .buttonStyle(.plain).help(task.done ? "Mark as incomplete" : "Mark as complete")

            if field.wrappedValue == .rename(task.id) {
                TextField("", text: $renameText).textFieldStyle(.plain).font(.system(size: 13))
                    .focused(field, equals: .rename(task.id))
                    .onSubmit { store.rename(task.id, to: renameText); field.wrappedValue = nil }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let p = store.projects.first(where: { $0.id == task.projectID }) {
                            Circle().fill(Palette.named(p.color)).brightness(-0.1).frame(width: 7, height: 7).help(p.name)
                        }
                        Text(task.title).font(.system(size: 13)).strikethrough(task.done)
                            .foregroundStyle(store.focusTaskID == task.id ? Color.black : Palette.ink)
                    }
                    if !task.done && (task.timeLimit != nil || task.reminder != nil || task.due != nil) {
                        HStack(spacing: 10) {
                            if let limit = task.timeLimit {
                                let actual = store.actualMinutes(task.id)
                                Label(actual > 0 ? "\(actual)/\(limit)m" : "\(limit)m", systemImage: "timer")
                                    .foregroundStyle(actual > limit ? Color.orange : Palette.inkSoft)
                            }
                            if let r = task.reminder { Label(reminderLabel(r), systemImage: "bell") }
                            if let due = task.due {
                                Label(due < store.today ? "Overdue" : "Due " + due.formatted(.dateTime.month(.abbreviated).day()), systemImage: "flag")
                                    .foregroundStyle(due < store.today ? Color.red.opacity(0.8) : Palette.inkSoft)
                            }
                        }
                        .font(.system(size: 11)).foregroundStyle(Palette.inkSoft)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .popover(isPresented: Binding(get: { reminderTaskID == task.id }, set: { if !$0 { reminderTaskID = nil } }),
                         arrowEdge: .bottom) {
                    ReminderPicker(title: task.title, initial: task.reminder ?? Date.now.addingTimeInterval(3600)) { date in
                        if let date { remind(task.id, at: date) }
                        reminderTaskID = nil
                    }
                }
            }

            if task.done {
                Button { store.delete(task.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.inkSoft).help("Delete")
            } else {
                HStack(spacing: 8) {
                    Button { store.start(task: task.id) } label: { Image(systemName: "play.fill") }
                        .help("Start focusing on this task")
                    Button { rename(task) } label: { Image(systemName: "square.and.pencil") }
                        .help("Rename")
                    Menu {
                        Button { store.start(task: task.id) } label: { Label("Focus", systemImage: "scope") }
                        Button { store.toggle(task.id) } label: { Label("Mark as Done", systemImage: "checkmark") }
                        Button { rename(task) } label: { Label("Rename…", systemImage: "square.and.pencil") }
                        Button { limitTaskID = task.id } label: { Label("Set Time Limit…", systemImage: "timer") }
                        Menu {
                            ForEach(reminderPresets(), id: \.0) { name, date in Button(name) { remind(task.id, at: date) } }
                            Divider()
                            Button("Choose a time…") { reminderTaskID = task.id }
                            if task.reminder != nil {
                                Button("Remove reminder", role: .destructive) { store.setReminder(task.id, at: nil) }
                            }
                        } label: { Label("Remind Me", systemImage: "bell") }
                        Button { store.moveToTomorrow(task.id) } label: { Label("Move to Tomorrow", systemImage: "arrow.right") }
                        Button { store.duplicate(task.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button { PlannerWindow.shared.show(task: task.id) } label: { Label("Open in Planner", systemImage: "arrow.up.forward.app") }
                        Divider()
                        Button(role: .destructive) { store.delete(task.id) } label: { Label("Delete", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .popover(isPresented: Binding(get: { limitTaskID == task.id }, set: { if !$0 { limitTaskID = nil } }), arrowEdge: .bottom) {
            SetTimeView(subtitle: task.title, initial: task.timeLimit ?? store.focusMinutes,
                        onSave: { store.setTimeLimit(task.id, minutes: $0) },
                        onStart: { store.setTimeLimit(task.id, minutes: $0); store.start(task: task.id) },
                        shown: Binding(get: { limitTaskID == task.id }, set: { if !$0 { limitTaskID = nil } }))
        }
    }

    func rename(_ task: TaskItem) {
        renameText = task.title
        field.wrappedValue = .rename(task.id)
    }

    /// Asks for notification permission the first time (no prompt once granted), then sets the reminder.
    func remind(_ id: UUID, at date: Date) {
        ReminderService.shared.requestAccess { ok in
            store.notificationsOn = ok
            store.setReminder(id, at: date)
        }
    }

    func reminderPresets(now: Date = .now) -> [(String, Date)] {
        let cal = Calendar.current
        var list = [("In 30 minutes", now.addingTimeInterval(1800)), ("In 1 hour", now.addingTimeInterval(3600))]
        if let evening = cal.date(bySettingHour: 18, minute: 0, second: 0, of: now), evening > now.addingTimeInterval(3600) {
            list.append(("This evening (6 PM)", evening))
        }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), let morning = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            list.append(("Tomorrow morning (9 AM)", morning))
        }
        return list
    }

    /// "Ask me": shown when unfinished tasks from an earlier day are waiting.
    var stalePrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Unfinished tasks").font(.system(size: 13, weight: .semibold))
            Text("\(store.stale.count) left from before today. Bring \(store.stale.count == 1 ? "it" : "them") into today?")
                .font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
            HStack(spacing: 8) {
                Button("Move to today") { withAnimation { store.carryStale() } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(Palette.ink, in: Capsule())
                Button("Leave in history") { withAnimation { store.dismissStale() } }
                    .buttonStyle(.plain).font(.system(size: 12))
                Button("Plan in Planner") { PlannerWindow.shared.show(planning: true) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// "Choose a time…" for a reminder.
struct ReminderPicker: View {
    let title: String
    let initial: Date
    let done: (Date?) -> Void
    @State private var date = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remind me").font(.headline)
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            DatePicker("", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute]).labelsHidden()
            Divider()
            HStack {
                Button("Cancel") { done(nil) }
                Spacer()
                Button("Set reminder") { done(date) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 280)
        .onAppear { date = max(initial, .now.addingTimeInterval(60)) }
    }
}

extension Store {
    func delete(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        ReminderService.shared.cancel(id)
        if focusTaskID == id { focusTaskID = nil }
    }
}

// MARK: - Focus

struct FocusCard: View {
    let store: Store
    @State private var showSetTime = false

    var body: some View {
        Card(color: Palette.lavender, drag: .focus) {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                VStack(spacing: 8) {
                    DotMatrix(text: clock(store.display(at: ctx.date)), dot: 3.6).padding(.top, Metrics.stack)
                    Text(status).font(.system(size: 12)).foregroundStyle(Palette.inkSoft).lineLimit(1)
                    GeometryReader { g in
                        // Stopwatch fills against the default duration as a gentle target.
                        let goal = store.isStopwatch ? TimeInterval(store.focusMinutes * 60) : store.focusTotal
                        let done = goal > 0 ? min(1, store.spent(at: ctx.date) / goal) : 0
                        Capsule().fill(.black.opacity(0.12))
                            .overlay(alignment: .leading) { Capsule().fill(Palette.ink).frame(width: g.size.width * done) }
                    }
                    .frame(height: 3).padding(.horizontal, 10)
                }
                .frame(maxWidth: .infinity)
            }
            Spacer()
            HStack(spacing: 6) {
                Button(action: primary) {
                    Label(primaryTitle, systemImage: primaryIcon).font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Color(red: 0.45, green: 0.42, blue: 0.62), in: Capsule())
                }
                Button { store.completeFocus() } label: {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).frame(width: 32, height: 32)
                        .background(Color(red: 0.45, green: 0.42, blue: 0.62), in: Circle())
                }
                .help("Complete focused task")
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            HStack(spacing: 8) {
                Button { showSetTime = true } label: { Label("Set time", systemImage: "slider.horizontal.3").font(.system(size: 12)) }
                    .disabled(store.isStopwatch).opacity(store.isStopwatch ? 0.4 : 1)
                    .popover(isPresented: $showSetTime, arrowEdge: .bottom) {
                        SetTimeView(subtitle: store.focusTask?.title, initial: store.focusMinutes,
                                     onSave: { store.setDuration($0) },
                                     onStart: { store.setDuration($0); store.endSession(); store.start() },
                                     shown: $showSetTime)
                    }
                if store.focusState != .ready {
                    Menu {
                        Button("End focus session") { store.endSession() }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            .buttonStyle(.plain).frame(maxWidth: .infinity)
        }
    }

    var status: String {
        switch store.focusState {
        case .ready: store.breakSuggested ? "Time for a break ☕︎" : store.isStopwatch ? "Stopwatch ready" : "Ready"
        case .running: store.focusTask?.title ?? "Focusing"
        case .paused: "Paused"
        case .finished: "Time's up"
        }
    }
    var primaryTitle: String {
        switch store.focusState { case .ready: "Start"; case .running: "Pause"; case .paused: "Resume"; case .finished: "Add 5 min" }
    }
    var primaryIcon: String {
        switch store.focusState { case .ready, .paused: "play.fill"; case .running: "pause.fill"; case .finished: "plus" }
    }
    func primary() {
        switch store.focusState {
        case .ready, .paused: store.start()
        case .running: store.pause()
        case .finished: store.addFiveMinutes()
        }
    }
}

/// "Focus duration" popover, used by the Focus card (default duration) and a task's Set Time Limit.
struct SetTimeView: View {
    let subtitle: String?
    let initial: Int
    let onSave: (Int) -> Void
    let onStart: (Int) -> Void
    @Binding var shown: Bool
    @State private var minutes = 25

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Focus duration").font(.headline)
            if let subtitle { Text(subtitle).foregroundStyle(.secondary).lineLimit(1) }
            Picker("", selection: $minutes) {
                ForEach([15, 25, 45, 60], id: \.self) { Text("\($0)m").tag($0) }
                if ![15, 25, 45, 60].contains(minutes) { Text("\(minutes)m").tag(minutes) }
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack {
                Text("Custom")
                Spacer()
                TextField("", value: $minutes, format: .number).frame(width: 44).multilineTextAlignment(.trailing)
                Text("min").foregroundStyle(.secondary)
                Stepper("", value: $minutes, in: 1...240).labelsHidden()
            }
            Text("Your timer starts when you begin focusing.").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Cancel") { shown = false }
                Spacer()
                Button("Save") { onSave(minutes); shown = false }.keyboardShortcut(.defaultAction)
                Button("Start") { onStart(minutes); shown = false }
            }
        }
        .padding(16).frame(width: 290)
        .onAppear { minutes = initial }
    }
}

// MARK: - Notepad

struct NotepadCard: View {
    @Bindable var store: Store
    var field: FocusState<Field?>.Binding

    var body: some View {
        Card(color: Palette.olive, drag: .notepad) {
            CardHeader(icon: "square.and.pencil", title: "Notepad")
            Text(Date.now.formatted(.dateTime.month(.abbreviated).day().year()))
                .font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
            Rectangle().fill(.black.opacity(0.12)).frame(height: 1)
            ZStack(alignment: .topLeading) {
                if store.notes.isEmpty {
                    Text("Write something down…").foregroundStyle(Palette.inkSoft).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: $store.notes).scrollContentBackground(.hidden).focused(field, equals: .notes)
                    .onKeyPress(.return, phases: .down) { press in
                        press.modifiers.contains(.command) && lineToTask() ? .handled : .ignored
                    }
            }
            .font(.system(size: 13))
            HStack {
                Label("\(wordCount(store.notes)) words", systemImage: "text.alignleft")
                Spacer()
                Text("⌘↩ makes a task").help("Press Command–Return to turn the current line into a task")
            }
            .font(.system(size: 11)).foregroundStyle(Palette.inkSoft)
        }
    }
}

extension NotepadCard {
    /// ⌘↩: moves the line under the cursor into Today's tasks.
    func lineToTask() -> Bool {
        guard let tv = NSApp.windows.first(where: \.isKeyWindow)?.firstResponder as? NSTextView,
              let (line, rest) = takeLine(tv.string, at: tv.selectedRange().location) else { return false }
        store.add(line)
        store.notes = rest
        return true
    }
}

/// The trimmed line containing `location` and the text without it; nil for a blank line.
func takeLine(_ text: String, at location: Int) -> (String, String)? {
    let ns = text as NSString
    let range = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
    let line = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? nil : (line, ns.replacingCharacters(in: range, with: ""))
}

// MARK: - Events

struct EventsCard: View {
    let store: Store

    var body: some View {
        Card(color: Palette.blue, drag: .events) {
            HStack {
                CardHeader(icon: "calendar", title: "Events")
                Spacer()
                Menu {
                    Button("Open in Calendar") { NSWorkspace.shared.open(URL(string: "ical://")!) }
                    Button("Refresh") { store.loadEvents() }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            let reminders = store.reminders
            if reminders.isEmpty && (!store.calendarAccess || store.events.isEmpty) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: store.calendarAccess ? "calendar" : "calendar.badge.plus").font(.system(size: 20))
                    Text(store.calendarAccess ? "Nothing scheduled" : "Calendar access").font(.system(size: 14, weight: .semibold))
                    Text(store.calendarAccess ? "No events in your selected calendars for today." : "Show today's events here.")
                        .font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
                    if !store.calendarAccess { Button("Connect Calendar") { store.connectCalendar() } }
                }
                .padding(.top, Metrics.stack)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !reminders.isEmpty {
                            section("Reminders")
                            ForEach(reminders) { reminderTile($0) }
                        }
                        if store.calendarAccess && !store.events.isEmpty {
                            HStack {
                                section("Today")
                                Spacer()
                                Text(Date.now.formatted(.dateTime.weekday(.abbreviated).day())).font(.system(size: 10)).foregroundStyle(Palette.inkSoft)
                            }
                            .padding(.top, reminders.isEmpty ? 0 : Metrics.stack)
                            ForEach(store.events, id: \.eventIdentifier) { eventTile($0) }
                        }
                        if !store.calendarAccess {
                            Button("Connect Calendar") { store.connectCalendar() }.font(.system(size: 12)).padding(.top, Metrics.stack)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            if store.calendarAccess {
                HStack {
                    Label("Connected", systemImage: "checkmark.circle").font(.system(size: 12))
                    Spacer()
                    Button { store.loadEvents() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh")
                }
            }
        }
    }

    func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.inkSoft)
    }

    func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func reminderTile(_ t: TaskItem) -> some View {
        tile {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text(reminderLabel(t.reminder!)).font(.system(size: 11)).foregroundStyle(Palette.inkSoft)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Mark as Done") { store.toggle(t.id) }
                    Button("Remove reminder", role: .destructive) { store.setReminder(t.id, at: nil) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
    }

    func eventTile(_ e: EKEvent) -> some View {
        let now = Date.now
        let live = !e.isAllDay && e.startDate <= now && now < e.endDate
        return tile {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Color(cgColor: e.calendar.cgColor)).frame(width: 3).frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title ?? "Untitled").font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text(e.isAllDay ? "All day" : "\(e.startDate.formatted(date: .omitted, time: .shortened)) – \(e.endDate.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(Palette.inkSoft)
                    if live { Text("Happening now").font(.system(size: 11, weight: .semibold)) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
