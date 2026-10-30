import AppKit
import Carbon.HIToolbox
import ServiceManagement

enum CardKind: String, Codable, CaseIterable, Identifiable {
    case tasks, focus, notepad, events
    var id: Self { self }
    var title: String { ["Tasks", "Focus timer", "Notepad", "Calendar events"][Self.allCases.firstIndex(of: self)!] }
    var icon: String { ["checklist", "timer", "square.and.pencil", "calendar"][Self.allCases.firstIndex(of: self)!] }
    /// Relative width on the Workspace page.
    var weight: CGFloat { [0.36, 0.19, 0.2, 0.25][Self.allCases.firstIndex(of: self)!] }
}

/// Where each visible card sits in a row `width` wide.
func cardFrames(_ weights: [CGFloat], width: CGFloat, gap: CGFloat) -> [(x: CGFloat, width: CGFloat)] {
    let total = weights.reduce(0, +), room = width - gap * CGFloat(max(weights.count - 1, 0))
    var x: CGFloat = 0
    return weights.map { w in
        defer { x += room * w / total + gap }
        return (x, room * w / total)
    }
}

/// How the notch looks. Match my Mac: pastel in Light mode, the dark island in Dark mode.
enum NotchLook: String, Codable, CaseIterable { case light = "Light", pastel = "Pastel", dark = "Dark island", system = "Match my Mac" }

enum PlannerLook: String, Codable, CaseIterable { case system = "Match my Mac", light = "Light", dark = "Dark" }

enum SelectionStyle: String, Codable, CaseIterable { case accent = "Mac accent color", gray = "Soft gray", butter = "Pale butter" }

enum CompactStyle: String, Codable, CaseIterable { case rail = "Icon rail", chips = "Live chips" }

enum Unfinished: String, Codable, CaseIterable { case ask = "Ask me", carry = "Move to today", leave = "Leave in history" }

enum TimerClick: String, Codable, CaseIterable { case pause = "Pause / Resume", restart = "Restart timer" }

enum Shortcut: String, Codable, CaseIterable {
    case optN = "⌥ N", ctrlOptN = "⌃⌥ N", cmdShiftN = "⇧⌘ N", optSpace = "⌥ Space", off = "Off"
    /// (virtual key code, Carbon modifier mask)
    var key: (UInt32, UInt32)? {
        switch self {
        case .optN: (UInt32(kVK_ANSI_N), UInt32(optionKey))
        case .ctrlOptN: (UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey))
        case .cmdShiftN: (UInt32(kVK_ANSI_N), UInt32(cmdKey | shiftKey))
        case .optSpace: (UInt32(kVK_Space), UInt32(optionKey))
        case .off: nil
        }
    }
}

/// User preferences. Every field falls back to its default when missing, so adding fields never loses saved data.
struct Settings: Codable, Equatable {
    var cardOrder = CardKind.allCases
    var hiddenCards: Set<CardKind> = []
    var shortcut = Shortcut.optN
    var dayStartHour = 0
    var unfinished = Unfinished.ask
    var weekendsInStreak = false
    var stopwatch = false
    var completionSound = true
    var syncReminders = false
    var workdayEndHour = 18   // Planner workload meter: time left until this hour
    var breakAfterMinutes = 90  // break nudge after this much unbroken focus; 0 = off
    var wrapUpHour = 17         // daily wrap-up banner at this hour; 0 = off
    var cardWeights: [CardKind: Double] = [:]  // resized card widths; missing = the card's default
    var panelHeight = Double(Metrics.panelHeight)
    var panelWidth = Double(Metrics.panelWidth)
    var closeAfter = 0.0        // seconds the notch waits after the pointer leaves; `stayOpen` = only click-away, Esc or ✕
    static let stayOpen = 3.5
    var notchLook = NotchLook.light
    var plannerLook = PlannerLook.system
    var plannerSelection = SelectionStyle.accent  // the selected sidebar row in the Planner
    var cardColors: [CardKind: Int] = [:]  // custom pastel per card (hex); missing = the default
    var showSubtasks = true
    var compactStyle = CompactStyle.rail  // how a page shows one card at a time when the notch is too narrow
    var holdToComplete = true   // Focus ✓ needs a press-and-hold
    var timerClick = TimerClick.pause  // clicking the clock on the task already being timed

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        cardOrder = (try? c.decodeIfPresent([CardKind].self, forKey: .cardOrder)) ?? d.cardOrder
        hiddenCards = (try? c.decodeIfPresent(Set<CardKind>.self, forKey: .hiddenCards)) ?? d.hiddenCards
        shortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .shortcut)) ?? d.shortcut
        dayStartHour = (try? c.decodeIfPresent(Int.self, forKey: .dayStartHour)) ?? d.dayStartHour
        unfinished = (try? c.decodeIfPresent(Unfinished.self, forKey: .unfinished)) ?? d.unfinished
        weekendsInStreak = (try? c.decodeIfPresent(Bool.self, forKey: .weekendsInStreak)) ?? d.weekendsInStreak
        stopwatch = (try? c.decodeIfPresent(Bool.self, forKey: .stopwatch)) ?? d.stopwatch
        completionSound = (try? c.decodeIfPresent(Bool.self, forKey: .completionSound)) ?? d.completionSound
        syncReminders = (try? c.decodeIfPresent(Bool.self, forKey: .syncReminders)) ?? d.syncReminders
        workdayEndHour = (try? c.decodeIfPresent(Int.self, forKey: .workdayEndHour)) ?? d.workdayEndHour
        breakAfterMinutes = (try? c.decodeIfPresent(Int.self, forKey: .breakAfterMinutes)) ?? d.breakAfterMinutes
        wrapUpHour = (try? c.decodeIfPresent(Int.self, forKey: .wrapUpHour)) ?? d.wrapUpHour
        cardWeights = (try? c.decodeIfPresent([CardKind: Double].self, forKey: .cardWeights)) ?? d.cardWeights
        panelHeight = (try? c.decodeIfPresent(Double.self, forKey: .panelHeight)) ?? d.panelHeight
        panelWidth = (try? c.decodeIfPresent(Double.self, forKey: .panelWidth)) ?? d.panelWidth
        closeAfter = (try? c.decodeIfPresent(Double.self, forKey: .closeAfter)) ?? d.closeAfter
        notchLook = (try? c.decodeIfPresent(NotchLook.self, forKey: .notchLook)) ?? d.notchLook
        plannerLook = (try? c.decodeIfPresent(PlannerLook.self, forKey: .plannerLook)) ?? d.plannerLook
        plannerSelection = (try? c.decodeIfPresent(SelectionStyle.self, forKey: .plannerSelection)) ?? d.plannerSelection
        cardColors = (try? c.decodeIfPresent([CardKind: Int].self, forKey: .cardColors)) ?? d.cardColors
        showSubtasks = (try? c.decodeIfPresent(Bool.self, forKey: .showSubtasks)) ?? d.showSubtasks
        compactStyle = (try? c.decodeIfPresent(CompactStyle.self, forKey: .compactStyle)) ?? d.compactStyle
        holdToComplete = (try? c.decodeIfPresent(Bool.self, forKey: .holdToComplete)) ?? d.holdToComplete
        timerClick = (try? c.decodeIfPresent(TimerClick.self, forKey: .timerClick)) ?? d.timerClick
    }

    /// Saved order plus any card kinds added since it was saved.
    var orderedCards: [CardKind] { cardOrder + CardKind.allCases.filter { !cardOrder.contains($0) } }
    var visibleCards: [CardKind] { orderedCards.filter { !hiddenCards.contains($0) } }

    func weight(_ card: CardKind) -> CGFloat { cardWeights[card].map { CGFloat($0) } ?? card.weight }

    /// Card order, visibility, widths and panel height back to the defaults.
    mutating func resetLayout() {
        let d = Settings()
        cardOrder = d.cardOrder; hiddenCards = d.hiddenCards; cardWeights = d.cardWeights; panelHeight = d.panelHeight; panelWidth = d.panelWidth
    }

    /// Dragging the gap between `left` and `right` by `dx` points (`perPoint` = weight per point); both keep `minWidth`.
    mutating func resize(_ left: CardKind, _ right: CardKind, from start: (CGFloat, CGFloat), by dx: CGFloat,
                         perPoint: CGFloat, minWidth: CGFloat) {
        let (l, r) = (start.0 / perPoint, start.1 / perPoint) // widths in points
        let newL = min(max(l + dx, minWidth), l + r - minWidth)
        guard newL.isFinite, l + r >= 2 * minWidth else { return }
        cardWeights[left] = Double(newL * perPoint)
        cardWeights[right] = Double((l + r - newL) * perPoint)
    }

    /// Dropping `card` onto `target` takes the target's place (moving right lands after it, left before it).
    mutating func move(_ card: CardKind, onto target: CardKind) {
        var order = orderedCards
        guard card != target, let from = order.firstIndex(of: card), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(card, at: from < to ? order.firstIndex(of: target)! + 1 : order.firstIndex(of: target)!)
        cardOrder = order
    }
}

// MARK: - Global shortcut (Carbon hot key: works without Accessibility permission)

enum HotKey {
    private static var ref: EventHotKeyRef?, plannerRef: EventHotKeyRef?
    private static var installed = false
    static var handler: (() -> Void)?          // id 1: the notch shortcut (Customize)
    private static var plannerHandler: (() -> Void)?  // id 2: ⌥⇧N opens the Planner

    private static func install() {
        guard !installed else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { (id.id == 2 ? HotKey.plannerHandler : HotKey.handler)?() }
            return noErr
        }, 1, &spec, nil, nil)
        installed = true
    }

    static func register(_ shortcut: Shortcut) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard let (code, mods) = shortcut.key else { return }
        install()
        let id = EventHotKeyID(signature: OSType(0x4E4F5443), id: 1) // 'NOTC'
        RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref)
    }

    static func registerPlanner(_ action: @escaping () -> Void) {
        plannerHandler = action
        install()
        let id = EventHotKeyID(signature: OSType(0x4E4F5443), id: 2)
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(optionKey | shiftKey), id, GetApplicationEventTarget(), 0, &plannerRef)
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message, or nil on success.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Launch at login couldn't be changed: \(error.localizedDescription)"
        }
    }
}
