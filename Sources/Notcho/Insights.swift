import SwiftUI

// MARK: - Stats (pure)

struct DayStat: Identifiable {
    let date: Date
    var completed = 0
    var planned = 0
    var focusSeconds: TimeInterval = 0
    var id: Date { date }
}

struct InsightStats {
    var days: [DayStat]          // oldest → today, 7 entries
    var completed: Int
    var planned: Int             // distinct tasks on the list at some point this week
    var focusSeconds: TimeInterval
    var activeDays: Int
    var streak: Int
}

enum Insights {
    static func compute(tasks: [TaskItem], focusLog: [FocusEntry], now: Date = .now,
                        calendar cal: Calendar = .current, weekendsInStreak: Bool = false, dayStartHour: Int = 0) -> InsightStats {
        // A day that starts at 6 AM: shift every moment back 6 h, then use plain calendar days.
        let shift = -Double(dayStartHour) * 3600
        let tasks = tasks.map { t in
            var t = t
            t.completedAt = t.completedAt?.addingTimeInterval(shift); t.createdAt = t.createdAt?.addingTimeInterval(shift)
            return t
        }
        let focusLog = focusLog.map { FocusEntry(date: $0.date.addingTimeInterval(shift), seconds: $0.seconds) }
        let today = cal.startOfDay(for: now.addingTimeInterval(shift))
        let starts = (0..<7).reversed().map { cal.date(byAdding: .day, value: -$0, to: today)! }

        func created(_ t: TaskItem) -> Date { cal.startOfDay(for: t.createdAt ?? min(t.completedAt ?? today, today)) }
        /// On the list that day: created by then, scheduled by then, and not finished before it.
        func planned(_ t: TaskItem, on day: Date) -> Bool {
            let start = max(created(t), t.day ?? .distantPast)
            guard start <= day else { return false }
            if let dismissed = t.dismissedAt, day >= dismissed { return false } // left in history
            guard let done = t.completedAt else { return true }
            return cal.startOfDay(for: done) >= day
        }
        func completed(on day: Date) -> Int { tasks.filter { $0.completedAt.map { cal.isDate($0, inSameDayAs: day) } ?? false }.count }
        func focus(on day: Date) -> TimeInterval { focusLog.filter { cal.isDate($0.date, inSameDayAs: day) }.reduce(0) { $0 + $1.seconds } }

        let days = starts.map { d in
            DayStat(date: d, completed: completed(on: d), planned: tasks.filter { planned($0, on: d) }.count, focusSeconds: focus(on: d))
        }
        let plannedIDs = Set(starts.flatMap { d in tasks.filter { planned($0, on: d) }.map(\.id) })

        // Streak: consecutive active days back from today. Today without activity yet doesn't break it;
        // weekends are skipped unless they count.
        var streak = 0
        var day = today
        for _ in 0..<366 {
            let active = completed(on: day) > 0 || focus(on: day) > 0
            if active { streak += 1 }
            else if cal.isDateInWeekend(day) && !weekendsInStreak {}
            else if day != today { break }
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }

        return InsightStats(days: days, completed: days.reduce(0) { $0 + $1.completed }, planned: plannedIDs.count,
                            focusSeconds: days.reduce(0) { $0 + $1.focusSeconds },
                            activeDays: days.filter { $0.completed > 0 || $0.focusSeconds > 0 }.count, streak: streak)
    }
}

extension Insights {
    /// Focus seconds per project since a date (nil = tasks without a project, or no task picked).
    static func timeByProject(tasks: [TaskItem], focusLog: [FocusEntry], since: Date) -> [(UUID?, TimeInterval)] {
        let projectOf = Dictionary(tasks.map { ($0.id, $0.projectID) }, uniquingKeysWith: { a, _ in a })
        var sums: [UUID?: TimeInterval] = [:]
        for e in focusLog where e.date >= since { sums[e.taskID.flatMap { projectOf[$0] ?? nil }, default: 0] += e.seconds }
        return sums.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }
}

func durationText(_ seconds: TimeInterval) -> String {
    let m = Int(seconds / 60)
    return m < 60 ? "\(m)m" : (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m")
}

// MARK: - View

struct InsightsView: View {
    let store: Store
    @State private var metric = 0          // 0 = Tasks, 1 = Focus
    @State private var selected: Date?

    var body: some View {
        let s = Insights.compute(tasks: store.tasks, focusLog: store.focusLog,
                                 weekendsInStreak: store.settings.weekendsInStreak, dayStartHour: store.settings.dayStartHour)
        GeometryReader { geo in
            HStack(spacing: Metrics.cardGap) {
                summary(s).frame(width: (geo.size.width - Metrics.cardGap) * 0.32)
                chartCard(s)
            }
        }
    }

    func summary(_ s: InsightStats) -> some View {
        Card(color: Tone.tasks) {
            Text("Last 7 days").font(.title3.weight(.semibold))
            Text("\(s.completed)").font(.system(size: 40, weight: .bold))
            Text("Tasks completed").font(.title3.weight(.semibold))
            GeometryReader { g in
                Capsule().fill(Tone.ink.opacity(0.1)).overlay(alignment: .leading) {
                    Capsule().fill(Tone.ink).frame(width: s.planned == 0 ? 0 : g.size.width * CGFloat(s.completed) / CGFloat(max(s.planned, s.completed)))
                }
            }
            .frame(height: 6)
            Text("of \(s.planned) planned").font(.callout).foregroundStyle(Tone.inkSoft)
            Rectangle().fill(Tone.ink.opacity(0.1)).frame(height: 1)
            VStack(spacing: 10) {
                stat("timer", "Focus time", durationText(s.focusSeconds))
                stat("calendar", "Active days", "\(s.activeDays) of 7")
                stat("flame", "Current streak", "\(s.streak)d")
            }
        }
    }

    func stat(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 18)
            Text(label)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .font(.body)
    }

    func chartCard(_ s: InsightStats) -> some View {
        let values = s.days.map { metric == 0 ? Double(max($0.planned, $0.completed)) : $0.focusSeconds / 60 }
        let top = niceMax(values.max() ?? 0, minutes: metric == 1)
        return Card(color: Tone.focus) {
            HStack {
                HStack(spacing: 2) {
                    ForEach(["Tasks", "Focus", "Projects"].indices, id: \.self) { i in
                        Button { metric = i } label: {
                            Text(["Tasks", "Focus", "Projects"][i]).font(.callout.weight(.semibold))
                                .foregroundStyle(metric == i ? Tone.onButton : Tone.ink.opacity(0.7))
                                .padding(.horizontal, 14).padding(.vertical, 5)
                                .background(metric == i ? Tone.button : .clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3).background(Tone.ink.opacity(0.1), in: Capsule())
                Spacer()
                Text(headerText(s)).font(.callout).foregroundStyle(Tone.inkSoft)
            }

            if metric == 2 { projectBars } else {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(s.days) { d in
                    VStack(spacing: 4) {
                        GeometryReader { g in
                            let h = g.size.height
                            ZStack(alignment: .bottom) {
                                if metric == 0 {
                                    RoundedRectangle(cornerRadius: 3).fill(Tone.ink.opacity(0.13))
                                        .frame(height: h * CGFloat(Double(d.planned) / top))
                                    RoundedRectangle(cornerRadius: 3).fill(Tone.ink)
                                        .frame(height: h * CGFloat(Double(d.completed) / top))
                                } else {
                                    RoundedRectangle(cornerRadius: 3).fill(Tone.ink)
                                        .frame(height: h * CGFloat(d.focusSeconds / 60 / top))
                                }
                            }
                            .frame(width: min(26, g.size.width), height: h, alignment: .bottom)
                            .frame(maxWidth: .infinity)
                            .opacity(selected == nil || selected == d.date ? 1 : 0.45)
                        }
                        Text(d.date.formatted(.dateTime.weekday(.abbreviated))).font(.subheadline)
                        Text(d.date.formatted(.dateTime.day())).font(.subheadline).foregroundStyle(Tone.inkSoft)
                    }
                    .fontWeight(selected == d.date || Calendar.current.isDateInToday(d.date) ? .semibold : .regular)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = selected == d.date ? nil : d.date }
                }
                // y-axis
                VStack(alignment: .trailing) {
                    Text(axisLabel(top)); Spacer(); Text(axisLabel(top / 2)); Spacer(); Text("0")
                }
                .font(.footnote).foregroundStyle(Tone.inkSoft).padding(.bottom, 32).frame(width: 26)
            }

            HStack(spacing: 14) {
                legend(Tone.ink, metric == 0 ? "Completed" : "Focus minutes")
                if metric == 0 { legend(Tone.ink.opacity(0.13), "Planned") }
                Spacer()
                Menu {
                    Button("All week") { selected = nil }
                    Divider()
                    ForEach(s.days) { d in Button(d.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) { selected = d.date } }
                } label: { Text(selected == nil ? "Select a day" : selected!.formatted(.dateTime.weekday(.abbreviated).day())).font(.callout) }
                .menuStyle(.borderlessButton).fixedSize()
            }
            }
        }
    }

    /// Focus time per project over the last 7 days, longest first.
    var projectBars: some View {
        let rows = Insights.timeByProject(tasks: store.tasks, focusLog: store.focusLog,
                                          since: Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: .now))!)
        let top = rows.map(\.1).max() ?? 1
        return VStack(alignment: .leading, spacing: 9) {
            if rows.isEmpty {
                Text("No focus time this week yet. Start the Focus timer on a task and it shows up here by project.")
                    .font(.callout).foregroundStyle(Tone.inkSoft)
            }
            ForEach(rows.prefix(6), id: \.0) { id, seconds in
                let p = store.projects.first { $0.id == id }
                HStack(spacing: 10) {
                    Text(p?.name ?? "No project").font(.callout).lineLimit(1).frame(width: 130, alignment: .leading)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 3).fill(p.map { Palette.named($0.color).opacity(1) } ?? Tone.ink.opacity(0.3))
                            .brightness(-0.08)
                            .frame(width: max(4, g.size.width * CGFloat(seconds / top)))
                    }
                    .frame(height: 12)
                    Text(durationText(seconds)).font(.callout.weight(.semibold).monospacedDigit()).frame(width: 56, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text).font(.callout)
        }
    }

    func headerText(_ s: InsightStats) -> String {
        if let day = selected, let d = s.days.first(where: { $0.date == day }) {
            let label = day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            return metric == 0 ? "\(label) · \(d.completed) of \(d.planned) done" : "\(label) · \(durationText(d.focusSeconds)) focus"
        }
        if metric == 2 { return "Focus by project · last 7 days" }
        let f = Date.FormatStyle().month(.abbreviated).day()
        return "\(s.days.first!.date.formatted(f)) – \(s.days.last!.date.formatted(f))"
    }

    /// Round the axis top up: whole tasks (≥ 4), or 30/60/… minutes for focus.
    func niceMax(_ v: Double, minutes: Bool) -> Double {
        minutes ? max(30, (v / 30).rounded(.up) * 30) : max(4, v.rounded(.up))
    }

    func axisLabel(_ v: Double) -> String {
        metric == 1 ? durationText(v * 60) : (v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v))
    }
}
