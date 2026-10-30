import AppKit
import SwiftUI

/// Notcho's design tokens, named by meaning. Text uses Apple's built-in styles (.body 13, .callout 12,
/// .subheadline 11, .footnote 10, .title3 15, .title2 17, .title 22, .largeTitle 26), so there are no sizes here.
enum Theme {
    // MARK: Colors that mean something. System colors adapt to light, dark and Increase Contrast on their own.
    static let notes = Color.yellow
    static let done = Color.green
    static let now = Color.blue
    static let projects = Color.purple
    /// Notcho's accent: the nacho chip.
    static let gold = dynamic(light: (0.949, 0.702, 0.239), dark: (0.949, 0.702, 0.239),
                              lightHighContrast: (0.62, 0.36, 0.0), darkHighContrast: (1.0, 0.80, 0.40))
    static let goldEdge = Color(red: 0.788, green: 0.467, blue: 0.122)

    // MARK: Corners nest: an inner corner is the outer corner minus the padding between them.
    static let panelRadius: CGFloat = 26
    static let cardRadius: CGFloat = 18
    static func inner(_ outer: CGFloat, padding: CGFloat) -> CGFloat { max(outer - padding, 4) }

    static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double),
                        lightHighContrast: (Double, Double, Double), darkHighContrast: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c: (Double, Double, Double) = switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: dark
            case .accessibilityHighContrastAqua: lightHighContrast
            case .accessibilityHighContrastDarkAqua: darkHighContrast
            default: light
            }
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

/// Notch colors: pastel under a Light appearance, the dark island under Dark. The panel's appearance
/// (Customize → Appearance) decides which, so views never check the mode themselves.
enum Tone {
    static var tasks: Color { card(.tasks) }
    static var focus: Color { card(.focus) }
    static var notes: Color { card(.notepad) }
    static var events: Color { card(.events) }

    /// Card pastels: the user's pick (Planner → Workspace → Card colors) or the default. Dark island cards stay dark.
    static var custom: [CardKind: Int] = [:]
    static let defaults: [CardKind: Int] = [.tasks: 0xD3EBD7, .focus: 0xD2E2F6, .notepad: 0xF7E9AE, .events: 0xE2D7F2]
    static func card(_ kind: CardKind) -> Color { pair(custom[kind] ?? defaults[kind]!, 0x1C1C1E) }
    /// Pastels that keep every card's text at 4.5:1 or better, highlights included.
    static let swatches = [0xD3EBD7, 0xD2E2F6, 0xF7E9AE, 0xE2D7F2, 0xF6D5D5, 0xF9DFC4, 0xD5EDEB, 0xE6E3DC]
    /// Secondary text (`inkSoft`) on the card's highlight (`wash`) is the weakest pair; it needs 4.5:1.
    static func readable(_ v: Int) -> Bool {
        func lum(_ v: Int) -> Double {
            [v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF].enumerated().reduce(0.0) { sum, e in
                let c = Double(e.element) / 255
                let lin = c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                return sum + lin * [0.2126, 0.7152, 0.0722][e.offset]
            }
        }
        let washed = [v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF].map { Int((Double($0) * 0.91).rounded()) }
        let bg = lum(washed[0] << 16 | washed[1] << 8 | washed[2])
        return (bg + 0.05) / (lum(0x4A4A4F) + 0.05) >= 4.5
    }
    static let ink = pair(0x1C1C1E, 0xF5F5F7)
    // Secondary text and the tints below stay at 4.5:1 or better on every card color and on `wash`; Increase Contrast pushes them further.
    static let inkSoft = pair(hex(0x4A4A4F), hex(0x98989F), contrast: (hex(0x2C2C2E), hex(0xD1D1D6)))
    /// A slightly darker version of whatever card color is underneath: highlights, fields, tiles.
    static let wash = pair(NSColor.black.withAlphaComponent(0.09), NSColor.white.withAlphaComponent(0.08),
                           contrast: (NSColor.black.withAlphaComponent(0.15), NSColor.white.withAlphaComponent(0.16)))
    /// Text and marks that mean something, dark enough to read on the pastels.
    static let warning = pair(0x7F3D00, 0xFF9F0A)   // over a time limit
    static let alert = pair(0x962018, 0xFF6961)     // overdue
    static let now = pair(0x0846A0, 0x64A8FF)       // happening now
    static let raised = pair(NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0.14))
    static let button = pair(0x1C1C1E, 0xF2B33D)
    static let onButton = pair(0xFFFFFF, 0x1C1C1E)
    static let timer = pair(0x1C1C1E, 0xF2B33D)

    static func pair(_ light: Int, _ dark: Int) -> Color { pair(hex(light), hex(dark)) }
    /// `contrast` replaces the pair while Increase Contrast is on. The panel forces aqua/darkAqua, so the setting is read directly.
    static func pair(_ light: NSColor, _ dark: NSColor, contrast: (NSColor, NSColor)? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) {
            let isDark = $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if let contrast, NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { return isDark ? contrast.1 : contrast.0 }
            return isDark ? dark : light
        })
    }
    static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
