import CoreGraphics
import Foundation

/// Where the drawing lands in the exported file.
struct SVGLayout {
    var width: CGFloat
    var height: CGFloat
    /// Page space (y down) to output space.
    var transform: CGAffineTransform
}

enum SVGWriter {
    /// `frame` is the symbol's layout frame in page space. A canvas of 0 keeps
    /// that frame at the rendered point size; otherwise the painted content is
    /// centered and scaled into a square canvas.
    static func layout(for drawing: VectorDrawing, frame: CGRect, options: ExportOptions) -> SVGLayout {
        let content = drawing.bounds.isNull ? frame : drawing.bounds
        guard options.canvas > 0 else {
            let box = frame.union(content)
            return SVGLayout(width: box.width, height: box.height,
                             transform: CGAffineTransform(translationX: -box.minX, y: -box.minY))
        }
        let side = CGFloat(min(max(options.canvas, 8), 4096))
        let usable = side * (1 - 2 * CGFloat(min(max(options.padding, 0), 0.45)))
        let scale = usable / max(content.width, content.height, 0.001)
        let transform = CGAffineTransform(translationX: -content.midX, y: -content.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: side / 2, y: side / 2))
        return SVGLayout(width: side, height: side, transform: transform)
    }

    static func svg(_ drawing: VectorDrawing, layout: SVGLayout, title: String, background: RGBA?) -> String {
        var writer = Writer(drawing: drawing, transform: layout.transform)
        let width = svgNumber(layout.width), height = svgNumber(layout.height)
        writer.lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        writer.lines.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\">")
        writer.lines.append("  <title>\(escape(title))</title>")
        writer.writeDefs(maskRegion: CGRect(x: -layout.width, y: -layout.height,
                                            width: layout.width * 3, height: layout.height * 3))
        if let background {
            writer.lines.append("  <rect width=\"\(width)\" height=\"\(height)\" fill=\"\(background.hex)\"\(opacityAttr("fill-opacity", background.alpha))/>")
        }
        writer.write(drawing.nodes, indent: "  ")
        writer.lines.append("</svg>")
        return writer.lines.joined(separator: "\n") + "\n"
    }

    private struct Writer {
        let drawing: VectorDrawing
        let transform: CGAffineTransform
        var lines: [String] = []

        private var usedClips = Set<String>()
        private var usedGradients = Set<String>()
        private var usedMasks = Set<String>()

        init(drawing: VectorDrawing, transform: CGAffineTransform) {
            self.drawing = drawing
            self.transform = transform
            collect(drawing.nodes)
        }

        private mutating func collect(_ nodes: [VectorNode]) {
            for node in nodes {
                switch node {
                case .shape(let shape):
                    useClip(shape.clipID)
                    useMask(shape.maskID)
                    if case .gradient(let id)? = shape.fill { usedGradients.insert(id) }
                case .group(let group):
                    useClip(group.clipID)
                    useMask(group.maskID)
                    collect(group.children)
                }
            }
        }

        private mutating func useClip(_ id: String?) {
            var current = id
            while let clipID = current, !usedClips.contains(clipID), let clip = drawing.clips[clipID] {
                usedClips.insert(clipID)
                current = clip.parent
            }
        }

        private mutating func useMask(_ id: String?) {
            guard let id, !usedMasks.contains(id), let mask = drawing.masks[id] else { return }
            usedMasks.insert(id)
            collect(mask.children)
        }

        mutating func writeDefs(maskRegion: CGRect) {
            guard !(usedClips.isEmpty && usedGradients.isEmpty && usedMasks.isEmpty) else { return }
            lines.append("  <defs>")
            for (id, gradient) in drawing.gradients.filter({ usedGradients.contains($0.key) }).sorted(by: { $0.value.index < $1.value.index }) {
                writeGradient(id, gradient)
            }
            for (id, clip) in drawing.clips.filter({ usedClips.contains($0.key) }).sorted(by: { $0.value.index < $1.value.index }) {
                let parent = clip.parent.map { " clip-path=\"url(#\($0))\"" } ?? ""
                let rule = clip.evenOdd ? " clip-rule=\"evenodd\"" : ""
                lines.append("    <clipPath id=\"\(id)\" clipPathUnits=\"userSpaceOnUse\"\(parent)><path d=\"\(pathData(clip.path))\"\(rule)/></clipPath>")
            }
            for (id, mask) in drawing.masks.filter({ usedMasks.contains($0.key) }).sorted(by: { $0.value.index < $1.value.index }) {
                let type = mask.alpha ? " style=\"mask-type:alpha\"" : ""
                lines.append("    <mask id=\"\(id)\" maskUnits=\"userSpaceOnUse\" x=\"\(svgNumber(maskRegion.minX))\" y=\"\(svgNumber(maskRegion.minY))\" width=\"\(svgNumber(maskRegion.width))\" height=\"\(svgNumber(maskRegion.height))\"\(type)>")
                if let backdrop = mask.backdrop {
                    lines.append("      <rect x=\"\(svgNumber(maskRegion.minX))\" y=\"\(svgNumber(maskRegion.minY))\" width=\"\(svgNumber(maskRegion.width))\" height=\"\(svgNumber(maskRegion.height))\" fill=\"\(backdrop.hex)\"/>")
                }
                write(mask.children, indent: "      ")
                lines.append("    </mask>")
            }
            lines.append("  </defs>")
        }

        private mutating func writeGradient(_ id: String, _ gradient: VectorGradient) {
            let m = gradient.transform.concatenating(transform)
            let c = gradient.coords
            // A similarity transform (rotation, uniform scale, translation)
            // can be baked into the coordinates; anything else stays a matrix.
            let similar = abs(m.a * m.a + m.b * m.b - (m.c * m.c + m.d * m.d)) < 1e-6 * max(1, m.a * m.a + m.b * m.b)
                && abs(m.a * m.c + m.b * m.d) < 1e-6 * max(1, m.a * m.a + m.b * m.b)
            let scale = sqrt(abs(m.a * m.d - m.b * m.c))
            var attributes: String
            if gradient.radial {
                if similar {
                    let f = CGPoint(x: c[0], y: c[1]).applying(m), center = CGPoint(x: c[3], y: c[4]).applying(m)
                    attributes = "fx=\"\(svgNumber(f.x))\" fy=\"\(svgNumber(f.y))\" fr=\"\(svgNumber(c[2] * scale))\" cx=\"\(svgNumber(center.x))\" cy=\"\(svgNumber(center.y))\" r=\"\(svgNumber(c[5] * scale))\""
                } else {
                    attributes = "fx=\"\(svgNumber(c[0]))\" fy=\"\(svgNumber(c[1]))\" fr=\"\(svgNumber(c[2]))\" cx=\"\(svgNumber(c[3]))\" cy=\"\(svgNumber(c[4]))\" r=\"\(svgNumber(c[5]))\" gradientTransform=\"\(matrix(m))\""
                }
            } else {
                if similar {
                    let p0 = CGPoint(x: c[0], y: c[1]).applying(m), p1 = CGPoint(x: c[2], y: c[3]).applying(m)
                    attributes = "x1=\"\(svgNumber(p0.x))\" y1=\"\(svgNumber(p0.y))\" x2=\"\(svgNumber(p1.x))\" y2=\"\(svgNumber(p1.y))\""
                } else {
                    attributes = "x1=\"\(svgNumber(c[0]))\" y1=\"\(svgNumber(c[1]))\" x2=\"\(svgNumber(c[2]))\" y2=\"\(svgNumber(c[3]))\" gradientTransform=\"\(matrix(m))\""
                }
            }
            let tag = gradient.radial ? "radialGradient" : "linearGradient"
            lines.append("    <\(tag) id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" \(attributes)>")
            for stop in gradient.stops {
                lines.append("      <stop offset=\"\(svgNumber(stop.offset))\" stop-color=\"\(stop.color.hex)\"/>")
            }
            lines.append("    </\(tag)>")
        }

        mutating func write(_ nodes: [VectorNode], indent: String) {
            for node in nodes {
                switch node {
                case .shape(let shape):
                    lines.append(indent + shapeElement(shape))
                case .group(let group):
                    var attributes = opacityAttr("opacity", group.opacity)
                    if let clip = group.clipID { attributes += " clip-path=\"url(#\(clip))\"" }
                    if let mask = group.maskID { attributes += " mask=\"url(#\(mask))\"" }
                    lines.append(indent + "<g\(attributes)>")
                    write(group.children, indent: indent + "  ")
                    lines.append(indent + "</g>")
                }
            }
        }

        private func shapeElement(_ shape: VectorShape) -> String {
            var attributes = "d=\"\(pathData(shape.path))\""
            switch shape.fill {
            case .color(let color)?:
                attributes += " fill=\"\(color.hex)\"" + opacityAttr("fill-opacity", shape.fillOpacity * color.alpha)
                if shape.evenOdd { attributes += " fill-rule=\"evenodd\"" }
            case .gradient(let id)?:
                attributes += " fill=\"url(#\(id))\"" + opacityAttr("fill-opacity", shape.fillOpacity)
                if shape.evenOdd { attributes += " fill-rule=\"evenodd\"" }
            case nil:
                attributes += " fill=\"none\""
            }
            if let stroke = shape.stroke {
                let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
                attributes += " stroke=\"\(stroke.hex)\" stroke-width=\"\(svgNumber(shape.strokeWidth * scale))\""
                attributes += opacityAttr("stroke-opacity", shape.strokeOpacity * stroke.alpha)
                if shape.lineCap == 1 { attributes += " stroke-linecap=\"round\"" }
                if shape.lineCap == 2 { attributes += " stroke-linecap=\"square\"" }
                if shape.lineJoin == 1 { attributes += " stroke-linejoin=\"round\"" }
                if shape.lineJoin == 2 { attributes += " stroke-linejoin=\"bevel\"" }
            }
            if let clip = shape.clipID { attributes += " clip-path=\"url(#\(clip))\"" }
            if let mask = shape.maskID { attributes += " mask=\"url(#\(mask))\"" }
            return "<path \(attributes)/>"
        }

        private func pathData(_ path: CGPath) -> String {
            var parts: [String] = []
            let t = transform
            path.applyWithBlock { pointer in
                let element = pointer.pointee
                func point(_ i: Int) -> String {
                    let p = element.points[i].applying(t)
                    return "\(svgNumber(p.x)) \(svgNumber(p.y))"
                }
                switch element.type {
                case .moveToPoint: parts.append("M" + point(0))
                case .addLineToPoint: parts.append("L" + point(0))
                case .addQuadCurveToPoint: parts.append("Q" + point(0) + " " + point(1))
                case .addCurveToPoint: parts.append("C" + point(0) + " " + point(1) + " " + point(2))
                case .closeSubpath: parts.append("Z")
                @unknown default: break
                }
            }
            return parts.joined()
        }

        private func matrix(_ m: CGAffineTransform) -> String {
            "matrix(\(svgNumber(m.a)) \(svgNumber(m.b)) \(svgNumber(m.c)) \(svgNumber(m.d)) \(svgNumber(m.tx)) \(svgNumber(m.ty)))"
        }
    }

    /// Up to three decimals, no trailing zeros, no "-0".
    static func number(_ value: CGFloat) -> String { svgNumber(value) }

    private static func escape(_ input: String) -> String {
        input.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private func svgNumber(_ value: CGFloat) -> String {
    guard value.isFinite else { return "0" }
    var rounded = (Double(value) * 1000).rounded() / 1000
    if rounded == 0 { rounded = 0 }
    if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int64(rounded)) }
    var text = String(format: "%.3f", rounded)
    while text.hasSuffix("0") { text.removeLast() }
    return text
}

private func opacityAttr(_ name: String, _ value: Double) -> String {
    value >= 0.9995 ? "" : " \(name)=\"\(svgNumber(CGFloat(min(max(value, 0), 1))))\""
}
