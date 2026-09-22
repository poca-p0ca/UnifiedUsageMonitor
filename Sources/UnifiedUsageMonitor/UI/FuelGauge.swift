import SwiftUI

/// Shared dial geometry. The sweep runs across the top of the circle: E on the
/// left, F on the right, exactly like a car fuel gauge.
enum Dial {
    static let startDegrees: Double = 200
    static let sweepDegrees: Double = 140

    static func center(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height * 0.84)
    }

    static func radius(in size: CGSize) -> CGFloat {
        min(size.width * 0.40, size.height * 0.72)
    }

    /// `fraction` is tank level: 0 = empty (left), 1 = full (right).
    static func point(center: CGPoint, radius: CGFloat, fraction: Double) -> CGPoint {
        let radians = (startDegrees + sweepDegrees * fraction) * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(cos(radians)),
                       y: center.y + radius * CGFloat(sin(radians)))
    }

    /// Arcs are sampled rather than built with `addArc`, whose `clockwise` flag
    /// is easy to get backwards under SwiftUI's flipped y-axis.
    static func arc(center: CGPoint, radius: CGFloat, from start: Double, to end: Double) -> Path {
        var path = Path()
        let steps = 48
        for step in 0...steps {
            let t = start + (end - start) * Double(step) / Double(steps)
            let p = point(center: center, radius: radius, fraction: t)
            if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

/// The needle is its own Shape so the swing animates when usage changes.
struct NeedleShape: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = Dial.center(in: rect.size)
        let radius = Dial.radius(in: rect.size)
        let angle = (Dial.startDegrees + Dial.sweepDegrees * fraction) * .pi / 180

        let along = CGVector(dx: cos(angle), dy: sin(angle))
        let across = CGVector(dx: -along.dy, dy: along.dx)

        func offset(_ forward: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: center.x + along.dx * forward + across.dx * side,
                    y: center.y + along.dy * forward + across.dy * side)
        }

        let tip = radius * 0.80
        let tail = -radius * 0.16

        var path = Path()
        path.move(to: offset(tip, 0))
        path.addLine(to: offset(tip * 0.25, 2.4))
        path.addLine(to: offset(tail, 3.2))
        path.addLine(to: offset(tail, -3.2))
        path.addLine(to: offset(tip * 0.25, -2.4))
        path.closeSubpath()
        return path
    }
}

/// One provider rendered as a fuel gauge.
///
/// The coloured section of the arc runs from E up to the needle, so it *is* the
/// remaining-level bar rather than a separate zone marking. Low fuel is
/// signalled by that colour turning red, not by a painted band.
struct FuelGauge: View {
    let providerID: String
    let title: String
    let window: UsageWindow?
    let caption: String?
    /// Last reading kept after a failed fetch. Drawn in grey rather than
    /// desaturated with a view effect: effects are not honoured by every
    /// renderer, and a stale number must never pass for a live one.
    var isStale: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    private var level: Double {
        guard let window else { return 0 }
        return min(1, max(0, window.remainingPercent / 100))
    }

    private func accentColor(_ breath: Double) -> Color {
        if isStale { return GaugeAccent.spent }
        return GaugeAccent.color(providerID: providerID, window: window,
                                 dark: colorScheme == .dark, breath: breath)
    }

    /// Only a gauge that is low and live breathes: a stale one is already grey,
    /// and a spent one has nowhere left to fade to.
    private var isBreathing: Bool {
        !isStale && window?.severity == .critical
    }

    var body: some View {
        if isBreathing {
            TimelineView(.animation) { timeline in
                content(breath: Breath.phase(at: timeline.date))
            }
        } else {
            content(breath: 1)
        }
    }

    private func content(breath: Double) -> some View {
        let accent = accentColor(breath)
        return VStack(spacing: 7) {
            ZStack {
                Canvas { context, size in draw(context: &context, size: size) }

                // Printed on the dial face where a car puts the fuel pump
                // symbol, so the needle sweeps over it.
                BrandMark(providerID: providerID, size: 22)
                    .offset(y: hubOffset - 16)
                    .opacity(window == nil ? 0.35 : 1)

                LevelArc(fraction: window == nil ? 0 : level)
                    .stroke(accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .animation(.spring(response: 0.9, dampingFraction: 0.7), value: level)

                NeedleShape(fraction: window == nil ? 0 : level)
                    .fill(accent)
                    .opacity(window == nil ? 0.25 : 1)
                    .animation(.spring(response: 0.9, dampingFraction: 0.7), value: level)

                Circle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 7, height: 7)
                    .offset(y: hubOffset)
            }
            .frame(height: 96)

            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                if let window {
                    // The gauge reads like a fuel tank, so the headline number
                    // is what is left, not what has been spent.
                    Text(Format.percent(window.remainingPercent))
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        .foregroundStyle(accent)
                    Text(L10n.t("gauge.remaining", "left"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("—")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }

                if let caption {
                    Text(caption)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The hub sits low in the 96pt canvas; offsets are measured from centre.
    private var hubOffset: CGFloat { 96 * 0.84 - 48 }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let center = Dial.center(in: size)
        let radius = Dial.radius(in: size)

        let trackColor = Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10)
        context.stroke(
            Dial.arc(center: center, radius: radius, from: 0, to: 1),
            with: .color(trackColor),
            style: StrokeStyle(lineWidth: 7, lineCap: .round)
        )

        // Eight minor ticks, with majors at E, ½ and F.
        for step in 0...8 {
            let t = Double(step) / 8
            let isMajor = (step == 0 || step == 4 || step == 8)
            let inner = radius - (isMajor ? 13 : 9)
            let outer = radius - 4
            var tick = Path()
            tick.move(to: Dial.point(center: center, radius: inner, fraction: t))
            tick.addLine(to: Dial.point(center: center, radius: outer, fraction: t))
            context.stroke(
                tick,
                with: .color(Color.primary.opacity(isMajor ? 0.55 : 0.28)),
                style: StrokeStyle(lineWidth: isMajor ? 1.6 : 1, lineCap: .round)
            )
        }

        // Resolved with an explicit colour: hierarchical styles do not
        // resolve inside a Canvas.
        let labelColor = Color.primary.opacity(0.5)
        let labelRadius = radius - 22
        context.draw(
            Text("E").font(.system(size: 9, weight: .semibold)).foregroundColor(labelColor),
            at: Dial.point(center: center, radius: labelRadius, fraction: 0)
        )
        context.draw(
            Text("F").font(.system(size: 9, weight: .semibold)).foregroundColor(labelColor),
            at: Dial.point(center: center, radius: labelRadius, fraction: 1)
        )
    }
}

struct LevelArc: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = Dial.center(in: rect.size)
        let radius = Dial.radius(in: rect.size)
        if fraction > 0.01 {
            return Dial.arc(center: center, radius: radius, from: 0, to: fraction)
        }
        return Path()
    }
}
