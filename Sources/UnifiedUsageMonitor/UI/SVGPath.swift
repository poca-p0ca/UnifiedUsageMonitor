import SwiftUI

/// Just enough of the SVG path grammar to draw the embedded brand marks:
/// M L H V C S Q T A Z, absolute and relative.
///
/// Written rather than hand-tracing the icons, so swapping in a newer icon is
/// a one-line data change instead of redrawing geometry.
enum SVGPath {
    /// Parses `data` in its own viewBox space, then scales it to fit `rect`
    /// while preserving aspect ratio and centring the result.
    static func path(from data: String, viewBox: CGSize, fitting rect: CGRect) -> Path {
        var parser = Parser(data)
        let raw = parser.parse()

        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let dx = rect.minX + (rect.width - viewBox.width * scale) / 2
        let dy = rect.minY + (rect.height - viewBox.height * scale) / 2
        let transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
        return raw.applying(transform)
    }

    private struct Parser {
        private let chars: [Character]
        private var index = 0
        private var current = CGPoint.zero
        private var subpathStart = CGPoint.zero
        private var lastCubicControl: CGPoint?
        private var lastQuadControl: CGPoint?
        private var path = Path()

        init(_ data: String) { chars = Array(data) }

        mutating func parse() -> Path {
            var command: Character = " "
            while true {
                skipSeparators()
                guard index < chars.count else { break }

                if chars[index].isLetter {
                    command = chars[index]
                    index += 1
                } else if command == " " {
                    break
                }

                let before = index
                run(command)
                // A run that consumed nothing means malformed data; stop rather
                // than spin. `Z` legitimately consumes no parameters.
                if index == before, command != "Z", command != "z" { break }

                // A moveto's follow-on coordinate pairs are implicit linetos.
                if command == "M" { command = "L" }
                if command == "m" { command = "l" }
                if command == "Z" || command == "z" { command = " " }
            }
            return path
        }

        private mutating func run(_ command: Character) {
            let relative = command.isLowercase
            let base = relative ? current : .zero

            switch command.lowercased().first! {
            case "m":
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.move(to: p)
                current = p
                subpathStart = p
                lastCubicControl = nil
                lastQuadControl = nil
            case "l":
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                line(to: p)
            case "h":
                line(to: CGPoint(x: base.x + number(), y: current.y))
            case "v":
                line(to: CGPoint(x: current.x, y: base.y + number()))
            case "c":
                let c1 = CGPoint(x: base.x + number(), y: base.y + number())
                let c2 = CGPoint(x: base.x + number(), y: base.y + number())
                let end = CGPoint(x: base.x + number(), y: base.y + number())
                curve(to: end, control1: c1, control2: c2)
            case "s":
                let c1 = lastCubicControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let c2 = CGPoint(x: base.x + number(), y: base.y + number())
                let end = CGPoint(x: base.x + number(), y: base.y + number())
                curve(to: end, control1: c1, control2: c2)
            case "q":
                let c = CGPoint(x: base.x + number(), y: base.y + number())
                let end = CGPoint(x: base.x + number(), y: base.y + number())
                quad(to: end, control: c)
            case "t":
                let c = lastQuadControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let end = CGPoint(x: base.x + number(), y: base.y + number())
                quad(to: end, control: c)
            case "a":
                let rx = number()
                let ry = number()
                let rotation = number()
                // Arc flags are single characters and may run together with the
                // coordinates that follow, so they cannot be read as numbers.
                let largeArc = flag()
                let sweep = flag()
                let end = CGPoint(x: base.x + number(), y: base.y + number())
                arc(to: end, rx: rx, ry: ry, rotation: rotation, largeArc: largeArc, sweep: sweep)
            case "z":
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil
                lastQuadControl = nil
            default:
                break
            }
        }

        private mutating func line(to point: CGPoint) {
            path.addLine(to: point)
            current = point
            lastCubicControl = nil
            lastQuadControl = nil
        }

        private mutating func curve(to end: CGPoint, control1: CGPoint, control2: CGPoint) {
            path.addCurve(to: end, control1: control1, control2: control2)
            current = end
            lastCubicControl = control2
            lastQuadControl = nil
        }

        private mutating func quad(to end: CGPoint, control: CGPoint) {
            path.addQuadCurve(to: end, control: control)
            current = end
            lastQuadControl = control
            lastCubicControl = nil
        }

        /// Endpoint-to-centre conversion per the SVG spec, then the sweep is
        /// approximated with cubic segments of at most 90° so the whole mark
        /// stays a single continuous subpath.
        private mutating func arc(to end: CGPoint, rx: Double, ry: Double,
                                  rotation: Double, largeArc: Bool, sweep: Bool) {
            let start = current
            guard rx != 0, ry != 0 else { return line(to: end) }
            guard start != end else { return }

            var rx = abs(rx), ry = abs(ry)
            let phi = rotation * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)

            let dx = (Double(start.x) - Double(end.x)) / 2
            let dy = (Double(start.y) - Double(end.y)) / 2
            let x1 = cosPhi * dx + sinPhi * dy
            let y1 = -sinPhi * dx + cosPhi * dy

            // Radii too small to span the endpoints are scaled up, per spec.
            let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
            if lambda > 1 {
                let factor = lambda.squareRoot()
                rx *= factor
                ry *= factor
            }

            let numerator = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
            let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
            let coefficient = (largeArc == sweep ? -1.0 : 1.0) * (numerator / denominator).squareRoot()

            let cx1 = coefficient * rx * y1 / ry
            let cy1 = -coefficient * ry * x1 / rx
            let cx = cosPhi * cx1 - sinPhi * cy1 + (Double(start.x) + Double(end.x)) / 2
            let cy = sinPhi * cx1 + cosPhi * cy1 + (Double(start.y) + Double(end.y)) / 2

            let theta1 = atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
            let theta2 = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx)
            var delta = theta2 - theta1
            if !sweep, delta > 0 { delta -= 2 * .pi }
            if sweep, delta < 0 { delta += 2 * .pi }

            let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
            let step = delta / Double(segments)
            let alpha = sin(step) * ((4 + 3 * pow(tan(step / 2), 2)).squareRoot() - 1) / 3

            func pointAt(_ theta: Double) -> CGPoint {
                let x = rx * cos(theta), y = ry * sin(theta)
                return CGPoint(x: cx + cosPhi * x - sinPhi * y,
                               y: cy + sinPhi * x + cosPhi * y)
            }
            func derivativeAt(_ theta: Double) -> CGVector {
                let x = -rx * sin(theta), y = ry * cos(theta)
                return CGVector(dx: cosPhi * x - sinPhi * y,
                                dy: sinPhi * x + cosPhi * y)
            }

            var theta = theta1
            for _ in 0..<segments {
                let next = theta + step
                let p1 = pointAt(theta), p2 = pointAt(next)
                let d1 = derivativeAt(theta), d2 = derivativeAt(next)
                path.addCurve(
                    to: p2,
                    control1: CGPoint(x: p1.x + alpha * d1.dx, y: p1.y + alpha * d1.dy),
                    control2: CGPoint(x: p2.x - alpha * d2.dx, y: p2.y - alpha * d2.dy)
                )
                theta = next
            }

            current = end
            lastCubicControl = nil
            lastQuadControl = nil
        }

        // MARK: - Scanning

        private mutating func skipSeparators() {
            while index < chars.count, chars[index] == "," || chars[index].isWhitespace {
                index += 1
            }
        }

        private mutating func number() -> CGFloat {
            skipSeparators()
            let start = index
            if index < chars.count, chars[index] == "+" || chars[index] == "-" { index += 1 }
            var seenDot = false
            while index < chars.count {
                let c = chars[index]
                if c.isNumber {
                    index += 1
                } else if c == ".", !seenDot {
                    seenDot = true
                    index += 1
                } else if c == "e" || c == "E" {
                    index += 1
                    if index < chars.count, chars[index] == "+" || chars[index] == "-" { index += 1 }
                } else {
                    break
                }
            }
            return CGFloat(Double(String(chars[start..<index])) ?? 0)
        }

        private mutating func flag() -> Bool {
            skipSeparators()
            guard index < chars.count else { return false }
            let c = chars[index]
            index += 1
            return c == "1"
        }
    }
}
