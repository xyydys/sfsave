import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws simple SVG files, the kind icon resources are, with Core Graphics:
/// paths and basic shapes, solid and gradient fills, strokes, opacity,
/// transforms, nested groups and embedded PNG/JPEG images. Clip paths, masks,
/// filters and text are skipped. Used for previews and for finding where an
/// original's visible pixels are, never for export.
enum SVGPreview {
    struct Document {
        fileprivate let root: Node
        fileprivate let ids: [String: Node]
        /// The `width` and `height` in user units; the viewBox when they are missing.
        let size: CGSize
        fileprivate let viewBox: CGRect
    }

    static func parse(_ data: Data) -> Document? {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root, root.name == "svg" else { return nil }
        var ids: [String: Node] = [:]
        func index(_ node: Node) {
            if let id = node.attributes["id"] { ids[id] = node }
            node.children.forEach(index)
        }
        index(root)
        let box = root.attributes["viewBox"].map(numbers).flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        let width = root.attributes["width"].flatMap(length) ?? box?.width ?? 0
        let height = root.attributes["height"].flatMap(length) ?? box?.height ?? 0
        guard width > 0, height > 0 else { return nil }
        return Document(root: root, ids: ids, size: CGSize(width: width, height: height),
                        viewBox: box ?? CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// The drawing as a PNG with `scale` pixels per unit of `size`.
    static func png(_ document: Document, scale: CGFloat) -> Data? {
        let width = max(Int((document.size.width * scale).rounded()), 1)
        let height = max(Int((document.size.height * scale).rounded()), 1)
        guard width * height <= 16_000_000,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // SVG space (y down) into the bitmap; the viewBox is fitted and centered.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let box = document.viewBox
        let fit = min(CGFloat(width) / max(box.width, 0.001), CGFloat(height) / max(box.height, 0.001))
        context.translateBy(x: (CGFloat(width) - box.width * fit) / 2, y: (CGFloat(height) - box.height * fit) / 2)
        context.scaleBy(x: fit, y: fit)
        context.translateBy(x: -box.minX, y: -box.minY)
        var renderer = Renderer(context: context, ids: document.ids)
        renderer.draw(document.root, state: Renderer.State())
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: Parsing helpers

    fileprivate static func numbers(_ text: String) -> [CGFloat] {
        var scanner = NumberScanner(text)
        var result: [CGFloat] = []
        while let value = scanner.number() { result.append(value) }
        return result
    }

    /// `24`, `24px`, `24.0pt`: the number, units ignored. Percentages are not lengths here.
    fileprivate static func length(_ text: String) -> CGFloat? {
        guard !text.contains("%") else { return nil }
        var scanner = NumberScanner(text)
        return scanner.number()
    }
}

// MARK: - Tree

private final class Node {
    let name: String
    var attributes: [String: String]
    var children: [Node] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
        // Inline style declarations win over attributes.
        if let style = attributes["style"] {
            for declaration in style.split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, !parts[0].isEmpty { self.attributes[parts[0]] = parts[1] }
            }
        }
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: Node?
    private var stack: [Node] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let node = Node(name: name, attributes: attributeDict)
        if let parent = stack.last { parent.children.append(node) } else if root == nil { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
}

// MARK: - Numbers

private struct NumberScanner {
    private let bytes: [UInt8]
    private(set) var index = 0

    init(_ text: String) { bytes = Array(text.utf8) }

    mutating func skipSeparators() {
        while index < bytes.count, [32, 9, 10, 13, 44].contains(bytes[index]) { index += 1 }
    }

    /// The next byte after separators, without consuming it.
    mutating func peek() -> UInt8? {
        skipSeparators()
        return index < bytes.count ? bytes[index] : nil
    }

    mutating func advance() { index += 1 }

    /// An arc flag: a single 0 or 1, which may run into the next number.
    mutating func flag() -> Bool? {
        skipSeparators()
        guard index < bytes.count, bytes[index] == 48 || bytes[index] == 49 else { return nil }
        defer { index += 1 }
        return bytes[index] == 49
    }

    mutating func number() -> CGFloat? {
        skipSeparators()
        let start = index
        if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
        var digits = false, dot = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= 48 && byte <= 57 { digits = true; index += 1 }
            else if byte == 46 && !dot { dot = true; index += 1 }
            else { break }
        }
        guard digits else { index = start; return nil }
        if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
            var probe = index + 1
            if probe < bytes.count, bytes[probe] == 43 || bytes[probe] == 45 { probe += 1 }
            if probe < bytes.count, bytes[probe] >= 48 && bytes[probe] <= 57 {
                index = probe
                while index < bytes.count, bytes[index] >= 48 && bytes[index] <= 57 { index += 1 }
            }
        }
        return Double(String(decoding: bytes[start..<index], as: UTF8.self)).map { CGFloat($0) }
    }
}

// MARK: - Rendering

private struct Renderer {
    struct State {
        var fill: String = "black"
        var fillOpacity: CGFloat = 1
        var evenOdd = false
        var stroke: String = "none"
        var strokeOpacity: CGFloat = 1
        var strokeWidth: CGFloat = 1
        var lineCap = CGLineCap.butt
        var lineJoin = CGLineJoin.miter
    }

    let context: CGContext
    let ids: [String: Node]
    private static let skipped: Set<String> = ["defs", "clipPath", "mask", "symbol", "title", "desc", "metadata", "filter",
                                               "linearGradient", "radialGradient", "style", "foreignObject", "pattern",
                                               "marker", "text", "script"]

    init(context: CGContext, ids: [String: Node]) {
        self.context = context
        self.ids = ids
    }

    mutating func draw(_ node: Node, state inherited: State) {
        guard !Self.skipped.contains(node.name), node.attributes["display"] != "none" else { return }
        var state = inherited
        let a = node.attributes
        if let value = a["fill"] { state.fill = value }
        if let value = a["fill-opacity"].flatMap(Self.unit) { state.fillOpacity = value }
        if let value = a["fill-rule"] { state.evenOdd = value == "evenodd" }
        if let value = a["stroke"] { state.stroke = value }
        if let value = a["stroke-opacity"].flatMap(Self.unit) { state.strokeOpacity = value }
        if let value = a["stroke-width"].flatMap(SVGPreview.length) { state.strokeWidth = value }
        if let value = a["stroke-linecap"] { state.lineCap = value == "round" ? .round : value == "square" ? .square : .butt }
        if let value = a["stroke-linejoin"] { state.lineJoin = value == "round" ? .round : value == "bevel" ? .bevel : .miter }
        let opacity = a["opacity"].flatMap(Self.unit) ?? 1

        context.saveGState()
        defer { context.restoreGState() }
        if let transform = a["transform"] { Self.transforms(transform).forEach { context.concatenate($0) } }

        switch node.name {
        case "svg", "g", "a", "switch":
            if opacity < 0.999 {
                context.setAlpha(opacity)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            for child in node.children { draw(child, state: state) }
            if opacity < 0.999 { context.endTransparencyLayer() }
        case "image":
            drawImage(node, opacity: opacity)
        default:
            if let path = shape(node) { paint(path, state: state, opacity: opacity, closed: node.name != "line" && node.name != "polyline") }
        }
    }

    private func shape(_ node: Node) -> CGPath? {
        let a = node.attributes
        func value(_ key: String) -> CGFloat { a[key].flatMap(SVGPreview.length) ?? 0 }
        switch node.name {
        case "path":
            return a["d"].map(PathParser.path)
        case "rect":
            let rect = CGRect(x: value("x"), y: value("y"), width: value("width"), height: value("height"))
            guard rect.width > 0, rect.height > 0 else { return nil }
            var rx = a["rx"].flatMap(SVGPreview.length), ry = a["ry"].flatMap(SVGPreview.length)
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let cornerX = min(rx ?? 0, rect.width / 2), cornerY = min(ry ?? 0, rect.height / 2)
            return cornerX > 0 && cornerY > 0
                ? CGPath(roundedRect: rect, cornerWidth: cornerX, cornerHeight: cornerY, transform: nil)
                : CGPath(rect: rect, transform: nil)
        case "circle":
            let r = value("r")
            guard r > 0 else { return nil }
            return CGPath(ellipseIn: CGRect(x: value("cx") - r, y: value("cy") - r, width: 2 * r, height: 2 * r), transform: nil)
        case "ellipse":
            let rx = value("rx"), ry = value("ry")
            guard rx > 0, ry > 0 else { return nil }
            return CGPath(ellipseIn: CGRect(x: value("cx") - rx, y: value("cy") - ry, width: 2 * rx, height: 2 * ry), transform: nil)
        case "line":
            let path = CGMutablePath()
            path.move(to: CGPoint(x: value("x1"), y: value("y1")))
            path.addLine(to: CGPoint(x: value("x2"), y: value("y2")))
            return path
        case "polyline", "polygon":
            let list = a["points"].map(SVGPreview.numbers) ?? []
            guard list.count >= 4 else { return nil }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: list[0], y: list[1]))
            for i in stride(from: 2, to: list.count - 1, by: 2) { path.addLine(to: CGPoint(x: list[i], y: list[i + 1])) }
            if node.name == "polygon" { path.closeSubpath() }
            return path
        default:
            return nil
        }
    }

    private func paint(_ path: CGPath, state: State, opacity: CGFloat, closed: Bool) {
        if closed, let fill = paintValue(state.fill) {
            context.saveGState()
            switch fill {
            case .color(let color):
                context.setFillColor(color.copy(alpha: color.alpha * state.fillOpacity * opacity) ?? color)
                context.addPath(path)
                context.fillPath(using: state.evenOdd ? .evenOdd : .winding)
            case .gradient(let node):
                context.addPath(path)
                context.clip(using: state.evenOdd ? .evenOdd : .winding)
                context.setAlpha(state.fillOpacity * opacity)
                drawGradient(node, bounds: path.boundingBoxOfPath)
            }
            context.restoreGState()
        }
        if let stroke = paintValue(state.stroke), state.strokeWidth > 0 {
            context.saveGState()
            context.setLineWidth(state.strokeWidth)
            context.setLineCap(state.lineCap)
            context.setLineJoin(state.lineJoin)
            switch stroke {
            case .color(let color):
                context.setStrokeColor(color.copy(alpha: color.alpha * state.strokeOpacity * opacity) ?? color)
                context.addPath(path)
                context.strokePath()
            case .gradient(let node):
                context.addPath(path)
                context.replacePathWithStrokedPath()
                context.clip()
                context.setAlpha(state.strokeOpacity * opacity)
                drawGradient(node, bounds: path.boundingBoxOfPath.insetBy(dx: -state.strokeWidth / 2, dy: -state.strokeWidth / 2))
            }
            context.restoreGState()
        }
    }

    private enum Paint {
        case color(CGColor)
        case gradient(Node)
    }

    private func paintValue(_ text: String) -> Paint? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("url(") {
            let id = value.dropFirst(4).prefix { $0 != ")" }.trimmingCharacters(in: CharacterSet(charactersIn: "#'\" "))
            if let node = ids[id], node.name == "linearGradient" || node.name == "radialGradient" { return .gradient(node) }
            // A missing paint server falls back to its color, if one follows.
            let fallback = value.drop { $0 != ")" }.dropFirst().trimmingCharacters(in: .whitespaces)
            return fallback.isEmpty ? nil : paintValue(fallback)
        }
        return Self.color(value).map { Paint.color($0) }
    }

    private func drawGradient(_ node: Node, bounds: CGRect) {
        let stops = gradientStops(node)
        guard !stops.isEmpty, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: stops.map(\.color) as CFArray,
                                        locations: stops.map(\.offset)) else { return }
        let a = attributes(node)
        let objectBox = (a["gradientUnits"] ?? "objectBoundingBox") != "userSpaceOnUse"
        func coordinate(_ key: String, _ fallback: CGFloat) -> CGFloat {
            guard let text = a[key] else { return fallback }
            if text.hasSuffix("%"), let number = Double(text.dropLast()) { return CGFloat(number) / 100 }
            return SVGPreview.length(text) ?? fallback
        }
        if objectBox {
            context.concatenate(CGAffineTransform(a: bounds.width, b: 0, c: 0, d: bounds.height, tx: bounds.minX, ty: bounds.minY))
        }
        if let transform = a["gradientTransform"] { Self.transforms(transform).forEach { context.concatenate($0) } }
        let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        if node.name == "radialGradient" {
            let cx = coordinate("cx", 0.5), cy = coordinate("cy", 0.5), r = coordinate("r", 0.5)
            let fx = coordinate("fx", cx), fy = coordinate("fy", cy)
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: fx, y: fy), startRadius: 0,
                                       endCenter: CGPoint(x: cx, y: cy), endRadius: r, options: options)
        } else {
            context.drawLinearGradient(gradient, start: CGPoint(x: coordinate("x1", 0), y: coordinate("y1", 0)),
                                       end: CGPoint(x: coordinate("x2", 1), y: coordinate("y2", 0)), options: options)
        }
    }

    /// Attributes of a gradient, with the ones it inherits through `href`.
    private func attributes(_ node: Node) -> [String: String] {
        var result = node.attributes
        var current = node
        for _ in 0..<4 {
            guard let link = current.attributes["href"] ?? current.attributes["xlink:href"],
                  let next = ids[String(link.drop { $0 == "#" })] else { break }
            for (key, value) in next.attributes where result[key] == nil { result[key] = value }
            current = next
        }
        return result
    }

    private func gradientStops(_ node: Node) -> [(offset: CGFloat, color: CGColor)] {
        var current = node
        for _ in 0..<4 where current.children.filter({ $0.name == "stop" }).isEmpty {
            guard let link = current.attributes["href"] ?? current.attributes["xlink:href"],
                  let next = ids[String(link.drop { $0 == "#" })] else { break }
            current = next
        }
        var last: CGFloat = 0
        return current.children.filter { $0.name == "stop" }.compactMap { stop -> (offset: CGFloat, color: CGColor)? in
            let a = stop.attributes
            var offset = a["offset"].map { text -> CGFloat in
                if text.hasSuffix("%") { return CGFloat(Double(text.dropLast()) ?? 0) / 100 }
                return SVGPreview.length(text) ?? 0
            } ?? 0
            offset = max(last, min(max(offset, 0), 1))
            last = offset
            guard let color = Self.color(a["stop-color"] ?? "black") else { return nil }
            let alpha = a["stop-opacity"].flatMap(Self.unit) ?? 1
            return (offset: offset, color: color.copy(alpha: color.alpha * alpha) ?? color)
        }
    }

    private func drawImage(_ node: Node, opacity: CGFloat) {
        let a = node.attributes
        guard let link = a["href"] ?? a["xlink:href"], link.hasPrefix("data:"),
              let comma = link.firstIndex(of: ","),
              let data = Data(base64Encoded: String(link[link.index(after: comma)...]).filter { !$0.isWhitespace }),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        func value(_ key: String) -> CGFloat { a[key].flatMap(SVGPreview.length) ?? 0 }
        let rect = CGRect(x: value("x"), y: value("y"), width: a["width"] == nil ? CGFloat(image.width) : value("width"),
                          height: a["height"] == nil ? CGFloat(image.height) : value("height"))
        context.saveGState()
        // Images draw bottom-up in Core Graphics; flip locally in y-down space.
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.setAlpha(opacity)
        context.draw(image, in: rect)
        context.restoreGState()
    }

    static func unit(_ text: String) -> CGFloat? {
        if text.hasSuffix("%"), let number = Double(text.dropLast()) { return CGFloat(min(max(number / 100, 0), 1)) }
        return SVGPreview.length(text).map { min(max($0, 0), 1) }
    }

    static func color(_ text: String) -> CGColor? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "none", "transparent", "": return nil
        case "black", "currentcolor": return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case "white": return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case "red": return CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        case "green": return CGColor(srgbRed: 0, green: 0.5, blue: 0, alpha: 1)
        case "blue": return CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        case "gray", "grey": return CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        default: break
        }
        if value.hasPrefix("#") {
            var hex = String(value.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else { return nil }
            let rgb = hex.count == 8 ? number >> 8 : number
            let alpha = hex.count == 8 ? CGFloat(number & 255) / 255 : 1
            return CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: alpha)
        }
        if value.hasPrefix("rgb") {
            let inner = value.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            func channel(_ text: String) -> CGFloat {
                if text.hasSuffix("%") { return CGFloat(Double(text.dropLast()) ?? 0) / 100 }
                return CGFloat(Double(text) ?? 0) / 255
            }
            let alpha = parts.count > 3 ? CGFloat(Double(parts[3]) ?? 1) : 1
            return CGColor(srgbRed: channel(parts[0]), green: channel(parts[1]), blue: channel(parts[2]), alpha: alpha)
        }
        return nil
    }

    /// `translate(…) rotate(…)` as transforms to concatenate in order.
    static func transforms(_ text: String) -> [CGAffineTransform] {
        var result: [CGAffineTransform] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n"))
            let v = SVGPreview.numbers(String(rest[rest.index(after: open)..<close]))
            switch name {
            case "matrix" where v.count == 6:
                result.append(CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]))
            case "translate" where !v.isEmpty:
                result.append(CGAffineTransform(translationX: v[0], y: v.count > 1 ? v[1] : 0))
            case "scale" where !v.isEmpty:
                result.append(CGAffineTransform(scaleX: v[0], y: v.count > 1 ? v[1] : v[0]))
            case "rotate" where !v.isEmpty:
                let angle = v[0] * .pi / 180
                if v.count >= 3 {
                    result.append(CGAffineTransform(translationX: v[1], y: v[2]))
                    result.append(CGAffineTransform(rotationAngle: angle))
                    result.append(CGAffineTransform(translationX: -v[1], y: -v[2]))
                } else {
                    result.append(CGAffineTransform(rotationAngle: angle))
                }
            case "skewX" where !v.isEmpty:
                result.append(CGAffineTransform(a: 1, b: 0, c: tan(v[0] * .pi / 180), d: 1, tx: 0, ty: 0))
            case "skewY" where !v.isEmpty:
                result.append(CGAffineTransform(a: 1, b: tan(v[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0))
            default:
                break
            }
            rest = rest[rest.index(after: close)...]
        }
        return result
    }
}

// MARK: - Path data

private enum PathParser {
    static func path(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = NumberScanner(data)
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: UInt8 = 0
        var command: UInt8 = 0

        while let next = scanner.peek() {
            if (next >= 65 && next <= 90) || (next >= 97 && next <= 122) {
                command = next
                scanner.advance()
                if command == 90 || command == 122 {
                    path.closeSubpath()
                    current = start
                    lastControl = nil
                    lastCommand = command
                    continue
                }
            } else if command == 0 {
                break
            }
            let relative = command >= 97
            let base = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            let before = scanner.index
            switch command | 32 {
            case 109: // m
                guard let p = point() else { return path }
                path.move(to: p)
                current = p
                start = p
                lastControl = nil
                command = relative ? 108 : 76 // further pairs are lines
            case 108: // l
                guard let p = point() else { return path }
                path.addLine(to: p)
                current = p
                lastControl = nil
            case 104: // h
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case 118: // v
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
            case 99: // c
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastControl = c2
            case 115: // s
                let reflectable = [99, 67, 115, 83].contains(Int(lastCommand))
                let c1 = reflectable && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                guard let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastControl = c2
            case 113: // q
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                current = p
                lastControl = c
            case 116: // t
                let reflectable = [113, 81, 116, 84].contains(Int(lastCommand))
                let c = reflectable && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                guard let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                current = p
                lastControl = c
            case 97: // a
                guard let rx = scanner.number(), let ry = scanner.number(), let angle = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = point() else { return path }
                addArc(path, from: current, to: p, rx: abs(rx), ry: abs(ry), angle: angle * .pi / 180, large: large, sweep: sweep)
                current = p
                lastControl = nil
            default:
                return path
            }
            lastCommand = command
            if scanner.index == before { break }
        }
        return path
    }

    /// SVG endpoint arc as cubic Béziers (SVG 1.1 appendix F.6).
    private static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                               angle: CGFloat, large: Bool, sweep: Bool) {
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let cosA = cos(angle), sinA = sin(angle)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosA * dx + sinA * dy, y1 = -sinA * dx + cosA * dy
        var rx = rx, ry = ry
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = sqrt(max(0, numerator / max(denominator, 1e-12)))
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx
        let cx = cosA * cx1 - sinA * cy1 + (p0.x + p1.x) / 2
        let cy = sinA * cx1 + cosA * cy1 + (p0.y + p1.y) / 2
        func angleOf(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let sign: CGFloat = ux * vy - uy * vx < 0 ? -1 : 1
            let dot = (ux * vx + uy * vy) / (sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy))
            return sign * acos(min(max(dot, -1), 1))
        }
        let theta = angleOf(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angleOf((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        func point(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosA - ry * sin(t) * sinA, y: cy + rx * cos(t) * sinA + ry * sin(t) * cosA)
        }
        func derivative(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosA - ry * cos(t) * sinA, y: -rx * sin(t) * sinA + ry * cos(t) * cosA)
        }
        var t = theta
        for _ in 0..<segments {
            let start = point(t), end = point(t + step)
            let d0 = derivative(t), d1 = derivative(t + step)
            path.addCurve(to: end, control1: CGPoint(x: start.x + k * d0.x, y: start.y + k * d0.y),
                          control2: CGPoint(x: end.x - k * d1.x, y: end.y - k * d1.y))
            t += step
        }
    }
}
