import CoreGraphics
import Foundation
import SwiftUI

/// A small parser for SVG path data (the `d` attribute), so vector logo marks
/// can live in Swift source instead of a resource bundle. Supports every path
/// command (M L H V C S Q T A Z, absolute and relative), implicit command
/// repetition, and the compact number forms design tools emit (`.5.5`,
/// `1-1`, `1e-3`, unseparated arc flags). Arcs become cubic Béziers.
enum SVGPathData {
    struct ParseError: Error, Equatable, CustomStringConvertible {
        var message: String
        var offset: Int
        var description: String { "SVG path data: \(message) at byte \(offset)" }
    }

    static func path(_ data: String) throws -> Path {
        var parser = Parser(bytes: Array(data.utf8))
        return try parser.parse()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        /// The previous segment's second control point, for S/s (cubic) and
        /// T/t (quadratic) reflection; nil when the previous segment differs.
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func parse() throws -> Path {
            var command: UInt8?
            skipSeparators()
            guard index < bytes.count else { return path }
            guard bytes[index] == UInt8(ascii: "M") || bytes[index] == UInt8(ascii: "m") else {
                throw error("path must start with a moveto")
            }
            while true {
                skipSeparators()
                guard index < bytes.count else { break }
                let byte = bytes[index]
                if Self.isCommand(byte) {
                    command = byte
                    index += 1
                } else if !startsNumber(byte) {
                    throw error("unexpected character '\(Character(Unicode.Scalar(byte)))'")
                } else if command == nil || command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                    throw error("number without a command")
                }
                guard let cmd = command else { break }
                try apply(cmd)
                // Extra coordinate pairs after a moveto are implicit linetos.
                if cmd == UInt8(ascii: "M") { command = UInt8(ascii: "L") }
                if cmd == UInt8(ascii: "m") { command = UInt8(ascii: "l") }
            }
            return path
        }

        mutating func apply(_ cmd: UInt8) throws {
            let relative = cmd >= UInt8(ascii: "a")
            let base = relative ? current : .zero
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: base.x + x, y: base.y + y) }
            var cubicControl: CGPoint?
            var quadControl: CGPoint?

            switch cmd | 0x20 { // lowercase
            case UInt8(ascii: "m"):
                let p = point(try number(), try number())
                path.move(to: p)
                current = p
                subpathStart = p
            case UInt8(ascii: "l"):
                let p = point(try number(), try number())
                path.addLine(to: p)
                current = p
            case UInt8(ascii: "h"):
                let x = try number()
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                let y = try number()
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                let c1 = point(try number(), try number())
                let c2 = point(try number(), try number())
                let p = point(try number(), try number())
                path.addCurve(to: p, control1: c1, control2: c2)
                cubicControl = c2
                current = p
            case UInt8(ascii: "s"):
                let c1 = reflected(lastCubicControl)
                let c2 = point(try number(), try number())
                let p = point(try number(), try number())
                path.addCurve(to: p, control1: c1, control2: c2)
                cubicControl = c2
                current = p
            case UInt8(ascii: "q"):
                let c = point(try number(), try number())
                let p = point(try number(), try number())
                path.addQuadCurve(to: p, control: c)
                quadControl = c
                current = p
            case UInt8(ascii: "t"):
                let c = reflected(lastQuadControl)
                let p = point(try number(), try number())
                path.addQuadCurve(to: p, control: c)
                quadControl = c
                current = p
            case UInt8(ascii: "a"):
                let rx = try number(), ry = try number(), rotation = try number()
                let largeArc = try flag(), sweep = try flag()
                let p = point(try number(), try number())
                addArc(to: p, rx: rx, ry: ry, rotation: rotation, largeArc: largeArc, sweep: sweep)
                current = p
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = subpathStart
            default:
                throw error("unsupported command")
            }
            lastCubicControl = cubicControl
            lastQuadControl = quadControl
        }

        func reflected(_ control: CGPoint?) -> CGPoint {
            guard let control else { return current }
            return CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
        }

        /// SVG 1.1 implementation notes F.6.5/F.6.6: endpoint to center
        /// parameterization, then one cubic per quarter turn at most.
        mutating func addArc(to end: CGPoint, rx: Double, ry: Double, rotation: Double, largeArc: Bool, sweep: Bool) {
            let start = current
            if start == end { return }
            var rx = abs(rx), ry = abs(ry)
            guard rx > 0, ry > 0 else {
                path.addLine(to: end)
                return
            }
            let phi = rotation * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)
            let dx2 = (start.x - end.x) / 2, dy2 = (start.y - end.y) / 2
            let x1p = cosPhi * dx2 + sinPhi * dy2
            let y1p = -sinPhi * dx2 + cosPhi * dy2

            let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
            if lambda > 1 {
                rx *= lambda.squareRoot()
                ry *= lambda.squareRoot()
            }
            let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
            let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
            let coefficient = (largeArc == sweep ? -1.0 : 1.0) * max(0, numerator / denominator).squareRoot()
            let cxp = coefficient * rx * y1p / ry
            let cyp = -coefficient * ry * x1p / rx
            let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
            let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

            let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
            let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
            let theta1 = atan2(uy, ux)
            var delta = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            if !sweep && delta > 0 { delta -= 2 * .pi }
            if sweep && delta < 0 { delta += 2 * .pi }

            func map(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: cx + rx * cosPhi * x - ry * sinPhi * y, y: cy + rx * sinPhi * x + ry * cosPhi * y)
            }
            let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
            let step = delta / Double(segments)
            let t = 4.0 / 3.0 * tan(step / 4)
            var angle = theta1
            for segment in 0..<segments {
                let next = angle + step
                let c1 = map(cos(angle) - t * sin(angle), sin(angle) + t * cos(angle))
                let c2 = map(cos(next) + t * sin(next), sin(next) - t * cos(next))
                // Land exactly on the requested endpoint, free of rounding drift.
                let p = segment == segments - 1 ? end : map(cos(next), sin(next))
                path.addCurve(to: p, control1: c1, control2: c2)
                angle = next
            }
        }

        // MARK: Scanning

        static func isCommand(_ byte: UInt8) -> Bool {
            switch byte | 0x20 {
            case UInt8(ascii: "m"), UInt8(ascii: "l"), UInt8(ascii: "h"), UInt8(ascii: "v"),
                 UInt8(ascii: "c"), UInt8(ascii: "s"), UInt8(ascii: "q"), UInt8(ascii: "t"),
                 UInt8(ascii: "a"), UInt8(ascii: "z"):
                true
            default:
                false
            }
        }

        func startsNumber(_ byte: UInt8) -> Bool {
            Self.isDigit(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+")
        }

        static func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

        mutating func skipSeparators() {
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: " "), UInt8(ascii: ","), 0x09, 0x0A, 0x0C, 0x0D: index += 1
                default: return
                }
            }
        }

        mutating func number() throws -> Double {
            skipSeparators()
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            var digits = 0
            while index < bytes.count, Self.isDigit(bytes[index]) { index += 1; digits += 1 }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                while index < bytes.count, Self.isDigit(bytes[index]) { index += 1; digits += 1 }
            }
            guard digits > 0 else {
                index = start
                throw error("expected a number")
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                var lookahead = index + 1
                if lookahead < bytes.count, bytes[lookahead] == UInt8(ascii: "-") || bytes[lookahead] == UInt8(ascii: "+") {
                    lookahead += 1
                }
                if lookahead < bytes.count, Self.isDigit(bytes[lookahead]) {
                    index = lookahead
                    while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
                }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard let value = Double(text), value.isFinite else {
                index = start
                throw error("invalid number '\(text)'")
            }
            return value
        }

        /// Arc flags are a single 0 or 1 and may run straight into the next
        /// value (`a1 1 0 0110 10`).
        mutating func flag() throws -> Bool {
            skipSeparators()
            guard index < bytes.count else { throw error("expected an arc flag") }
            switch bytes[index] {
            case UInt8(ascii: "0"): index += 1; return false
            case UInt8(ascii: "1"): index += 1; return true
            default: throw error("expected an arc flag")
            }
        }

        func error(_ message: String) -> ParseError { ParseError(message: message, offset: index) }
    }
}
