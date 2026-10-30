import AppKit
import EventKit
import SwiftUI

// MARK: - UI state shared with the controller

enum Page: String, CaseIterable { case workspace = "Workspace", insights = "Insights", customize = "Customize" }

@Observable final class NotchModel {
    var expanded = false
    var editing = false            // a text field has focus: don't collapse on hover-out
    var dragging = false           // moving or resizing a card, or the panel: don't collapse
    var setHeight: (CGFloat) -> Void = { _ in }  // the controller resizes the panel window
    var setWidth: (CGFloat) -> Void = { _ in }
    var applyLook: () -> Void = {}                // the controller sets the panel's appearance
    var page = Page.workspace
    var collapsed = CGSize(width: 200, height: 32)
    var workspace = CGSize(width: 820, height: 330)
    var notchOffsetX: CGFloat = 0  // notch centre relative to panel centre
    var pill = CGRect(x: 0, y: 0, width: 90, height: 30) // relative to panel top-left
    var quip: String?              // the goodbye shown where the timer was, for 2 s after Stop
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
    static let outer: CGFloat = 16         // panel edge → cards (Planner and settings layouts)
    static let ear: CGFloat = 10           // NotchShape's top curves: the black body starts this far in from the window edge
    static let inset: CGFloat = 12         // black edge → cards, on the sides and the bottom
    static let minCard: CGFloat = 140
    static let pagePopup: CGFloat = 112    // the folded Workspace · Insights · Customize button
    static let pageTabs: CGFloat = 308     // the full tab bar plus ✕
    /// Narrowest panel: the folded page button must fit beside the notch.
    static func minPanelWidth(notch: CGFloat) -> CGFloat { notch + 2 * (ear + inset + pagePopup) }
    /// True when `count` cards fit side by side in `width` at `minCard` each.
    static func fits(_ count: Int, in width: CGFloat) -> Bool { CGFloat(count) * minCard + CGFloat(max(count - 1, 0)) * cardGap <= width }
    /// Narrowest panel that keeps `cards` cards at `minCard` each.
    static func minWidth(cards: Int) -> CGFloat {
        let n = CGFloat(max(cards, 1))
        return n * minCard + (n - 1) * cardGap + 2 * (ear + inset)
    }
    static let rail: CGFloat = 50          // the icon rail plus its gap
    /// Which cards stay side by side in `width`, and which step aside into the rail or chips.
    /// `pick` (a card clicked in the rail) is kept over the others, swapping out its neighbor.
    static func arrange(_ cards: [CardKind], width: CGFloat, rail: Bool, pick: CardKind?) -> (shown: [CardKind], aside: [CardKind]) {
        func need(_ c: [CardKind]) -> CGFloat { c.map(\.comfort).reduce(0, +) + CGFloat(max(c.count - 1, 0)) * cardGap }
        if need(cards) <= width { return (cards, []) }
        let room = width - (rail ? self.rail : 0)
        var shown = cards
        for c in CardKind.dropOrder where c != pick && shown.count > 1 && need(shown) > room { shown.removeAll { $0 == c } }
        return (shown, cards.filter { !shown.contains($0) })
    }
    static let cardGap: CGFloat = 12       // between cards, and header → cards
    static let cardPadding: CGFloat = 16   // card edge → content
    static let cardRadius = Theme.cardRadius
    static let stack: CGFloat = 10         // between blocks inside a card
}

// MARK: - Shape: flat top, inward-curving top "ears", rounded bottom

struct NotchShape: Shape {
    func path(in r: CGRect) -> Path {
        let top = min(r.width * 0.125, Metrics.ear), bottom = min(r.height * 0.5, Theme.panelRadius)
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
    var color: Color = Tone.ink

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
        let pitch = dot * 1.5
        // Lay out every dot, then trim empty edge columns so the dots themselves center ("1" has a blank left column).
        var cells: [(col: Int, row: Int)] = [], x = 0
        for g in text.compactMap({ Self.glyphs[$0] }) {
            for (row, line) in g.enumerated() { for (col, bit) in line.enumerated() where bit == "1" { cells.append((x + col, row)) } }
            x += g[0].count + 1
        }
        let lo = cells.map(\.col).min() ?? 0, hi = cells.map(\.col).max() ?? 0
        return Canvas { ctx, _ in
            for c in cells {
                let r = CGRect(x: CGFloat(c.col - lo) * pitch, y: CGFloat(c.row) * pitch, width: dot, height: dot)
                ctx.fill(Path(ellipseIn: r), with: .color(color))
            }
        }
        .frame(width: CGFloat(hi - lo) * pitch + dot, height: 6 * pitch + dot)
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
                .id(store.settings.notchLook) // re-resolve every color when the look changes
                .frame(width: model.workspace.width, height: model.workspace.height)
                .opacity(model.expanded ? 1 : 0)
                .animation(model.expanded ? .easeOut(duration: 0.12).delay(0.2) : .easeOut(duration: 0.08), value: model.expanded)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(.black, in: NotchShape())
                .clipShape(NotchShape())
                .offset(x: model.expanded ? 0 : model.notchOffsetX)
                .frame(maxWidth: .infinity, alignment: .top)

            if store.focusState != .ready {
                TimerPill(model: model, store: store)
                    .offset(x: model.pill.minX, y: model.pill.minY)
                    .opacity(model.expanded ? 0 : 1)
                    .animation(.easeOut(duration: 0.12), value: model.expanded)
            } else if let quip = model.quip {
                Text(quip).font(.callout.weight(.semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 12).frame(height: model.pill.height).background(.black, in: Capsule())
                    .frame(maxWidth: model.workspace.width - model.pill.minX - 4, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                    .offset(x: model.pill.minX, y: model.pill.minY)
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: store.settings.notchLook) { model.applyLook() }
    }
}

/// The menu-bar timer beside the notch. Click: pause/resume. Right-click: Pause/Resume, Restart, Stop
/// (Customize → Timer menu). Hovering a paused one can show ✕ (Customize → Hover ✕ to stop, off by default).
struct TimerPill: View {
    let model: NotchModel
    let store: Store
    @State private var hover = false

    static let hoverWidth: CGFloat = 116

    var body: some View {
        let paused = store.focusState == .paused
        let showX = paused && hover && store.settings.timerHoverStop
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                DotMatrix(text: clock(store.display(at: ctx.date)), dot: 1.9, color: .white.opacity(paused ? 0.45 : 0.9)) // dim = paused
            }
            .contentShape(Rectangle())
            .onTapGesture { store.focusState == .running ? store.pause() : store.start() }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(store.focusState == .running ? "Pause" : "Resume")
            if showX {
                Button(action: stop) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 18, height: 18).background(.white.opacity(0.22), in: Circle())
                }
                .buttonStyle(.plain).help("Stop timer").accessibilityLabel("Stop timer")
            }
        }
        .frame(width: showX ? Self.hoverWidth : model.pill.width, height: model.pill.height)
        .background(.black, in: Capsule())
        .contentShape(Capsule())
        .frame(width: Self.hoverWidth, alignment: .leading) // room to widen; the controller lets this area take the pointer
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: showX)
        .contextMenu {
            if store.settings.timerMenu {
                Button(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") { paused ? store.start() : store.pause() }
                Button("Restart", systemImage: "arrow.counterclockwise") { store.restart() }
                Divider()
                Button("Stop timer", systemImage: "xmark", action: stop)
            }
        }
    }

    /// Ends the session and shows a cheeky goodbye where the timer was, for 2 seconds.
    func stop() {
        let line = store.stopTimer()
        let anim: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9)
        withAnimation(anim) { model.quip = line }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: line, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if model.quip == line { withAnimation(anim) { model.quip = nil } }
        }
    }
}

// MARK: - Workspace shell

enum Field: Hashable { case add, rename(UUID), notes }

struct WorkspaceView: View {
    @Bindable var model: NotchModel
    let store: Store
    let close: () -> Void
    @FocusState private var field: Field?

    @State private var pick: CardKind?

    var body: some View {
        // Black space beside the notch decides the top bar: full tabs, a folded button on the right, or on the left.
        let beside = (model.workspace.width - model.collapsed.width) / 2 - (Metrics.ear + Metrics.inset)
        VStack(spacing: Metrics.cardGap) {
            HStack(spacing: 10) {
                if beside < Metrics.pagePopup + 38 { pageMenu; Spacer() } else { Spacer() }
                if beside >= Metrics.pageTabs { PagePicker(page: $model.page) } else if beside >= Metrics.pagePopup + 38 { pageMenu }
                Button(action: close) {
                    Image(systemName: "xmark").font(.callout.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(.white.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain).help("Close").accessibilityLabel("Close")
            }
            .frame(height: 30)

            switch model.page {
            case .workspace:
                GeometryReader { geo in
                    let style = store.settings.compactStyle
                    let (shown, aside) = Metrics.arrange(store.settings.visibleCards, width: geo.size.width, rail: style == .rail, pick: pick)
                    if aside.isEmpty { sideBySide(shown, geo) } else {
                        Aside(style: style, items: { now in aside.map { deckItem($0, now) } },
                              pick: { id in withAnimation(.spring(response: 0.3, dampingFraction: 1)) { pick = CardKind(rawValue: id) } }) {
                            GeometryReader { inner in sideBySide(shown, inner) }
                        }
                    }
                }
            case .insights: InsightsView(store: store)
            case .customize: CustomizeView(store: store)
            }
        }
        // The black body starts `ear` in from the window edge (NotchShape's top curves); cards sit `inset` inside it on every side.
        .padding(.horizontal, Metrics.ear + Metrics.inset).padding(.top, 6).padding(.bottom, Metrics.inset)
        .overlay(alignment: .bottom) { heightHandle }
        .overlay(alignment: .leading) { widthHandle(side: -1) }
        .overlay(alignment: .trailing) { widthHandle(side: 1) }
        .overlay(alignment: .bottomLeading) { cornerHandle(side: -1) }
        .overlay(alignment: .bottomTrailing) { cornerHandle(side: 1) }
        .onChange(of: field) { model.editing = field != nil }
        .onChange(of: model.expanded) { if !model.expanded { field = nil } }
    }

    /// Workspace · Insights · Customize folded into one pop-up when the tabs don't fit beside the notch.
    var pageMenu: some View {
        Menu {
            ForEach(Page.allCases, id: \.self) { p in
                Button { model.page = p } label: { if p == model.page { Label(p.rawValue, systemImage: "checkmark") } else { Text(p.rawValue) } }
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.page.rawValue).font(.callout.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold))
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .environment(\.colorScheme, .dark).foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.white.opacity(0.12), in: Capsule())
        .frame(width: Metrics.pagePopup, alignment: .leading)
        .accessibilityLabel("Page: \(model.page.rawValue)")
    }

    /// One card's button in the compact rail or chip row, with live info.
    func deckItem(_ kind: CardKind, _ now: Date) -> DeckItem {
        switch kind {
        case .tasks:
            let n = store.todo.count
            return DeckItem(id: kind.rawValue, icon: kind.icon, tint: Tone.icon(kind), color: kind.color, title: "Tasks",
                            info: "\(n)", badge: n > 0 ? "\(n)" : nil)
        case .events:
            let left = store.events.filter { !$0.isAllDay && $0.endDate > now }
            return DeckItem(id: kind.rawValue, icon: kind.icon, tint: Tone.icon(kind), color: kind.color, title: "Events",
                            info: left.first?.startDate.formatted(date: .omitted, time: .shortened), badge: left.isEmpty ? nil : "\(left.count)")
        case .focus:
            let on = store.focusState != .ready
            return DeckItem(id: kind.rawValue, icon: kind.icon, tint: Tone.icon(kind), color: kind.color, title: "Focus",
                            info: on ? clock(store.display(at: now)) : nil, live: store.focusState == .running)
        case .notepad:
            return DeckItem(id: kind.rawValue, icon: kind.icon, tint: Tone.icon(kind), color: kind.color, title: "Notepad")
        }
    }

    /// The cards side by side, sized by their weights (the normal layout).
    @ViewBuilder func sideBySide(_ cards: [CardKind], _ geo: GeometryProxy) -> some View {
        let weights = cards.map(store.settings.weight)
        let frames = cardFrames(weights, width: geo.size.width, gap: Metrics.cardGap)
        let perPoint = weights.reduce(0, +) / (geo.size.width - Metrics.cardGap * CGFloat(cards.count - 1))
        ZStack(alignment: .topLeading) {
            ForEach(Array(cards.enumerated()), id: \.element) { i, kind in
                let lifted = moving == kind
                card(kind)
                    .frame(width: frames[i].width, height: geo.size.height)
                    .scaleEffect(lifted ? 1.02 : 1)
                    .shadow(color: .black.opacity(lifted ? 0.4 : 0), radius: 14, y: 6)
                    .offset(x: frames[i].x + (lifted ? moveOffset : 0))
                    .zIndex(lifted ? 1 : 0)
                    .transaction { if lifted { $0.animation = nil } } // the lifted card follows the pointer exactly
                    .environment(\.cardGrip) { grip(kind, $0, cards: cards, frames: frames) }
            }
            ForEach(cards.indices.dropLast(), id: \.self) { i in
                gap(cards[i], cards[i + 1], height: geo.size.height, perPoint: perPoint)
                    .offset(x: frames[i].x + frames[i].width)
            }
        }
        .coordinateSpace(name: "cards")
    }

    // MARK: Moving and resizing

    @State private var moving: CardKind?
    @State private var grabX: CGFloat = 0       // pointer → lifted card's left edge
    @State private var moveOffset: CGFloat = 0
    @State private var resizeStart: (CGFloat, CGFloat)?
    @State private var hoverGap: CardKind?
    @State private var heightStart: CGFloat?
    @State private var widthStart: (width: CGFloat, mouseX: CGFloat)?
    @State private var cornerStart: (width: CGFloat, height: CGFloat, mouse: CGPoint)?

    /// Dot handle dragged: the card follows the pointer and swaps with a neighbor once it passes that neighbor's middle.
    func grip(_ kind: CardKind, _ v: DragGesture.Value?, cards: [CardKind], frames: [(x: CGFloat, width: CGFloat)]) {
        guard let v, let i = cards.firstIndex(of: kind) else {
            model.dragging = false
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { moving = nil; moveOffset = 0 }
            return
        }
        if moving != kind { moving = kind; grabX = v.startLocation.x - frames[i].x; model.dragging = true }
        let left = v.location.x - grabX, middle = left + frames[i].width / 2
        var newX = frames[i].x, target: CardKind?
        if i + 1 < cards.count, middle > frames[i + 1].x + frames[i + 1].width / 2 {
            target = cards[i + 1]; newX = frames[i].x + frames[i + 1].width + Metrics.cardGap
        } else if i > 0, middle < frames[i - 1].x + frames[i - 1].width / 2 {
            target = cards[i - 1]; newX = frames[i - 1].x
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
            if let target { store.settings.move(kind, onto: target) }
            moveOffset = left - newX
        }
    }

    /// The space between two cards: drag to resize them, double-click to make them equal.
    func gap(_ l: CardKind, _ r: CardKind, height: CGFloat, perPoint: CGFloat) -> some View {
        Color.clear.frame(width: Metrics.cardGap, height: height).contentShape(Rectangle())
            .overlay { Capsule().fill(.white.opacity(hoverGap == l ? 0.4 : 0)).frame(width: 3, height: 40) }
            .onHover { inside in
                hoverGap = inside ? l : (hoverGap == l ? nil : hoverGap)
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onTapGesture(count: 2) {
                let even = Double(store.settings.weight(l) + store.settings.weight(r)) / 2
                withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
                    store.settings.cardWeights[l] = even; store.settings.cardWeights[r] = even
                }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("cards"))
                .onChanged { v in
                    if resizeStart == nil { resizeStart = (store.settings.weight(l), store.settings.weight(r)); model.dragging = true }
                    store.settings.resize(l, r, from: resizeStart!, by: v.translation.width, perPoint: perPoint, minWidth: Metrics.minCard)
                }
                .onEnded { _ in resizeStart = nil; model.dragging = false })
            .help("Drag to resize · double-click to make them equal")
    }

    /// Bottom edge: drag to make the panel taller or shorter, double-click for the default height.
    var heightHandle: some View {
        Capsule().fill(.white.opacity(heightStart != nil ? 0.5 : 0.2)).frame(width: 40, height: 4)
            .frame(width: 160, height: 14).contentShape(Rectangle())
            .onHover { if $0 { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .onTapGesture(count: 2) { model.setHeight(Metrics.panelHeight) }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if heightStart == nil { heightStart = CGFloat(store.settings.panelHeight); model.dragging = true }
                    model.setHeight(heightStart! + v.translation.height)
                }
                .onEnded { _ in heightStart = nil; model.dragging = false })
            .help("Drag to change the height · double-click to reset")
    }

    /// A side edge: drag to make the panel wider or narrower (both sides move, so it stays under the notch), double-click for the default.
    func widthHandle(side: CGFloat) -> some View {
        Capsule().fill(.white.opacity(widthStart != nil ? 0.5 : 0.2)).frame(width: 4, height: 40)
            .frame(width: Metrics.inset, height: 160).contentShape(Rectangle())
            .padding(side < 0 ? .leading : .trailing, Metrics.ear) // in the black strip between the edge and the cards
            .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .onTapGesture(count: 2) { model.setWidth(Metrics.panelWidth) }
            // The window moves as it resizes, so measure the pointer on screen, not in the view.
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { _ in
                    let x = NSEvent.mouseLocation.x
                    if widthStart == nil { widthStart = (CGFloat(store.settings.panelWidth), x); model.dragging = true }
                    model.setWidth(widthStart!.width + 2 * side * (x - widthStart!.mouseX))
                }
                .onEnded { _ in widthStart = nil; model.dragging = false })
            .help("Drag to change the width · double-click to reset")
    }

    /// A bottom corner: drag to change width and height together; double-click for the default size.
    func cornerHandle(side: CGFloat) -> some View {
        Canvas { ctx, _ in
            // Sits in the ring between the card corner (18) and the panel corner (30), which share a center.
            var p = Path()
            p.addArc(center: CGPoint(x: 30, y: -2), radius: 24, startAngle: .degrees(118), endAngle: .degrees(152), clockwise: false)
            ctx.stroke(p, with: .color(.white.opacity(cornerStart != nil ? 0.5 : 0.2)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .frame(width: 28, height: 28).scaleEffect(x: side, y: 1).contentShape(Rectangle())
        .padding(side < 0 ? .leading : .trailing, Metrics.ear)
        .onHover { inside in
            guard inside else { NSCursor.pop(); return }
            if #available(macOS 15, *) { NSCursor.frameResize(position: side < 0 ? .bottomLeft : .bottomRight, directions: .all).push() }
            else { NSCursor.crosshair.push() }
        }
        .onTapGesture(count: 2) { model.setWidth(Metrics.panelWidth); model.setHeight(Metrics.panelHeight) }
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { _ in
                let m = NSEvent.mouseLocation
                if cornerStart == nil {
                    cornerStart = (CGFloat(store.settings.panelWidth), CGFloat(store.settings.panelHeight), m); model.dragging = true
                }
                let s = cornerStart!
                model.setWidth(s.width + 2 * side * (m.x - s.mouse.x))
                model.setHeight(s.height + (s.mouse.y - m.y)) // screen y grows upward; the panel hangs from the top
            }
            .onEnded { _ in cornerStart = nil; model.dragging = false })
        .help("Drag to resize · double-click to reset")
    }

    @ViewBuilder func card(_ kind: CardKind) -> some View {
        switch kind {
        case .tasks: TasksCard(store: store, field: $field).id(store.settings.cardColors[kind]) // redraw on a new color
        case .focus: FocusCard(store: store).id(store.settings.cardColors[kind])
        case .notepad: NotepadCard(store: store, field: $field).id(store.settings.cardColors[kind])
        case .events: EventsCard(store: store).id(store.settings.cardColors[kind])
        }
    }
}

struct PagePicker: View {
    @Binding var page: Page
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Page.allCases, id: \.self) { p in
                Button { withAnimation(.spring(response: 0.28, dampingFraction: 1)) { page = p } } label: {
                    Text(p.rawValue).font(.callout.weight(.semibold))
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

/// A Workspace card's dot handle reports drags here: a value while dragging, nil when let go.
struct CardGripKey: EnvironmentKey { static let defaultValue: ((DragGesture.Value?) -> Void)? = nil }
extension EnvironmentValues {
    var cardGrip: ((DragGesture.Value?) -> Void)? { get { self[CardGripKey.self] } set { self[CardGripKey.self] = newValue } }
}

extension CardKind {
    var color: Color { [Tone.tasks, Tone.focus, Tone.notes, Tone.events][Self.allCases.firstIndex(of: self)!] }
}

struct Card<Content: View>: View {
    let color: Color
    @ViewBuilder let content: Content
    @Environment(\.cardGrip) private var grip
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(0..<2, id: \.self) { _ in
                    GridRow { ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 3.5, height: 3.5) } }
                }
            }
            .foregroundStyle(Tone.ink.opacity(grip == nil ? 0 : 0.16))
            .accessibilityHidden(true)
            .frame(width: 70, height: 14).contentShape(Rectangle())
            .padding(.top, 6)
            .onHover { inside in
                guard grip != nil else { return }
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("cards"))
                .onChanged { grip?($0) }.onEnded { _ in grip?(nil) }, including: grip == nil ? .none : .all)
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: Metrics.stack) { content }
                .padding(.horizontal, Metrics.cardPadding).padding(.bottom, Metrics.cardPadding).padding(.top, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(Tone.ink)
        .background(color, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

struct Placeholder: View {
    let title: String, note: String, color: Color
    var body: some View {
        Card(color: color) {
            Text(title).font(.title2.weight(.semibold))
            Text(note).foregroundStyle(Tone.inkSoft)
        }
    }
}

struct CardHeader: View {
    let icon: String?, title: String
    var tint: Color = Tone.ink
    var body: some View {
        HStack(spacing: 6) {
            // Icons start on the card's 16 pt text line in a fixed 16 pt column, so every title starts at 38 pt.
            // square.and.pencil's pencil makes it draw 1 pt low and right of the others (measured): nudge it back.
            if let icon {
                Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(tint)
                    .offset(x: icon == "square.and.pencil" ? -1 : 0, y: icon == "square.and.pencil" ? -1 : 0)
                    .frame(width: 16, alignment: .leading)
            }
            Text(title).font(.title2.weight(.semibold))
        }
    }
}

struct Dotted: View {
    var body: some View {
        Line().stroke(style: StrokeStyle(lineWidth: 1, dash: [1, 3])).foregroundStyle(Tone.ink.opacity(0.25)).frame(height: 1)
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
    @State private var hoverClock: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Card(color: Tone.tasks) {
            HStack {
                CardHeader(icon: "checklist", title: "Today's tasks", tint: Tone.icon(.tasks))
                Spacer()
                Text(Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.callout).foregroundStyle(Tone.inkSoft)
            }
            HStack(spacing: 2) {
                tab("To do", count: store.todo.count, selected: !showCompleted) { showCompleted = false }
                tab("Completed", count: store.completed.count, selected: showCompleted) { showCompleted = true }
            }
            .padding(2).background(Tone.wash, in: RoundedRectangle(cornerRadius: 9))

            if !showCompleted && store.settings.unfinished == .ask && !store.stale.isEmpty {
                stalePrompt
            }

            let list = showCompleted ? store.completed : store.todo
            List {
                if list.isEmpty {
                    Text(showCompleted ? "Nothing completed yet." : "Add your first task below.")
                        .font(.body).foregroundStyle(Tone.inkSoft).padding(.vertical, 8)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(list) { task in
                    row(task)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                .onMove(perform: showCompleted ? nil : { store.moveTodo(from: $0, to: $1) })
            }
            .listStyle(.plain).scrollContentBackground(.hidden).scrollIndicators(.never)
            .environment(\.defaultMinListRowHeight, 1)
            .padding(.horizontal, -16) // List insets rows 8 pt; rows pad 8 more: highlight 8 pt from the card edge, text on the 16 pt line

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.callout.weight(.semibold)).foregroundStyle(Tone.ink)
                    ZStack(alignment: .leading) {
                        if draft.isEmpty { Text("Add a task…").foregroundStyle(Tone.ink.opacity(0.7)).allowsHitTesting(false) }
                        TextField("", text: $draft)
                            .textFieldStyle(.plain).focused(field, equals: .add)
                            .onSubmit { store.add(draft); draft = ""; field.wrappedValue = .add }
                    }
                    .font(.body)
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(Tone.wash, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, -8) // field 8 pt from the card edge, + on the 16 pt line
            }
        }
    }

    func tab(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).fontWeight(selected ? .semibold : .regular)
                Text("\(count)").font(.subheadline).foregroundStyle(Tone.inkSoft)
            }
            .font(.callout).padding(.horizontal, 9).padding(.vertical, 4)
            .background(selected ? Tone.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    /// The task at hand: the one being focused on, else the top of the list.
    func isCurrent(_ task: TaskItem) -> Bool {
        !task.done && (store.focusTaskID ?? store.todo.first?.id) == task.id
    }

    /// Another task: focus on it. The task being timed: pause/resume or restart, per Customize.
    func clockTapped(_ task: TaskItem) {
        let timing = store.focusTaskID == task.id && (store.focusState == .running || store.focusState == .paused)
        guard timing, store.settings.timerClick == .pause else { return store.start(task: task.id) }
        store.focusState == .running ? store.pause() : store.start()
    }

    func clockHelp(_ task: TaskItem) -> String {
        guard store.focusTaskID == task.id, store.settings.timerClick == .pause else { return "Focus on this task" }
        switch store.focusState { case .running: return "Pause"; case .paused: return "Resume"; default: return "Focus on this task" }
    }

    /// The Focus card's timer icon. On the task being timed, a ring fills with the session's progress and the icon pulses while it runs.
    func focusIcon(_ task: TaskItem) -> some View {
        let timing = store.focusTaskID == task.id && store.focusState != .ready
        return TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let goal = store.isStopwatch ? TimeInterval(store.focusMinutes * 60) : store.focusTotal
            let done = timing && goal > 0 ? min(1, store.spent(at: ctx.date) / goal) : 0
            Image(systemName: "timer").font(.callout.weight(.semibold)).foregroundStyle(timing ? Tone.accent : Tone.ink)
                .symbolEffect(.pulse, isActive: timing && store.focusState == .running && !reduceMotion)
                .frame(width: 24, height: 24)
                .overlay {
                    if timing || hoverClock == task.id {
                        Circle().stroke(Tone.ink.opacity(0.15), lineWidth: 2)
                    }
                    if timing {
                        Circle().trim(from: 0, to: done).stroke(Tone.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }
                .contentShape(Circle())
                .onHover { hoverClock = $0 ? task.id : (hoverClock == task.id ? nil : hoverClock) }
        }
    }

    func row(_ task: TaskItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 1)) { store.toggle(task.id) } } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle").font(.title2)
            }
            .buttonStyle(.plain).help(task.done ? "Mark as incomplete" : "Mark as complete")
            .accessibilityLabel(task.done ? "Mark \(task.title) as incomplete" : "Mark \(task.title) as complete")

            if field.wrappedValue == .rename(task.id) {
                TextField("", text: $renameText).textFieldStyle(.plain).font(.body)
                    .focused(field, equals: .rename(task.id))
                    .onSubmit { store.rename(task.id, to: renameText); field.wrappedValue = nil }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(task.title).font(.body).strikethrough(task.done)
                            .foregroundStyle(Tone.ink).fontWeight(isCurrent(task) ? .semibold : .regular)
                        if let p = store.projects.first(where: { $0.id == task.projectID }) {
                            Circle().fill(Palette.named(p.color)).brightness(-0.1).frame(width: 7, height: 7).help(p.name)
                                .accessibilityLabel("Project: \(p.name)")
                        }
                    }
                    if !task.done && (task.timeLimit != nil || task.reminder != nil || task.due != nil) {
                        HStack(spacing: 10) {
                            if let limit = task.timeLimit {
                                let actual = store.actualMinutes(task.id)
                                Label(actual > 0 ? "\(actual)/\(limit)m" : "\(limit)m", systemImage: "timer")
                                    .foregroundStyle(actual > limit ? Tone.warning : Tone.inkSoft)
                            }
                            if let r = task.reminder { Label(reminderLabel(r), systemImage: "bell") }
                            if let due = task.due {
                                Label(due < store.today ? "Overdue" : "Due " + due.formatted(.dateTime.month(.abbreviated).day()), systemImage: "flag")
                                    .foregroundStyle(due < store.today ? Tone.alert : Tone.inkSoft)
                            }
                        }
                        .font(.subheadline).foregroundStyle(Tone.inkSoft)
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
                    .buttonStyle(.plain).font(.subheadline).foregroundStyle(Tone.inkSoft).help("Delete")
            } else {
                HStack(spacing: 8) {
                    Button { withAnimation(.easeOut(duration: 0.6)) { clockTapped(task) } } label: { focusIcon(task) }
                        .help(clockHelp(task)).accessibilityLabel("\(clockHelp(task)): \(task.title)")
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
                    } label: { Image(systemName: "ellipsis").accessibilityLabel("More") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .buttonStyle(.plain).font(.subheadline.weight(.semibold)).foregroundStyle(Tone.ink)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(isCurrent(task) ? Tone.current : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            Text("Unfinished tasks").font(.body.weight(.semibold))
            Text("\(store.stale.count) left from before today. Bring \(store.stale.count == 1 ? "it" : "them") into today?")
                .font(.callout).foregroundStyle(Tone.inkSoft)
            HStack(spacing: 8) {
                Button("Move to today") { withAnimation { store.carryStale() } }
                    .buttonStyle(.plain).font(.callout.weight(.semibold)).foregroundStyle(Tone.onButton)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(Tone.button, in: Capsule())
                Button("Leave in history") { withAnimation { store.dismissStale() } }
                    .buttonStyle(.plain).font(.callout)
                Button("Plan in Planner") { PlannerWindow.shared.show(planning: true) }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(Tone.inkSoft)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Tone.wash, in: RoundedRectangle(cornerRadius: 10))
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

/// The Focus card's ✓. With `hold` on, a ring fills while it's pressed and the task completes when it closes.
struct CompleteButton: View {
    let hold: Bool
    let action: () -> Void
    @State private var progress = 0.0
    static let holdTime = 0.8

    var body: some View {
        let face = Image(systemName: "checkmark").font(.callout.weight(.bold)).foregroundStyle(Tone.onButton)
            .frame(width: 32, height: 32)
            .background(Tone.button, in: Circle())
            .overlay {
                Circle().inset(by: -3).trim(from: 0, to: progress)
                    .stroke(Tone.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .contentShape(Circle())
        if hold {
            face.help("Hold to complete")
                // VoiceOver can't press and hold, so it gets a plain action.
                .accessibilityElement().accessibilityLabel("Complete focused task").accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
                .onLongPressGesture(minimumDuration: Self.holdTime) {
                    progress = 0; action()
                } onPressingChanged: { pressing in
                    withAnimation(pressing ? .linear(duration: Self.holdTime) : .easeOut(duration: 0.15)) { progress = pressing ? 1 : 0 }
                }
        } else {
            Button(action: action) { face }.help("Complete focused task").accessibilityLabel("Complete focused task")
        }
    }
}

struct FocusCard: View {
    let store: Store
    @State private var showSetTime = false

    var body: some View {
        Card(color: Tone.focus) {
            CardHeader(icon: "timer", title: "Focus", tint: Tone.icon(.focus))
            // Minutes over seconds when the card is tall; one line ("18:12") when it's short. Whichever gives bigger dots.
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let text = clock(store.display(at: ctx.date))
                GeometryReader { g in
                    let line = max(2, min(g.size.width / 37, g.size.height / 10.5))  // 25 columns, 7 rows
                    let stack = max(2, min(g.size.width / 17, g.size.height / 22))  // 11 columns, 2 × 7 rows
                    Group {
                        if stack >= line {
                            VStack(spacing: stack * 1.5) {
                                ForEach(Array(text.split(separator: ":").enumerated()), id: \.offset) { DotMatrix(text: String($0.element), dot: stack, color: Tone.timer) }
                            }
                        } else {
                            DotMatrix(text: text, dot: line, color: Tone.timer)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.top, 4)
            Text(status).font(.callout).foregroundStyle(Tone.inkSoft).lineLimit(1).frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                Button(action: primary) {
                    Label(primaryTitle, systemImage: primaryIcon).font(.callout.weight(.semibold))
                        .lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Tone.button, in: Capsule())
                }
                CompleteButton(hold: store.settings.holdToComplete) { store.completeFocus() }
            }
            .buttonStyle(.plain).foregroundStyle(Tone.onButton)
            HStack(spacing: 8) {
                Button { showSetTime = true } label: { Label("Set time", systemImage: "slider.horizontal.3").font(.callout) }
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
                    } label: { Image(systemName: "ellipsis").accessibilityLabel("More") }
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
        Card(color: Tone.notes) {
            CardHeader(icon: "square.and.pencil", title: "Notepad", tint: Tone.icon(.notepad))
            Text(Date.now.formatted(.dateTime.month(.abbreviated).day().year()))
                .font(.callout).foregroundStyle(Tone.inkSoft)
            Rectangle().fill(Tone.ink.opacity(0.12)).frame(height: 1)
            ZStack(alignment: .topLeading) {
                if store.notes.isEmpty {
                    Text("Write something down…").foregroundStyle(Tone.inkSoft).allowsHitTesting(false)
                }
                TextEditor(text: $store.notes).scrollContentBackground(.hidden).scrollIndicators(.never)
                    .padding(.leading, -5).focused(field, equals: .notes)
                    .onKeyPress(.return, phases: .down) { press in
                        press.modifiers.contains(.command) && lineToTask() ? .handled : .ignored
                    }
            }
            .font(.body)
            Text("⌘↩ makes a task").help("Press Command–Return to turn the current line into a task")
                .font(.subheadline).foregroundStyle(Tone.inkSoft).frame(maxWidth: .infinity, alignment: .trailing)
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
        Card(color: Tone.events) {
            HStack {
                CardHeader(icon: "calendar", title: "Events", tint: Tone.icon(.events))
                Spacer()
                Menu {
                    Button("Open in Calendar") { NSWorkspace.shared.open(URL(string: "ical://")!) }
                    Button("Refresh") { store.loadEvents() }
                } label: { Image(systemName: "ellipsis").accessibilityLabel("More") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            let reminders = store.reminders
            if reminders.isEmpty && (!store.calendarAccess || store.events.isEmpty) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: store.calendarAccess ? "calendar" : "calendar.badge.exclamationmark").font(.title)
                    Text(store.calendarAccess ? "Nothing scheduled" : "Calendar not connected").font(.title3.weight(.semibold))
                    Text(store.calendarAccess ? "No events in your selected calendars for today." : "Connect it to see today's events here.")
                        .font(.callout).foregroundStyle(Tone.inkSoft)
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
                                Text(Date.now.formatted(.dateTime.weekday(.abbreviated).day())).font(.footnote).foregroundStyle(Tone.inkSoft)
                            }
                            .padding(.top, reminders.isEmpty ? 0 : Metrics.stack)
                            ForEach(store.events, id: \.eventIdentifier) { eventTile($0) }
                        }
                        if !store.calendarAccess {
                            Button("Connect Calendar") { store.connectCalendar() }.font(.callout).padding(.top, Metrics.stack)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.never)
                .padding(.horizontal, -8) // the scroll view clips: widen it so tiles can reach 8 pt from the card edge
            }
        }
    }

    func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.footnote.weight(.semibold)).foregroundStyle(Tone.inkSoft)
    }

    func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Tone.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, -8) // tile 8 pt from the card edge, its content on the 16 pt line
    }

    func reminderTile(_ t: TaskItem) -> some View {
        tile {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.body.weight(.semibold)).lineLimit(2)
                    Text(reminderLabel(t.reminder!)).font(.subheadline).foregroundStyle(Tone.inkSoft)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Mark as Done") { store.toggle(t.id) }
                    Button("Remove reminder", role: .destructive) { store.setReminder(t.id, at: nil) }
                } label: { Image(systemName: "ellipsis").accessibilityLabel("More") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
    }

    func eventTile(_ e: EKEvent) -> some View {
        let now = Date.now
        let live = !e.isAllDay && e.startDate <= now && now < e.endDate
        return tile {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(live ? Tone.now : Color(cgColor: e.calendar.cgColor)).frame(width: 3).frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title ?? "Untitled").font(.body.weight(.semibold)).lineLimit(2)
                    Text(e.isAllDay ? "All day" : "\(e.startDate.formatted(date: .omitted, time: .shortened)) – \(e.endDate.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline).foregroundStyle(Tone.inkSoft)
                    if live { Text("Happening now").font(.subheadline.weight(.semibold)).foregroundStyle(Tone.now) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Compact deck: one card at a time

struct DeckItem: Identifiable {
    let id: String, icon: String, tint: Color, color: Color, title: String
    var info: String? = nil, badge: String? = nil, live = false
}

/// When a page's cards don't fit side by side, it shows one at a time, picked from an icon rail
/// (badges for what's waiting) or a row of live chips (Customize → Compact layout).
struct CompactDeck<Content: View>: View {
    let style: CompactStyle
    @Binding var selected: String?
    let items: (Date) -> [DeckItem]
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        let ids = items(.now).map(\.id)
        let current = ids.contains(selected ?? "") ? selected! : ids.first ?? ""
        Aside(style: style, current: current, items: items, pick: { selected = $0 }) { content(current) }
    }
}

/// Content with an icon rail on its left or a chip row above it; clicking one calls `pick`.
struct Aside<Content: View>: View {
    let style: CompactStyle
    var current: String? = nil
    let items: (Date) -> [DeckItem]
    let pick: (String) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        let picker = TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let list = items(ctx.date)
            if style == .rail {
                VStack(spacing: 6) { ForEach(list) { rail($0, on: $0.id == current) }; Spacer(minLength: 0) }
            } else {
                HStack(spacing: 6) { ForEach(list) { chip($0, on: $0.id == current) }; if current == nil { Spacer(minLength: 0) } }
            }
        }
        if style == .rail {
            HStack(spacing: Metrics.rail - 40) { picker.frame(width: 40); content().frame(maxWidth: .infinity, maxHeight: .infinity) }
        } else {
            VStack(spacing: 10) { picker; content().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }

    func rail(_ i: DeckItem, on: Bool) -> some View {
        Button { pick(i.id) } label: {
            Image(systemName: i.icon).font(.title3.weight(.semibold)).foregroundStyle(on ? i.tint : .white.opacity(0.75))
                .frame(width: 40, height: 40)
                .background(on ? AnyShapeStyle(i.color) : AnyShapeStyle(.white.opacity(0.08)), in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if let b = i.badge {
                        Text(b).font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Color(nsColor: Tone.hex(0x0A64D8)), in: Capsule())
                            .offset(x: 5, y: -5)
                    } else if i.live {
                        Circle().fill(Color(nsColor: Tone.hex(0x34C759))).frame(width: 9, height: 9).offset(x: 2, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(i.title)
        .accessibilityLabel([i.title, i.badge.map { "\($0) waiting" }, i.live ? "running" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    func chip(_ i: DeckItem, on: Bool) -> some View {
        Button { pick(i.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: i.icon).font(.callout.weight(.semibold)).foregroundStyle(on ? i.tint : .white.opacity(0.8))
                if on { Text(i.title).font(.callout.weight(.semibold)).lineLimit(1) }
                if let info = i.info { Text(info).font(.callout).monospacedDigit().lineLimit(1).opacity(on ? 0.7 : 0.9) }
            }
            .foregroundStyle(on ? Tone.ink : .white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: on ? .infinity : nil)
            .background(on ? AnyShapeStyle(i.color) : AnyShapeStyle(.white.opacity(0.10)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(i.title)
        .accessibilityLabel([i.title, i.info].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
