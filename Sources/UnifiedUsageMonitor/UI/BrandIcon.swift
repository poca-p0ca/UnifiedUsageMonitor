import AppKit
import SwiftUI

/// Flat redraws of each vendor's mark, so the dial face stays as flat as the
/// gauge around it. The installed app icons are skeuomorphic (gradients, glass,
/// a tinted tile) and read as stickers next to a line-drawn dial.
enum BrandPalette {
    /// Silver, not the accent: the mark is dial-face printing, and colour here
    /// would compete with the needle and the level arc for attention.
    static func silver(dark: Bool) -> LinearGradient {
        LinearGradient(
            colors: dark
                ? [Color(white: 0.90), Color(white: 0.68)]
                : [Color(white: 0.72), Color(white: 0.52)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private static func pair(for providerID: String) -> (light: NSColor, dark: NSColor)? {
        switch providerID {
        case "codex":
            // ChatGPT Green: #10A37F (Light), Brighter green (Dark)
            return (NSColor(srgbRed: 0.063, green: 0.639, blue: 0.498, alpha: 1),
                    NSColor(srgbRed: 0.239, green: 0.745, blue: 0.616, alpha: 1))
        case "anthropic":
            return (NSColor(srgbRed: 0.80, green: 0.42, blue: 0.27, alpha: 1),
                    NSColor(srgbRed: 0.90, green: 0.57, blue: 0.43, alpha: 1))
        case "antigravity":
            // Gemini Blue: #078EFA (Light), Brighter blue (Dark)
            return (NSColor(srgbRed: 0.027, green: 0.557, blue: 0.980, alpha: 1),
                    NSColor(srgbRed: 0.361, green: 0.706, blue: 0.980, alpha: 1))
        default:
            return nil
        }
    }

    /// SwiftUI path: resolved from the view's colour scheme, so offscreen
    /// renders match what the live popover shows.
    static func accent(for providerID: String, dark: Bool) -> Color {
        guard let pair = pair(for: providerID) else { return .secondary }
        return Color(nsColor: dark ? pair.dark : pair.light)
    }

    /// AppKit path: the menu bar needs a colour that re-resolves on its own
    /// when the system appearance changes.
    static func nsAccent(for providerID: String) -> NSColor {
        guard let pair = pair(for: providerID) else { return .secondaryLabelColor }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? pair.dark : pair.light
        }
    }
}

/// Resolves the colour of the level arc, the needle and the menu bar dot.
///
/// Brand hue carries normal state; at critical utilisation it switches to red,
/// the way a real gauge's low-fuel light overrides the dial. Without that
/// override, brand colour alone would give no warning.
enum GaugeAccent {
    /// `breath` runs 0...1: 1 is the full brand colour, 0 is the grey a spent
    /// gauge settles on. Only the critical band varies it; everywhere else
    /// passes 1.
    static func color(providerID: String, window: UsageWindow?, dark: Bool, breath: Double = 1) -> Color {
        guard let window else { return Color.secondary.opacity(0.4) }
        switch window.severity {
        case .exhausted:
            return spent
        case .critical:
            // Interpolated, never branched. Choosing between two colours gives
            // SwiftUI nothing to animate, so a flag-driven version just freezes
            // on whichever colour it settled on.
            return mix(providerID: providerID, dark: dark, breath: breath)
        default:
            return BrandPalette.accent(for: providerID, dark: dark)
        }
    }

    /// Where an exhausted gauge rests, and the far end of the breath.
    static let spent = Color.primary.opacity(0.35)

    /// Fades the brand colour toward neutral while dropping opacity, so
    /// `breath == 0` lands exactly on `spent` — the breath and the spent state
    /// share an endpoint instead of being two different greys.
    private static func mix(providerID: String, dark: Bool, breath: Double) -> Color {
        let amount = min(1, max(0, breath))
        let neutral = NSColor(white: dark ? 1 : 0, alpha: 1)
        let brand = NSColor(BrandPalette.accent(for: providerID, dark: dark)).usingColorSpace(.sRGB)
        let faded = brand?.blended(withFraction: 1 - amount, of: neutral) ?? neutral
        return Color(nsColor: faded).opacity(0.35 + 0.65 * amount)
    }

    static func nsColor(providerID: String, window: UsageWindow?) -> NSColor {
        guard let window else { return .tertiaryLabelColor }
        switch window.severity {
        case .exhausted:
            return .tertiaryLabelColor
        case .critical:
            // The menu bar has no cheap way to breathe — it would need its own
            // redraw timer — so low fuel reads there as a dimmed brand colour.
            return NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let neutral = NSColor(white: dark ? 1 : 0, alpha: 1)
                let brand = NSColor(BrandPalette.accent(for: providerID, dark: dark))
                    .usingColorSpace(.sRGB)
                return (brand?.blended(withFraction: 0.45, of: neutral) ?? neutral)
                    .withAlphaComponent(0.8)
            }
        default:
            return BrandPalette.nsAccent(for: providerID)
        }
    }
}

/// Drives the low-fuel breathing from the clock rather than from view state,
/// so every view that shows the same reading pulses in step.
enum Breath {
    /// One full cycle: brand colour → grey → brand colour.
    private static let period: Double = 1.6

    /// Never reaches 0: a gauge that is merely low must stay distinguishable
    /// from one that is spent.
    static func phase(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period

        // Triangle first, then a cubic ease-in-out. A raw sine reads as a
        // constant-rate sweep because it barely rests at either extreme; the
        // cubic holds each end and moves quickly through the middle.
        let triangle = t < 0.5 ? t * 2 : (1 - t) * 2
        let eased = triangle < 0.5
            ? 4 * triangle * triangle * triangle
            : 1 - pow(-2 * triangle + 2, 3) / 2

        return 0.3 + 0.7 * eased
    }
}

struct BrandMark: View {
    let providerID: String
    var size: CGFloat = 22

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let silver = BrandPalette.silver(dark: colorScheme == .dark)
        Group {
            if let data = BrandArtwork.pathData(for: providerID) {
                // Even-odd matches the source SVGs' fill-rule; with non-zero
                // the enclosed counters would fill solid.
                BrandArtworkShape(pathData: data)
                    .fill(silver, style: FillStyle(eoFill: true))
            } else {
                Circle().stroke(silver, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
    }
}
