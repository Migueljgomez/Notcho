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
