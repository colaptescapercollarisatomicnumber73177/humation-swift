import CoreGraphics
import Foundation

// MARK: - SVG fragment → geometry
//
// Parses one inline part SVG (`<svg>…</svg>`) into a `HumationParsedPart`. The
// SVG's own width/height/viewBox are ignored: raw path coordinates are kept in
// the part's local space and positioned by `layerSlot.offset` at compose time
// (matching the reference engine, which strips the `<svg>` wrapper and only
// translates the inner content).
//
// Cascade handled per the SVG/CSS model: inherited (from ancestors) → element
// presentation attributes → matched `<style>` class rules (author stylesheet
// wins over presentation attributes). `opacity` is treated per-element (not
// inherited). Only the features that actually occur in the asset set are
// implemented — see the asset scan.

final class HumationSVGParser: NSObject, XMLParserDelegate {

    /// Parse a fragment. Returns empty geometry on failure (never throws).
    static func parse(_ svg: String) -> HumationParsedPart {
        let parser = HumationSVGParser()
        guard let data = svg.data(using: .utf8) else {
            return HumationParsedPart(shapes: [], clips: [:])
        }
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return HumationParsedPart(shapes: parser.shapes, clips: parser.clips)
    }

    // MARK: Output

    private var shapes: [HumationShape] = []
    private var clips: [String: HumationClip] = [:]

    // MARK: Inherited render context

    private struct Context {
        var ctm: CGAffineTransform
        var paint: HumationPaintStyle
        var clipIDs: [String]
    }

    private var stack: [Context] = [
        Context(ctm: .identity, paint: HumationPaintStyle(), clipIDs: [])
    ]
    private var top: Context { stack[stack.count - 1] }

    // MARK: CSS + clip-build state

    private var cssClasses: [String: PaintAttributes] = [:]
    private var inStyle = false
    private var styleText = ""

    private var clipBuildID: String?
    private var clipBuildPath: CGMutablePath?
    private var clipBuildRule: CGPathFillRule = .winding

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attrs: [String: String]
    ) {
        let name = elementName.lowercased()

        switch name {
        case "style":
            inStyle = true
            styleText = ""
            return

        case "clippath":
            clipBuildID = attrs["id"]
            clipBuildPath = CGMutablePath()
            clipBuildRule = (attrs["clip-rule"] == "evenodd") ? .evenOdd : .winding
            // clipPath establishes its own context for any transforms on it.
            pushContainer(attrs: attrs)
            return

        case "svg", "defs", "g":
            pushContainer(attrs: attrs)
            return

        default:
            break
        }

        // A drawable primitive.
        guard let local = makePrimitivePath(name, attrs) else { return }

        // Bake the accumulated transform (+ any element transform) into the path.
        var ctm = top.ctm
        if let t = attrs["transform"] {
            ctm = HumationTransform.parse(t).concatenating(ctm)
        }
        guard let baked = local.copy(using: &ctm) else { return }

        if clipBuildPath != nil {
            clipBuildPath?.addPath(baked)
            return
        }

        var paint = resolvedPaint(attrs: attrs, fillRuleAttr: attrs["fill-rule"])
        // The transform is baked into the path geometry, but stroke-width is a
        // separate property that SVG scales with the coordinate system. Many
        // parts (all glasses, some items) draw inside a `scale(s)` group with a
        // large raw stroke-width (e.g. r=52, stroke-width=25.51 under
        // scale(0.06667)); without scaling the width too, the stroke renders
        // ~15× too thick and floods the shape into a solid black blob (this is
        // what painted black lenses over every face). Scale by the CTM's linear
        // factor √|det| (uniform scale → s; assets only use uniform scale).
        let ctmScale = (ctm.a * ctm.d - ctm.b * ctm.c).magnitude.squareRoot()
        if ctmScale > 0, ctmScale != 1 {
            paint.strokeWidth *= ctmScale
        }
        shapes.append(HumationShape(path: baked, paint: paint, clipPathIDs: top.clipIDs))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inStyle { styleText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()

        switch name {
        case "style":
            inStyle = false
            parseCSS(styleText)
            return

        case "clippath":
            if let id = clipBuildID, let path = clipBuildPath {
                clips[id] = HumationClip(path: path, fillRule: clipBuildRule)
            }
            clipBuildID = nil
            clipBuildPath = nil
            popContainer()
            return

        case "svg", "defs", "g":
            popContainer()
            return

        default:
            return
        }
    }

    // MARK: Container push/pop (transform + inherited paint + clip)

    private func pushContainer(attrs: [String: String]) {
        var ctm = top.ctm
        if let t = attrs["transform"] {
            ctm = HumationTransform.parse(t).concatenating(ctm)
        }
        // Inherited paint carries down (opacity excluded — see resolvedPaint).
        let paint = mergedInheritablePaint(into: top.paint, attrs: attrs)

        var clipIDs = top.clipIDs
        if let clip = attrs["clip-path"], let id = clipRefID(clip) {
            clipIDs.append(id)
        }
        stack.append(Context(ctm: ctm, paint: paint, clipIDs: clipIDs))
    }

    private func popContainer() {
        if stack.count > 1 { stack.removeLast() }
    }

    // MARK: Paint resolution

    /// Effective paint for a leaf shape: inherited → presentation attrs → class
    /// rules. `opacity` starts at 1 per element (not inherited).
    private func resolvedPaint(attrs: [String: String], fillRuleAttr: String?) -> HumationPaintStyle {
        var style = top.paint
        style.opacity = 1
        applyPresentation(attrs, to: &style)
        applyClasses(attrs["class"], to: &style)
        if let rule = fillRuleAttr {
            style.fillRule = (rule == "evenodd") ? .evenOdd : .winding
        }
        return style
    }

    /// Inheritable paint for a container: applies presentation + class but keeps
    /// it as the new inherited baseline for descendants.
    private func mergedInheritablePaint(
        into base: HumationPaintStyle, attrs: [String: String]
    ) -> HumationPaintStyle {
        var style = base
        applyPresentation(attrs, to: &style)
        applyClasses(attrs["class"], to: &style)
        return style
    }

    private func applyPresentation(_ attrs: [String: String], to style: inout HumationPaintStyle) {
        if let v = attrs["fill"] { style.fill = HumationColorValue.parse(v) }
        if let v = attrs["stroke"] { style.stroke = HumationColorValue.parse(v) }
        if let v = attrs["stroke-width"], let n = Double(v) { style.strokeWidth = CGFloat(n) }
        if let v = attrs["stroke-miterlimit"], let n = Double(v) { style.miterLimit = CGFloat(n) }
        if let v = attrs["stroke-linecap"] { style.lineCap = lineCap(v) }
        if let v = attrs["stroke-linejoin"] { style.lineJoin = lineJoin(v) }
        if let v = attrs["opacity"], let n = Double(v) { style.opacity = CGFloat(n) }
        if let v = attrs["fill-rule"] { style.fillRule = (v == "evenodd") ? .evenOdd : .winding }
    }

    private func applyClasses(_ classAttr: String?, to style: inout HumationPaintStyle) {
        guard let classAttr else { return }
        for cls in classAttr.split(separator: " ") {
            cssClasses[String(cls)]?.apply(to: &style)
        }
    }

    // MARK: Primitive dispatch

    private func makePrimitivePath(_ name: String, _ attrs: [String: String]) -> CGPath? {
        func f(_ key: String) -> CGFloat { CGFloat(Double(attrs[key] ?? "") ?? 0) }
        switch name {
        case "path":
            guard let d = attrs["d"] else { return nil }
            return HumationPathParser.path(from: d)
        case "circle":
            return HumationPrimitive.circle(cx: f("cx"), cy: f("cy"), r: f("r"))
        case "ellipse":
            return HumationPrimitive.ellipse(cx: f("cx"), cy: f("cy"), rx: f("rx"), ry: f("ry"))
        case "rect":
            return HumationPrimitive.rect(
                x: f("x"), y: f("y"), width: f("width"), height: f("height"),
                rx: f("rx"), ry: f("ry")
            )
        case "line":
            return HumationPrimitive.line(x1: f("x1"), y1: f("y1"), x2: f("x2"), y2: f("y2"))
        case "polygon":
            return HumationPrimitive.polygon(
                points: HumationPrimitive.parsePoints(attrs["points"] ?? ""), closed: true
            )
        case "polyline":
            return HumationPrimitive.polygon(
                points: HumationPrimitive.parsePoints(attrs["points"] ?? ""), closed: false
            )
        default:
            return nil
        }
    }

    // MARK: CSS `<style>` parsing

    /// Partial paint overrides parsed from a class rule or presentation attrs.
    private struct PaintAttributes {
        var fill: HumationSVGColor?
        var stroke: HumationSVGColor?
        var strokeWidth: CGFloat?
        var miterLimit: CGFloat?
        var lineCap: CGLineCap?
        var lineJoin: CGLineJoin?
        var opacity: CGFloat?

        func apply(to style: inout HumationPaintStyle) {
            if let v = fill { style.fill = v }
            if let v = stroke { style.stroke = v }
            if let v = strokeWidth { style.strokeWidth = v }
            if let v = miterLimit { style.miterLimit = v }
            if let v = lineCap { style.lineCap = v }
            if let v = lineJoin { style.lineJoin = v }
            if let v = opacity { style.opacity = v }
        }

        /// Layer `other`'s non-nil fields on top of this one (used to merge a
        /// class declared across multiple `<style>` rules / comma selectors).
        mutating func overlay(_ other: PaintAttributes) {
            if let v = other.fill { fill = v }
            if let v = other.stroke { stroke = v }
            if let v = other.strokeWidth { strokeWidth = v }
            if let v = other.miterLimit { miterLimit = v }
            if let v = other.lineCap { lineCap = v }
            if let v = other.lineJoin { lineJoin = v }
            if let v = other.opacity { opacity = v }
        }
    }

    /// Parse `.a, .b { prop: val; … }` blocks. Supports comma-separated
    /// selectors; `isolation` is ignored.
    private func parseCSS(_ css: String) {
        var text = css
        // Strip CSS comments.
        while let open = text.range(of: "/*"), let close = text.range(of: "*/", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }

        var scanner = text[...]
        while let braceOpen = scanner.firstIndex(of: "{") {
            let selectorPart = scanner[scanner.startIndex..<braceOpen]
            guard let braceClose = scanner[braceOpen...].firstIndex(of: "}") else { break }
            let body = scanner[scanner.index(after: braceOpen)..<braceClose]

            let attributes = parseDeclarations(String(body))
            for selector in selectorPart.split(separator: ",") {
                let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix(".") else { continue }
                let className = String(trimmed.dropFirst())
                // Merge into any existing rule for this class (later wins).
                var existing = cssClasses[className] ?? PaintAttributes()
                existing.overlay(attributes)
                cssClasses[className] = existing
            }
            scanner = scanner[scanner.index(after: braceClose)...]
        }
    }

    private func parseDeclarations(_ body: String) -> PaintAttributes {
        var attrs = PaintAttributes()
        for decl in body.split(separator: ";") {
            let pair = decl.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pair.count == 2 else { continue }
            let (prop, value) = (pair[0].lowercased(), pair[1])
            switch prop {
            case "fill": attrs.fill = HumationColorValue.parse(value)
            case "stroke": attrs.stroke = HumationColorValue.parse(value)
            case "stroke-width": attrs.strokeWidth = Double(value).map { CGFloat($0) }
            case "stroke-miterlimit": attrs.miterLimit = Double(value).map { CGFloat($0) }
            case "stroke-linecap": attrs.lineCap = lineCap(value)
            case "stroke-linejoin": attrs.lineJoin = lineJoin(value)
            case "opacity": attrs.opacity = Double(value).map { CGFloat($0) }
            default: break // isolation, etc.
            }
        }
        return attrs
    }

    // MARK: Small helpers

    private func clipRefID(_ value: String) -> String? {
        // `url(#id)`
        guard let hash = value.firstIndex(of: "#"),
              let close = value.lastIndex(of: ")")
        else { return nil }
        return String(value[value.index(after: hash)..<close])
    }

    private func lineCap(_ v: String) -> CGLineCap {
        switch v {
        case "round": return .round
        case "square": return .square
        default: return .butt
        }
    }

    private func lineJoin(_ v: String) -> CGLineJoin {
        switch v {
        case "round": return .round
        case "bevel": return .bevel
        default: return .miter
        }
    }
}
