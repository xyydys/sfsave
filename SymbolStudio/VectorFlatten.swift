import CoreGraphics
import Foundation

extension VectorDrawing {
    /// The same picture with clips and masks worked into the path geometry:
    /// a clip becomes an intersection, the black-on-white "clear behind"
    /// masks the system uses for gaps between layers become a subtraction.
    /// The SVG then holds plain filled paths, which every SVG renderer draws
    /// the same way. An alpha mask made of solid shapes at several opacities
    /// (how the system draws hierarchical layers over a gradient) turns the
    /// masked shape into one copy per mask shape at that opacity. Masks with
    /// gradients or partial knockouts cannot be expressed as geometry and are kept.
    func flattened() -> VectorDrawing {
        var flattener = Flattener(drawing: self)
        var result = self
        result.nodes = flattener.flatten(nodes, ops: [])
        if flattener.keptMasks > 0 {
            result.warnings.append("有 \(flattener.keptMasks) 处半透明遮罩不能合并成路径，保留为 SVG 遮罩。")
        }
        return result
    }
}

private enum GeometryOp {
    case intersect(CGPath)
    case subtract(CGPath)
}

private enum MaskGeometry {
    /// Fully shown or fully hidden areas.
    case ops([GeometryOp])
    /// Areas shown at an opacity, drawn in order. Painting the masked shape
    /// once per area at that opacity composites to the same result, as long
    /// as the masked content is a single shape.
    case layers([(path: CGPath, alpha: Double)])
}

private struct Flattener {
    let drawing: VectorDrawing
    var keptMasks = 0
    private var clipCache: [String: CGPath] = [:]
    private var maskCache: [String: MaskGeometry?] = [:]

    init(drawing: VectorDrawing) { self.drawing = drawing }

    mutating func flatten(_ nodes: [VectorNode], ops: [GeometryOp]) -> [VectorNode] {
        var result: [VectorNode] = []
        for node in nodes {
            switch node {
            case .shape(let shape):
                result += flatten(shape, ops: ops).map { .shape($0) }
            case .group(var group):
                var inner = ops + clipOps(group.clipID)
                group.clipID = nil
                var layers: [(path: CGPath, alpha: Double)]?
                if let maskID = group.maskID {
                    switch maskGeometry(maskID) {
                    case .ops(let maskOps)?:
                        inner += maskOps
                        group.maskID = nil
                    case .layers(let found)?:
                        layers = found
                    case nil:
                        keptMasks += 1
                    }
                }
                group.children = flatten(group.children, ops: inner)
                if let layers {
                    if group.children.count == 1, case .shape(var only) = group.children[0] {
                        only.fillOpacity *= group.opacity
                        result += Self.layered(only, layers).map { .shape($0) }
                        continue
                    }
                    keptMasks += 1
                }
                result += simplify(group)
            }
        }
        return result
    }

    /// A group left with only opacity: one child, or children with the same
    /// paint, take the opacity themselves; otherwise the group stays.
    private func simplify(_ group: VectorGroup) -> [VectorNode] {
        if group.children.isEmpty { return [] }
        if group.maskID != nil { return [.group(group)] }
        if group.opacity >= 0.999 { return group.children }
        let shapes = group.children.compactMap { node -> VectorShape? in
            if case .shape(let shape) = node, shape.stroke == nil, shape.maskID == nil, shape.clipID == nil { return shape }
            return nil
        }
        guard shapes.count == group.children.count, let first = shapes.first,
              shapes.allSatisfy({ samePaint($0, first) }) else { return [.group(group)] }
        var merged = first
        if shapes.count > 1 {
            merged.path = shapes.dropFirst().reduce(Self.normalized(first)) { $0.union(Self.normalized($1), using: .evenOdd) }
            merged.evenOdd = true
        }
        merged.fillOpacity *= group.opacity
        return [.shape(merged)]
    }

    private func samePaint(_ a: VectorShape, _ b: VectorShape) -> Bool {
        guard abs(a.fillOpacity - b.fillOpacity) < 0.001 else { return false }
        switch (a.fill, b.fill) {
        case (.color(let x)?, .color(let y)?): return x == y
        case (.gradient(let x)?, .gradient(let y)?): return x == y
        default: return false
        }
    }

    private mutating func flatten(_ shape: VectorShape, ops: [GeometryOp]) -> [VectorShape] {
        var shape = shape
        var all = ops + clipOps(shape.clipID)
        shape.clipID = nil
        var layers: [(path: CGPath, alpha: Double)]?
        if let maskID = shape.maskID {
            switch maskGeometry(maskID) {
            case .ops(let maskOps)?:
                all += maskOps
                shape.maskID = nil
            case .layers(let found)?:
                layers = found
                shape.maskID = nil
            case nil:
                keptMasks += 1
            }
        }
        if all.isEmpty && layers == nil { return [shape] }

        var parts: [VectorShape] = []
        if shape.fill != nil {
            var fill = shape
            fill.stroke = nil
            parts.append(fill)
        }
        if let stroke = shape.stroke, shape.strokeWidth > 0 {
            // Clipping a stroke means clipping its outline.
            var outline = shape
            outline.path = shape.path.copy(strokingWithWidth: shape.strokeWidth,
                                           lineCap: CGLineCap(rawValue: Int32(shape.lineCap)) ?? .butt,
                                           lineJoin: CGLineJoin(rawValue: Int32(shape.lineJoin)) ?? .miter,
                                           miterLimit: 10)
            outline.evenOdd = false
            outline.fill = .color(stroke)
            outline.fillOpacity = shape.strokeOpacity
            outline.stroke = nil
            parts.append(outline)
        }
        let clipped: [VectorShape] = parts.compactMap { part in
            var part = part
            guard let path = Self.apply(all, to: Self.normalized(part)) else { return nil }
            part.path = path
            part.evenOdd = true
            return part
        }
        guard let layers else { return clipped }
        return clipped.flatMap { Self.layered($0, layers) }
    }

    /// One copy of `shape` per mask area, at that area's opacity.
    private static func layered(_ shape: VectorShape, _ layers: [(path: CGPath, alpha: Double)]) -> [VectorShape] {
        layers.compactMap { layer in
            guard layer.alpha > 0.002, let path = apply([.intersect(layer.path)], to: normalized(shape)) else { return nil }
            var piece = shape
            piece.path = path
            piece.evenOdd = true
            piece.fillOpacity *= layer.alpha
            return piece
        }
    }

    /// `nil` when nothing is left.
    private static func apply(_ ops: [GeometryOp], to start: CGPath) -> CGPath? {
        var path = start
        for op in ops {
            let box = path.boundingBoxOfPath
            switch op {
            case .intersect(let clip):
                if isRectangle(clip) && clip.boundingBoxOfPath.insetBy(dx: -0.001, dy: -0.001).contains(box) { continue }
                path = path.intersection(clip, using: .evenOdd)
            case .subtract(let cut):
                guard cut.boundingBoxOfPath.intersects(box) else { continue }
                path = path.subtracting(cut, using: .evenOdd)
            }
            if path.isEmpty || path.boundingBoxOfPath.isNull || path.boundingBoxOfPath.isEmpty { return nil }
        }
        return path
    }

    private static func normalized(_ shape: VectorShape) -> CGPath {
        shape.path.normalized(using: shape.evenOdd ? .evenOdd : .winding)
    }

    /// An axis-aligned rectangle: only straight lines, every point on the bounding box.
    private static func isRectangle(_ path: CGPath) -> Bool {
        let box = path.boundingBoxOfPath
        var points = 0
        var straight = true
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                let p = element.points[0]
                points += 1
                let onEdge = abs(p.x - box.minX) < 0.001 || abs(p.x - box.maxX) < 0.001
                    || abs(p.y - box.minY) < 0.001 || abs(p.y - box.maxY) < 0.001
                if !onEdge { straight = false }
            case .closeSubpath: break
            default: straight = false
            }
        }
        return straight && points <= 5
    }

    private mutating func clipOps(_ id: String?) -> [GeometryOp] {
        var ops: [GeometryOp] = []
        var current = id
        while let clipID = current, let clip = drawing.clips[clipID] {
            if clipCache[clipID] == nil {
                clipCache[clipID] = clip.path.normalized(using: clip.evenOdd ? .evenOdd : .winding)
            }
            if let path = clipCache[clipID] { ops.append(.intersect(path)) }
            current = clip.parent
        }
        return ops
    }

    /// The mask as geometry, or `nil` when it cannot be expressed that way.
    private mutating func maskGeometry(_ id: String) -> MaskGeometry? {
        if let cached = maskCache[id] { return cached }
        let geometry = computeMaskGeometry(id)
        maskCache[id] = .some(geometry)
        return geometry
    }

    private mutating func computeMaskGeometry(_ id: String) -> MaskGeometry? {
        guard let mask = drawing.masks[id] else { return .ops([]) }
        var shapes: [VectorShape] = []
        guard collectPlain(mask.children, ops: [], into: &shapes) else { return nil }
        let union = shapes.reduce(CGMutablePath() as CGPath) { acc, shape in
            acc.isEmpty ? shape.path : acc.union(shape.path, using: .evenOdd)
        }
        let opaque = shapes.allSatisfy { (Self.alpha(of: $0) ?? 0) > 0.98 }
        let backdrop = mask.backdrop.map(Self.luminance) ?? 0
        // An alpha mask, or a luminosity mask of white shapes on black, shows
        // the content as much as the shapes cover it.
        if mask.alpha || (backdrop < 0.02 && shapes.allSatisfy({ (Self.lightness(of: $0) ?? 0) > 0.98 })) {
            if opaque { return .ops([.intersect(union)]) }
            return .layers(shapes.compactMap { shape in Self.alpha(of: shape).map { (path: shape.path, alpha: $0) } })
        }
        // Black shapes on white cut the content away.
        if backdrop > 0.98, opaque, shapes.allSatisfy({ (Self.lightness(of: $0) ?? 1) < 0.02 }) {
            return .ops(shapes.isEmpty ? [] : [.subtract(union)])
        }
        return nil
    }

    /// Mask content as plain filled shapes with their clips applied. Fails on
    /// anything that is not a solid fill at full group opacity.
    private mutating func collectPlain(_ nodes: [VectorNode], ops: [GeometryOp], into shapes: inout [VectorShape]) -> Bool {
        for node in nodes {
            switch node {
            case .shape(let shape):
                guard shape.maskID == nil, shape.stroke == nil, case .color? = shape.fill else { return false }
                var part = shape
                guard let path = Self.apply(ops + clipOps(shape.clipID), to: Self.normalized(shape)) else { continue }
                part.path = path
                part.clipID = nil
                shapes.append(part)
            case .group(let group):
                guard group.maskID == nil, group.opacity >= 0.999 else { return false }
                if !collectPlain(group.children, ops: ops + clipOps(group.clipID), into: &shapes) { return false }
            }
        }
        return true
    }

    private static func alpha(of shape: VectorShape) -> Double? {
        guard case .color(let color)? = shape.fill else { return nil }
        return color.alpha * shape.fillOpacity
    }

    private static func lightness(of shape: VectorShape) -> Double? {
        guard case .color(let color)? = shape.fill else { return nil }
        return luminance(color)
    }

    private static func luminance(_ color: RGBA) -> Double {
        0.3 * color.red + 0.59 * color.green + 0.11 * color.blue
    }
}
