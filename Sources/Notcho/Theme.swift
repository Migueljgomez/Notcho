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
    static let tasks = pair(0xD3EBD7, 0x1C1C1E)
    static let focus = pair(0xD2E2F6, 0x1C1C1E)
    static let notes = pair(0xF7E9AE, 0x1C1C1E)
    static let events = pair(0xE2D7F2, 0x1C1C1E)
    static let ink = pair(0x1C1C1E, 0xF5F5F7)
    static let inkSoft = pair(0x55555A, 0x98989F)
    /// A slightly darker version of whatever card color is underneath: highlights, fields, tiles.
    static let wash = pair(NSColor.black.withAlphaComponent(0.09), NSColor.white.withAlphaComponent(0.08))
    static let raised = pair(NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0.14))
    static let button = pair(0x1C1C1E, 0xF2B33D)
    static let onButton = pair(0xFFFFFF, 0x1C1C1E)
    static let timer = pair(0x1C1C1E, 0xF2B33D)

    static func pair(_ light: Int, _ dark: Int) -> Color { pair(hex(light), hex(dark)) }
    static func pair(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
    static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
