@preconcurrency import CoreGraphics
import Foundation

// MARK: - Geometry model
//
// Intermediate render model produced by `HumationSVGParser`. It stores colour
// *bindings* (slot vs fixed vs none), never resolved colours, so the same parsed
// geometry is reused across every recolour — recolouring touches no geometry.

/// A paint source for a fill or stroke.
enum HumationSVGColor: Equatable, Sendable {
    /// Recolourable: bound to a `var(--hm-SLOT, #fallback)` reference.
    case slot(HumationColorSlot, fallback: HumationRGBA)
    /// Fixed (intentionally non-recolourable) colour.
    case fixed(HumationRGBA)
    case none
}

/// Plain RGBA so the model stays `Sendable` (CGColor isn't); converted to
/// `CGColor` at draw time.
struct HumationRGBA: Equatable, Hashable, Sendable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat

    var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static let black = HumationRGBA(r: 0, g: 0, b: 0, a: 1)
    static let white = HumationRGBA(r: 1, g: 1, b: 1, a: 1)
}

struct HumationPaintStyle: Equatable, Sendable {
    var fill: HumationSVGColor = .fixed(.black) // SVG initial fill is black.
    var stroke: HumationSVGColor = .none
    var strokeWidth: CGFloat = 1
    var lineCap: CGLineCap = .butt
    var lineJoin: CGLineJoin = .miter
    var miterLimit: CGFloat = 4
    var fillRule: CGPathFillRule = .winding
    var opacity: CGFloat = 1
}

/// One drawable shape: a flattened (transform-baked) path plus its paint and
/// any active clip path id(s).
struct HumationShape: @unchecked Sendable {
    var path: CGPath
    var paint: HumationPaintStyle
    /// Active clip path ids (outermost → innermost), intersected at draw time.
    var clipPathIDs: [String]
}

struct HumationClip: @unchecked Sendable {
    var path: CGPath
    var fillRule: CGPathFillRule
}

/// Fully parsed part: ordered shapes + the clip paths they reference.
struct HumationParsedPart: @unchecked Sendable {
    var shapes: [HumationShape]
    var clips: [String: HumationClip]
}

// MARK: - Colour parsing

enum HumationColorValue {
    /// Parse an SVG fill/stroke value (`none`, `#hex`, `var(--hm-…)`, `ivory`).
    static func parse(_ raw: String) -> HumationSVGColor {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.caseInsensitiveCompare("none") == .orderedSame {
            return .none
        }
        if value.hasPrefix("var(") {
            return parseVar(value)
        }
        if let rgba = HumationRGBA(hex: value) {
            return .fixed(rgba)
        }
        if let named = namedColors[value.lowercased()] {
            return .fixed(named)
        }
        return .fixed(.black)
    }

    /// `var(--hm-SLOT, #FALLBACK)` → a slot binding. Falls back to black when no
    /// default is present.
    private static func parseVar(_ value: String) -> HumationSVGColor {
        guard
            let open = value.firstIndex(of: "("),
            let close = value.lastIndex(of: ")")
        else { return .fixed(.black) }

        let inner = value[value.index(after: open)..<close]
        let parts = inner.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let name = parts.first, name.hasPrefix("--hm-") else {
            return .fixed(.black)
        }
        let slotName = String(name.dropFirst("--hm-".count))
        guard let slot = HumationColorSlot(rawValue: slotName) else {
            return .fixed(.black)
        }
        let fallback = parts.count > 1 ? (HumationRGBA(hex: parts[1]) ?? .black) : .black
        return .slot(slot, fallback: fallback)
    }

    /// Named colours that appear in the asset set (currently just `ivory`),
    /// plus the common ones for safety.
    private static let namedColors: [String: HumationRGBA] = [
        "ivory": HumationRGBA(r: 1, g: 1, b: 240 / 255, a: 1),
        "white": .white,
        "black": .black,
    ]
}

extension HumationRGBA {
    /// Parse `#RGB`, `#RRGGBB`, `RGB`, or `RRGGBB`.
    init?(hex raw: String) {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.allSatisfy(\.isHexDigit) else { return nil }

        let value: UInt64
        switch hex.count {
        case 3:
            // Expand each nibble (e.g. F0A → FF00AA).
            let chars = Array(hex)
            let expanded = String([chars[0], chars[0], chars[1], chars[1], chars[2], chars[2]])
            guard let v = UInt64(expanded, radix: 16) else { return nil }
            value = v
        case 6:
            guard let v = UInt64(hex, radix: 16) else { return nil }
            value = v
        default:
            return nil
        }
        self.init(
            r: CGFloat((value >> 16) & 0xFF) / 255,
            g: CGFloat((value >> 8) & 0xFF) / 255,
            b: CGFloat(value & 0xFF) / 255,
            a: 1
        )
    }
}

// MARK: - Transform parsing

enum HumationTransform {
    /// Parse an SVG `transform` attribute. The asset set uses only `translate`
    /// and `scale` (possibly combined, e.g. `translate(-2, 3) scale(0.0813)`),
    /// applied left-to-right.
    static func parse(_ raw: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        let scanner = Scanner(string: raw)
        scanner.charactersToBeSkipped = CharacterSet.whitespacesAndNewlines

        while !scanner.isAtEnd {
            guard let fn = scanFunctionName(scanner) else { break }
            guard scanner.scanString("(") != nil else { break }
            var args: [CGFloat] = []
            while let n = scanner.scanDouble() {
                args.append(CGFloat(n))
                _ = scanner.scanString(",")
            }
            _ = scanner.scanString(")")

            let step: CGAffineTransform
            switch fn {
            case "translate":
                step = CGAffineTransform(
                    translationX: args.first ?? 0, y: args.count > 1 ? args[1] : 0
                )
            case "scale":
                let sx = args.first ?? 1
                let sy = args.count > 1 ? args[1] : sx
                step = CGAffineTransform(scaleX: sx, y: sy)
            case "rotate":
                let deg = args.first ?? 0
                let rad = deg * .pi / 180
                if args.count >= 3 {
                    step = CGAffineTransform(translationX: args[1], y: args[2])
                        .rotated(by: rad)
                        .translatedBy(x: -args[1], y: -args[2])
                } else {
                    step = CGAffineTransform(rotationAngle: rad)
                }
            case "matrix" where args.count == 6:
                step = CGAffineTransform(
                    a: args[0], b: args[1], c: args[2], d: args[3], tx: args[4], ty: args[5]
                )
            default:
                step = .identity
            }
            // Left-to-right: child coords are transformed by later functions first,
            // so pre-concatenate (step applied before the accumulated result).
            result = step.concatenating(result)
        }
        return result
    }

    private static func scanFunctionName(_ scanner: Scanner) -> String? {
        scanner.scanCharacters(from: CharacterSet.letters)
    }
}
