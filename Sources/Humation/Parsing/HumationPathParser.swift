import CoreGraphics
import Foundation

// MARK: - SVG path `d` parser
//
// Supports exactly the command set present in the asset library: M/m L/l H/h
// V/v C/c S/s Z/z (absolute + relative). No arcs (A/a) or quadratics (Q/q/T/t)
// exist in the data — see the asset scan. Handles SVG number quirks: implicit
// command repetition, an implicit L after M, and concatenated numbers
// (`1.5.3` → 1.5, 0.3 ; `3-4` → 3, -4).

enum HumationPathParser {
    static func path(from d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens = Tokenizer(d)

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint? = nil
        var command: Character? = nil

        func num() -> CGFloat? { tokens.nextNumber() }
        func pair() -> CGPoint? {
            guard let x = num(), let y = num() else { return nil }
            return CGPoint(x: x, y: y)
        }

        while true {
            // A command letter, or an implicit repeat of the previous command.
            if let letter = tokens.peekCommand() {
                command = letter
                tokens.consumeCommand()
            } else if tokens.peekNumber() == nil {
                break // end of input
            } else if command == nil {
                break // numbers with no command — malformed; stop safely
            }

            guard let cmd = command else { break }
            let isRelative = cmd.isLowercase
            let upper = Character(cmd.uppercased())

            switch upper {
            case "M":
                guard var p = pair() else { return path }
                if isRelative { p = CGPoint(x: current.x + p.x, y: current.y + p.y) }
                path.move(to: p)
                current = p
                subpathStart = p
                lastCubicControl = nil
                // Subsequent pairs after an M are implicit L commands.
                command = isRelative ? "l" : "L"

            case "L":
                guard var p = pair() else { return path }
                if isRelative { p = CGPoint(x: current.x + p.x, y: current.y + p.y) }
                path.addLine(to: p)
                current = p
                lastCubicControl = nil

            case "H":
                guard let x = num() else { return path }
                let nx = isRelative ? current.x + x : x
                let p = CGPoint(x: nx, y: current.y)
                path.addLine(to: p)
                current = p
                lastCubicControl = nil

            case "V":
                guard let y = num() else { return path }
                let ny = isRelative ? current.y + y : y
                let p = CGPoint(x: current.x, y: ny)
                path.addLine(to: p)
                current = p
                lastCubicControl = nil

            case "C":
                guard var c1 = pair(), var c2 = pair(), var end = pair() else { return path }
                if isRelative {
                    c1 = CGPoint(x: current.x + c1.x, y: current.y + c1.y)
                    c2 = CGPoint(x: current.x + c2.x, y: current.y + c2.y)
                    end = CGPoint(x: current.x + end.x, y: current.y + end.y)
                }
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
                lastCubicControl = c2

            case "S":
                // Smooth cubic: first control is the reflection of the previous
                // cubic's second control about the current point.
                guard var c2 = pair(), var end = pair() else { return path }
                if isRelative {
                    c2 = CGPoint(x: current.x + c2.x, y: current.y + c2.y)
                    end = CGPoint(x: current.x + end.x, y: current.y + end.y)
                }
                let c1: CGPoint
                if let last = lastCubicControl {
                    c1 = CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                } else {
                    c1 = current
                }
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
                lastCubicControl = c2

            case "Z":
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil

            default:
                return path // unsupported command — stop safely
            }
        }
        return path
    }
}

// MARK: - Number/command tokenizer

private struct Tokenizer {
    private let chars: [Character]
    private var index = 0

    private static let commandSet: Set<Character> = [
        "M", "m", "L", "l", "H", "h", "V", "v", "C", "c", "S", "s", "Z", "z",
        "Q", "q", "T", "t", "A", "a", // not produced by assets, but recognised as commands
    ]

    init(_ string: String) {
        chars = Array(string)
    }

    private mutating func skipSeparators() {
        while index < chars.count {
            let c = chars[index]
            if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" {
                index += 1
            } else {
                break
            }
        }
    }

    mutating func peekCommand() -> Character? {
        skipSeparators()
        guard index < chars.count else { return nil }
        let c = chars[index]
        return Tokenizer.commandSet.contains(c) ? c : nil
    }

    mutating func consumeCommand() {
        index += 1
    }

    mutating func peekNumber() -> Character? {
        skipSeparators()
        guard index < chars.count else { return nil }
        let c = chars[index]
        return (c.isNumber || c == "." || c == "-" || c == "+") ? c : nil
    }

    /// Reads one SVG number (optional sign, digits, one dot, optional exponent).
    mutating func nextNumber() -> CGFloat? {
        skipSeparators()
        guard index < chars.count else { return nil }

        let start = index
        if chars[index] == "-" || chars[index] == "+" { index += 1 }
        var sawDigit = false
        while index < chars.count, chars[index].isNumber {
            index += 1
            sawDigit = true
        }
        if index < chars.count, chars[index] == "." {
            index += 1
            while index < chars.count, chars[index].isNumber {
                index += 1
                sawDigit = true
            }
        }
        if sawDigit, index < chars.count, chars[index] == "e" || chars[index] == "E" {
            let mark = index
            index += 1
            if index < chars.count, chars[index] == "-" || chars[index] == "+" { index += 1 }
            var expDigit = false
            while index < chars.count, chars[index].isNumber {
                index += 1
                expDigit = true
            }
            if !expDigit { index = mark } // not a real exponent; rewind
        }

        guard sawDigit else {
            index = start
            return nil
        }
        return CGFloat(Double(String(chars[start..<index])) ?? 0)
    }
}

// MARK: - Primitive shape builders

enum HumationPrimitive {
    static func circle(cx: CGFloat, cy: CGFloat, r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
    }

    static func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry), transform: nil)
    }

    static func rect(
        x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rx: CGFloat, ry: CGFloat
    ) -> CGPath {
        let rect = CGRect(x: x, y: y, width: width, height: height)
        if rx > 0 || ry > 0 {
            return CGPath(
                roundedRect: rect,
                cornerWidth: rx > 0 ? rx : ry,
                cornerHeight: ry > 0 ? ry : rx,
                transform: nil
            )
        }
        return CGPath(rect: rect, transform: nil)
    }

    static func line(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x1, y: y1))
        path.addLine(to: CGPoint(x: x2, y: y2))
        return path
    }

    static func polygon(points: [CGPoint], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        if closed { path.closeSubpath() }
        return path
    }

    /// Parse a `points="x1,y1 x2,y2 …"` list.
    static func parsePoints(_ raw: String) -> [CGPoint] {
        let nums = raw
            .split { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" || $0 == "\r" }
            .compactMap { Double($0) }
        var points: [CGPoint] = []
        var i = 0
        while i + 1 < nums.count {
            points.append(CGPoint(x: nums[i], y: nums[i + 1]))
            i += 2
        }
        return points
    }
}
