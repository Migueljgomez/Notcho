import AppKit
import EventKit
import SwiftUI

struct CustomizeView: View {
    @Bindable var store: Store
    @State private var loginOn = LoginItem.enabled
    @State private var loginError: String?

    var body: some View {
        GeometryReader { geo in
            let w = (geo.size.width - 2 * Metrics.cardGap) / 3
            HStack(spacing: Metrics.cardGap) {
                general.frame(width: w)
                focus.frame(width: w)
                workspace
            }
        }
    }

    // MARK: General

    var general: some View {
        Card(color: Tone.tasks) {
            CardHeader(icon: "slider.horizontal.3", title: "General")
            ScrollView { VStack(spacing: Metrics.stack) {
                row("Launch at login") {
                    Toggle("", isOn: Binding(get: { loginOn }, set: { loginError = LoginItem.set($0); loginOn = LoginItem.enabled }))
                        .toggleStyle(.switch).labelsHidden()
                }
                row("Open shortcut") {
                    Picker("", selection: $store.settings.shortcut) {
                        ForEach(Shortcut.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: store.settings.shortcut) { HotKey.register(store.settings.shortcut) }
                }
                row("Close after") {
                    Slider(value: $store.settings.closeAfter, in: 0...Settings.stayOpen, step: 0.25).frame(width: 110)
                    Text(closeLabel).font(.callout.monospacedDigit()).frame(width: 64, alignment: .trailing)
                }
                .help("How long the notch stays open after your pointer leaves it")
                row("Appearance") {
                    Picker("", selection: $store.settings.notchLook) {
                        ForEach(NotchLook.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                .help("Match my Mac: pastel in Light mode, the dark island in Dark mode")
                Dotted()
                Text("Your day").font(.body.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                row("Day starts at") {
                    Picker("", selection: $store.settings.dayStartHour) {
                        ForEach(0..<12) { h in Text(hourLabel(h)).tag(h) }
                    }
                    .labelsHidden().fixedSize()
                }
                row("Unfinished tasks") {
                    Picker("", selection: $store.settings.unfinished) {
                        ForEach(Unfinished.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .help("What happens to yesterday's unfinished tasks when a new day starts")
                    .onChange(of: store.settings.unfinished) { store.rollover() }
                }
                row("Workday ends at") {
                    Picker("", selection: $store.settings.workdayEndHour) {
                        ForEach(12...23, id: \.self) { h in
                            Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now)!.formatted(date: .omitted, time: .shortened)).tag(h)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .help("The Planner's workload meter counts the time left until then")
                }
                row("Daily wrap-up at") {
                    Picker("", selection: $store.settings.wrapUpHour) {
                        Text("Off").tag(0)
                        ForEach(14...21, id: \.self) { h in
                            Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now)!.formatted(date: .omitted, time: .shortened)).tag(h)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .help("A banner that opens the wrap-up: review the day, move what's left, note highlights")
                }
                row("Break nudge after") {
                    Picker("", selection: $store.settings.breakAfterMinutes) {
                        Text("Off").tag(0)
                        ForEach([45, 60, 90, 120], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .help("After this much unbroken focus, the notch suggests a break")
                }
                row("Weekends in streak") {
                    Toggle("", isOn: $store.settings.weekendsInStreak).toggleStyle(.switch).labelsHidden()
                }
                Dotted()
                row("Sync with Apple Reminders") {
                    Toggle("", isOn: Binding(get: { store.settings.syncReminders }, set: setReminderSync))
                        .toggleStyle(.switch).labelsHidden()
                }
                .help("Tasks appear in a Notch list in Reminders, which iCloud syncs to your iPhone. Changes there come back here.")
                if !store.syncStatus.isEmpty {
                    Text(store.syncStatus).font(.subheadline)
                        .foregroundStyle(store.syncStatus.hasPrefix("Synced") ? Tone.inkSoft : .red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let loginError { Text(loginError).font(.subheadline).foregroundStyle(.red) }
            } }
            .scrollIndicators(.never)
        }
    }

    /// On: ask for Reminders access, create the Notch list, stop the notch's own notifications, sync.
    /// Off: pause sync (links are kept) and go back to the notch's own notifications.
    func setReminderSync(_ on: Bool) {
        if on {
            RemindersSync.shared.enable { problem in
                if let problem { store.syncStatus = problem; return }
                store.settings.syncReminders = true
                ReminderService.shared.paused = true
                ReminderService.shared.cancelAll()
                RemindersSync.shared.syncNow()
            }
        } else {
            store.settings.syncReminders = false
            ReminderService.shared.paused = false
            RemindersSync.shared.disable()
            store.tasks.forEach { ReminderService.shared.sync($0) }
        }
    }

    // MARK: Focus

    var focus: some View {
        Card(color: Tone.focus) {
            CardHeader(icon: "timer", title: "Focus")
            VStack(spacing: Metrics.stack) {
                row("Default timer") {
                    Picker("", selection: Binding(get: { store.settings.stopwatch }, set: { on in
                        store.endSession() // a running session keeps its own mode, so end it first
                        store.settings.stopwatch = on
                    })) {
                        Text("Countdown").tag(false)
                        Text("Stopwatch").tag(true)
                    }
                    .labelsHidden().fixedSize()
                }
                row("Duration") {
                    HStack(spacing: 10) {
                        Button { store.setDuration(store.focusMinutes - 5) } label: { Image(systemName: "minus") }
                        Text("\(store.focusMinutes) min").monospacedDigit().frame(minWidth: 52)
                        Button { store.setDuration(store.focusMinutes + 5) } label: { Image(systemName: "plus") }
                    }
                    .buttonStyle(.plain).font(.body.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Tone.wash, in: RoundedRectangle(cornerRadius: 8))
                    .disabled(store.isStopwatch).opacity(store.isStopwatch ? 0.4 : 1)
                }
                row("Completion sound") {
                    Toggle("", isOn: $store.settings.completionSound).toggleStyle(.switch).labelsHidden()
                }
                Text("A task's time limit overrides the default.").font(.callout).foregroundStyle(Tone.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Dotted()
                HStack {
                    Text("Permissions").font(.body.weight(.semibold))
                    Spacer()
                    Text("v1.0").font(.callout).foregroundStyle(Tone.inkSoft)
                }
                HStack(spacing: 14) {
                    Label("Calendar: \(store.calendarAccess ? "On" : "Off")", systemImage: "calendar")
                    Button {
                        if store.notificationsOn {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                        } else {
                            ReminderService.shared.requestAccess { ok in
                                store.notificationsOn = ok
                                // Already denied: macOS won't ask again, so open Settings instead.
                                if !ok { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!) }
                            }
                        }
                    } label: { Label("Notifications: \(store.notificationsOn ? "On" : "Off")", systemImage: "bell") }
                    .buttonStyle(.plain).help(store.notificationsOn ? "Notification settings" : "Enable notifications")
                    Spacer()
                }
                .font(.callout).foregroundStyle(Tone.inkSoft)
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                } label: {
                    Label("Open App Settings", systemImage: "arrow.up.right").labelStyle(TrailingIcon())
                        .font(.callout.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Tone.wash, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Workspace

    var workspace: some View {
        Card(color: Tone.events) {
            CardHeader(icon: "rectangle.3.group", title: "Customize workspace")
            Text("Drag to reorder. Toggle to show or hide.").font(.callout).foregroundStyle(Tone.inkSoft)
            List {
                ForEach(store.settings.orderedCards) { kind in
                    let visible = !store.settings.hiddenCards.contains(kind)
                    HStack(spacing: 10) {
                        Image(systemName: kind.icon).frame(width: 18)
                        Text(kind.title).font(.body)
                        Spacer()
                        Toggle("", isOn: Binding(get: { visible }, set: { on in
                            if on { store.settings.hiddenCards.remove(kind) } else { store.settings.hiddenCards.insert(kind) }
                        }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                        .disabled(visible && store.settings.visibleCards.count == 1) // keep at least one card
                        Image(systemName: "line.3.horizontal").foregroundStyle(Tone.inkSoft)
                    }
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                .onMove { from, to in
                    var order = store.settings.orderedCards
                    order.move(fromOffsets: from, toOffset: to)
                    store.settings.cardOrder = order
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).scrollDisabled(true).foregroundStyle(Tone.ink)
            Text("Hidden cards keep their content.").font(.callout).foregroundStyle(Tone.inkSoft)
            Button("Reset layout") { withAnimation(.snappy) { store.settings.resetLayout() } }
            .buttonStyle(.plain).font(.callout).foregroundStyle(Tone.inkSoft)
        }
    }

    // MARK: Helpers

    func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label).font(.body)
            Spacer()
            control()
        }
    }

    var closeLabel: String {
        let s = store.settings.closeAfter
        return s >= Settings.stayOpen ? "Stay open" : s == 0 ? "Instant" : String(format: "%g s", s)
    }

    func hourLabel(_ h: Int) -> String {
        let date = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now)!
        return date.formatted(date: .omitted, time: .shortened)
    }
}

struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon }
    }
}

// MARK: - Planner → Workspace: the notch layout, with a live preview

struct WorkspaceSettings: View {
    @Bindable var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Workspace").font(.title.weight(.bold))
                Text("How the notch looks when it opens. You can also drag the dots on a card to move it, drag the space between cards to resize them, and drag the bottom edge to change the height.")
                    .font(.body).foregroundStyle(Palette.pInkSoft).fixedSize(horizontal: false, vertical: true)

                // Preview at the real proportions
                GeometryReader { geo in
                    let cards = store.settings.visibleCards
                    let frames = cardFrames(cards.map(store.settings.weight), width: geo.size.width - 16, gap: 5)
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(cards.enumerated()), id: \.element) { i, kind in
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(kind.color)
                                .overlay(Image(systemName: kind.icon).font(.body.weight(.semibold)).foregroundStyle(Tone.ink))
                                .frame(width: frames[i].width).offset(x: frames[i].x)
                        }
                    }
                    .padding(8)
                    .background(.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .frame(height: min(store.settings.panelHeight / 4, 150))
                .animation(.snappy, value: store.settings)

                VStack(alignment: .leading, spacing: 6) {
                    Text("CARDS").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
                    List {
                        ForEach(store.settings.orderedCards) { kind in
                            let visible = !store.settings.hiddenCards.contains(kind)
                            HStack(spacing: 10) {
                                Image(systemName: "line.3.horizontal").foregroundStyle(Palette.pInkSoft)
                                Circle().fill(kind.color).frame(width: 10, height: 10)
                                Text(kind.title).font(.body)
                                Spacer()
                                Toggle("", isOn: Binding(get: { visible }, set: { on in
                                    if on { store.settings.hiddenCards.remove(kind) } else { store.settings.hiddenCards.insert(kind) }
                                }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                                .disabled(visible && store.settings.visibleCards.count == 1) // keep at least one card
                            }
                            .padding(.vertical, 4)
                        }
                        .onMove { from, to in
                            var order = store.settings.orderedCards
                            order.move(fromOffsets: from, toOffset: to)
                            store.settings.cardOrder = order
                        }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden).scrollDisabled(true)
                    .frame(height: CGFloat(CardKind.allCases.count) * 34)
                    Text("Drag to reorder. Hidden cards keep their content.").font(.callout).foregroundStyle(Palette.pInkSoft)
                }
                .padding(14).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 6) {
                    Text("APPEARANCE").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
                    Picker("", selection: $store.settings.notchLook) {
                        ForEach(NotchLook.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text("Match my Mac: pastel in Light mode, the dark island in Dark mode.").font(.callout).foregroundStyle(Palette.pInkSoft)
                }
                .padding(14).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 6) {
                    Text("PANEL HEIGHT").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.pInkSoft)
                    HStack {
                        Slider(value: $store.settings.panelHeight, in: 240...700, step: 10)
                        Text("\(Int(store.settings.panelHeight)) px").font(.callout.monospacedDigit()).frame(width: 52, alignment: .trailing)
                    }
                }
                .padding(14).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))

                Button { withAnimation(.snappy) { store.settings.resetLayout() } } label: {
                    Label("Reset layout", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(Pill(fill: Palette.pWash))
                .help("Card order, widths, visibility and height back to the default")
            }
            .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 28)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .foregroundStyle(Palette.pInk)
    }
}
