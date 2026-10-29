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

enum Unfinished: String, Codable, CaseIterable { case ask = "Ask me", carry = "Move to today", leave = "Leave in history" }

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
    var plannerDark = false     // Planner window in dark mode (the notch is unaffected)

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
        plannerDark = (try? c.decodeIfPresent(Bool.self, forKey: .plannerDark)) ?? d.plannerDark
    }

    /// Saved order plus any card kinds added since it was saved.
    var orderedCards: [CardKind] { cardOrder + CardKind.allCases.filter { !cardOrder.contains($0) } }
    var visibleCards: [CardKind] { orderedCards.filter { !hiddenCards.contains($0) } }

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
