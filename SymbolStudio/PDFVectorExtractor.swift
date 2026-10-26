import CoreGraphics
import Foundation

/// Walks a PDF page with CGPDFScanner and records its vector painting as a
/// `VectorDrawing`. The PDF comes from the system drawing an SF Symbol, so the
/// output keeps the exact layers, colors and opacities the system used.
///
/// Supported: paths, fills and strokes, q/Q, cm, gray/RGB/CMYK/ICC colors,
/// ExtGState alpha and soft masks, clipping, form XObjects (including
/// transparency groups), axial and radial shadings and shading patterns.
/// Images, text and tiling patterns are reported in `warnings`.
final class PDFVectorExtractor {
    static func extract(pdf data: Data) -> VectorDrawing? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let extractor = PDFVectorExtractor()
        extractor.run(page)
        return extractor.drawing
    }

    fileprivate enum ColorSpace {
        case gray, rgb, cmyk, pattern
        case icc(CGColorSpace, Int)
        case unsupported(Int)

        var componentCount: Int {
            switch self {
            case .gray: return 1
            case .rgb: return 3
            case .cmyk: return 4
            case .pattern: return 0
            case .icc(_, let count), .unsupported(let count): return count
            }
        }

        var initialComponents: [CGFloat] {
            switch self {
            case .cmyk: return [0, 0, 0, 1]
            case .icc(_, 4): return [0, 0, 0, 1]
            default: return Array(repeating: 0, count: componentCount)
            }
        }
    }

    private struct LastClip {
        let id: String
        let path: CGPath
        let evenOdd: Bool
        let parent: String?
    }

    private struct GState {
        var ctm = CGAffineTransform.identity
        var fillSpace = ColorSpace.gray
        var strokeSpace = ColorSpace.gray
        var fillColor = RGBA.black
        var strokeColor = RGBA.black
        var fillPattern: String?
        var fillAlpha: Double = 1
        var strokeAlpha: Double = 1
        var lineWidth: CGFloat = 1
        var lineCap = 0
        var lineJoin = 0
        var clipID: String?
        var lastClip: LastClip?
        var maskID: String?
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    private var drawing = VectorDrawing()
    private var state = GState()
    private var saved: [GState] = []
    private var path = CGMutablePath()
    fileprivate var pendingClip: Bool?
    private var outputs: [[VectorNode]] = [[]]
    private var baseCTMs: [CGAffineTransform] = [.identity]
    private var flip = CGAffineTransform.identity
    private var pageRect = CGRect.zero
    private var table: CGPDFOperatorTableRef?
    private var maskDepth = 0
    private var formDepth = 0
    private var nextIndex = 0
    private var iccCache: [Int: ColorSpace] = [:]

    // MARK: Driver

    private func run(_ page: CGPDFPage) {
        let box = page.getBoxRect(.mediaBox)
        flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -box.minX, ty: box.maxY)
        pageRect = CGRect(origin: .zero, size: box.size)
        drawing.pageSize = box.size
        guard let table = CGPDFOperatorTableCreate() else { return }
        self.table = table
        register(table)
        let content = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        CGPDFOperatorTableRelease(table)
        self.table = nil

        drawing.nodes = prune(outputs.first ?? [])
        for (id, mask) in drawing.masks {
            drawing.masks[id] = VectorMask(index: mask.index, alpha: mask.alpha, backdrop: mask.backdrop,
                                           children: prune(mask.children))
        }
    }

    private func register(_ table: CGPDFOperatorTableRef) {
        func on(_ name: String, _ callback: CGPDFOperatorCallback) {
            CGPDFOperatorTableSetCallback(table, name, callback)
        }
        on("q") { _, info in extractor(info).push() }
        on("Q") { _, info in extractor(info).pop() }
        on("cm") { scanner, info in extractor(info).concat(scanner) }

        on("m") { scanner, info in extractor(info).moveTo(scanner) }
        on("l") { scanner, info in extractor(info).lineTo(scanner) }
        on("c") { scanner, info in extractor(info).curveTo(scanner) }
        on("v") { scanner, info in extractor(info).curveV(scanner) }
        on("y") { scanner, info in extractor(info).curveY(scanner) }
        on("h") { _, info in extractor(info).closePath() }
        on("re") { scanner, info in extractor(info).rectangle(scanner) }

        on("f") { scanner, info in extractor(info).paint(scanner, fill: true, evenOdd: false, stroke: false, close: false) }
        on("F") { scanner, info in extractor(info).paint(scanner, fill: true, evenOdd: false, stroke: false, close: false) }
        on("f*") { scanner, info in extractor(info).paint(scanner, fill: true, evenOdd: true, stroke: false, close: false) }
        on("B") { scanner, info in extractor(info).paint(scanner, fill: true, evenOdd: false, stroke: true, close: false) }
        on("B*") { scanner, info in extractor(info).paint(scanner, fill: true, evenOdd: true, stroke: true, close: false) }
        on("b") { scanner, info in extractor(info).paint(scanner, fill: true, evenOdd: false, stroke: true, close: true) }
        on("b*") { scanner, info in extractor(info).paint(scanner, fill: true, evenOdd: true, stroke: true, close: true) }
        on("S") { scanner, info in extractor(info).paint(scanner, fill: false, evenOdd: false, stroke: true, close: false) }
        on("s") { scanner, info in extractor(info).paint(scanner, fill: false, evenOdd: false, stroke: true, close: true) }
        on("n") { _, info in extractor(info).endPath() }
        on("W") { _, info in extractor(info).pendingClip = false }
        on("W*") { _, info in extractor(info).pendingClip = true }

        on("g") { scanner, info in extractor(info).setDeviceColor(scanner, .gray, stroke: false) }
        on("G") { scanner, info in extractor(info).setDeviceColor(scanner, .gray, stroke: true) }
        on("rg") { scanner, info in extractor(info).setDeviceColor(scanner, .rgb, stroke: false) }
        on("RG") { scanner, info in extractor(info).setDeviceColor(scanner, .rgb, stroke: true) }
        on("k") { scanner, info in extractor(info).setDeviceColor(scanner, .cmyk, stroke: false) }
        on("K") { scanner, info in extractor(info).setDeviceColor(scanner, .cmyk, stroke: true) }
        on("cs") { scanner, info in extractor(info).setColorSpace(scanner, stroke: false) }
        on("CS") { scanner, info in extractor(info).setColorSpace(scanner, stroke: true) }
        on("sc") { scanner, info in extractor(info).setColor(scanner, stroke: false) }
        on("scn") { scanner, info in extractor(info).setColor(scanner, stroke: false) }
        on("SC") { scanner, info in extractor(info).setColor(scanner, stroke: true) }
        on("SCN") { scanner, info in extractor(info).setColor(scanner, stroke: true) }

        on("gs") { scanner, info in extractor(info).extendedState(scanner) }
        on("w") { scanner, info in extractor(info).lineWidth(scanner) }
        on("J") { scanner, info in extractor(info).lineCap(scanner) }
        on("j") { scanner, info in extractor(info).lineJoin(scanner) }

        on("sh") { scanner, info in extractor(info).shade(scanner) }
        on("Do") { scanner, info in extractor(info).xObject(scanner) }
        on("BT") { _, info in extractor(info).text() }
        on("BI") { _, info in extractor(info).rasterImage() }
    }

    // MARK: Graphics state

    fileprivate func push() { saved.append(state) }

    fileprivate func pop() {
        if let previous = saved.popLast() { state = previous }
    }

    fileprivate func concat(_ scanner: CGPDFScannerRef) {
        guard let v = popNumbers(scanner, 6) else { return }
        state.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(state.ctm)
    }

    fileprivate func lineWidth(_ scanner: CGPDFScannerRef) {
        if let v = popNumbers(scanner, 1) { state.lineWidth = v[0] }
    }

    fileprivate func lineCap(_ scanner: CGPDFScannerRef) {
        if let v = popNumbers(scanner, 1) { state.lineCap = Int(v[0]) }
    }

    fileprivate func lineJoin(_ scanner: CGPDFScannerRef) {
        if let v = popNumbers(scanner, 1) { state.lineJoin = Int(v[0]) }
    }

    fileprivate func extendedState(_ scanner: CGPDFScannerRef) {
        guard let name = popName(scanner),
              let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "ExtGState", name)
        else { return }
        var dictRef: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dictRef), let dict = dictRef else { return }
        var value: CGPDFReal = 0
        if CGPDFDictionaryGetNumber(dict, "ca", &value) { state.fillAlpha = Double(value) }
        if CGPDFDictionaryGetNumber(dict, "CA", &value) { state.strokeAlpha = Double(value) }
        if CGPDFDictionaryGetNumber(dict, "LW", &value) { state.lineWidth = value }
        var maskObject: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dict, "SMask", &maskObject), let maskObject {
            var maskDict: CGPDFDictionaryRef?
            if CGPDFObjectGetValue(maskObject, .dictionary, &maskDict), let maskDict {
                state.maskID = softMask(maskDict, scanner: scanner)
            } else {
                state.maskID = nil
            }
        }
        var blendObject: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dict, "BM", &blendObject), let blendObject,
           let mode = objectName(blendObject), mode != "Normal", mode != "Compatible" {
            warn("混合模式 \(mode) 无法写入 SVG，按普通模式处理")
        }
    }

    // MARK: Path construction

    private func pagePoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: y).applying(state.ctm).applying(flip)
    }

    fileprivate func moveTo(_ scanner: CGPDFScannerRef) {
        guard let v = popNumbers(scanner, 2) else { return }
        path.move(to: pagePoint(v[0], v[1]))
    }

    fileprivate func lineTo(_ scanner: CGPDFScannerRef) {
        guard let v = popNumbers(scanner, 2) else { return }
        let point = pagePoint(v[0], v[1])
        if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
    }

    fileprivate func curveTo(_ scanner: CGPDFScannerRef) {
        guard let v = popNumbers(scanner, 6) else { return }
        addCurve(pagePoint(v[0], v[1]), pagePoint(v[2], v[3]), pagePoint(v[4], v[5]))
    }

    fileprivate func curveV(_ scanner: CGPDFScannerRef) {
        guard let v = popNumbers(scanner, 4) else { return }
        addCurve(path.isEmpty ? pagePoint(v[0], v[1]) : path.currentPoint, pagePoint(v[0], v[1]), pagePoint(v[2], v[3]))
    }

    fileprivate func curveY(_ scanner: CGPDFScannerRef) {
        guard let v = popNumbers(scanner, 4) else { return }
        let end = pagePoint(v[2], v[3])
        addCurve(pagePoint(v[0], v[1]), end, end)
    }

    private func addCurve(_ control1: CGPoint, _ control2: CGPoint, _ end: CGPoint) {
        if path.isEmpty { path.move(to: control1) }
        path.addCurve(to: end, control1: control1, control2: control2)
    }

    fileprivate func closePath() {
        if !path.isEmpty { path.closeSubpath() }
    }

    fileprivate func rectangle(_ scanner: CGPDFScannerRef) {
        guard let v = popNumbers(scanner, 4) else { return }
        let (x, y, w, h) = (v[0], v[1], v[2], v[3])
        path.move(to: pagePoint(x, y))
        path.addLine(to: pagePoint(x + w, y))
        path.addLine(to: pagePoint(x + w, y + h))
        path.addLine(to: pagePoint(x, y + h))
        path.closeSubpath()
    }

    // MARK: Painting

    fileprivate func paint(_ scanner: CGPDFScannerRef, fill: Bool, evenOdd: Bool, stroke: Bool, close: Bool) {
        if close { closePath() }
        if !path.isEmpty, let geometry = path.copy() {
            if fill { emitFill(geometry, evenOdd: evenOdd, scanner: scanner) }
            if stroke { emitStroke(geometry) }
        }
        endPath()
    }

    fileprivate func endPath() {
        if let evenOdd = pendingClip, let geometry = path.copy() {
            addClip(geometry, evenOdd: evenOdd)
        }
        pendingClip = nil
        path = CGMutablePath()
    }

    private func emitFill(_ geometry: CGPath, evenOdd: Bool, scanner: CGPDFScannerRef) {
        var shape = VectorShape(path: geometry)
        shape.evenOdd = evenOdd
        if let pattern = state.fillPattern {
            if let id = gradient(forPattern: pattern, scanner: scanner) {
                shape.fill = .gradient(id)
            } else {
                warn("图案填充无法转换，已用灰色代替")
                shape.fill = .color(RGBA(red: 0.5, green: 0.5, blue: 0.5))
            }
        } else {
            shape.fill = .color(state.fillColor)
        }
        shape.fillOpacity = state.fillAlpha
        append(shape)
    }

    private func emitStroke(_ geometry: CGPath) {
        var shape = VectorShape(path: geometry)
        shape.fillOpacity = 0
        shape.stroke = state.strokeColor
        shape.strokeOpacity = state.strokeAlpha
        let m = state.ctm
        shape.strokeWidth = max(state.lineWidth, 0.01) * sqrt(abs(m.a * m.d - m.b * m.c))
        shape.lineCap = state.lineCap
        shape.lineJoin = state.lineJoin
        append(shape)
    }

    private func append(_ shape: VectorShape) {
        let visibleFill = shape.fill != nil && shape.fillOpacity > 0.001
        let visibleStroke = shape.stroke != nil && shape.strokeOpacity > 0.001
        guard visibleFill || visibleStroke else { return }
        var shape = shape
        shape.clipID = state.clipID
        shape.maskID = state.maskID
        outputs[outputs.count - 1].append(.shape(shape))
        if maskDepth == 0 {
            drawing.bounds = drawing.bounds.union(clippedBounds(shape.bounds, clipID: shape.clipID))
        }
    }

    private func clippedBounds(_ rect: CGRect, clipID: String?) -> CGRect {
        var result = rect
        var current = clipID
        while let id = current, let clip = drawing.clips[id] {
            result = result.intersection(clip.path.boundingBoxOfPath)
            current = clip.parent
        }
        return result
    }

    private func addClip(_ geometry: CGPath, evenOdd: Bool) {
        var rect = CGRect.zero
        if geometry.isRect(&rect), rect.insetBy(dx: -0.01, dy: -0.01).contains(pageRect) { return }
        let id = makeID("clip")
        drawing.clips[id] = VectorClip(index: nextIndex, path: geometry, evenOdd: evenOdd, parent: state.clipID)
        state.lastClip = LastClip(id: id, path: geometry, evenOdd: evenOdd, parent: state.clipID)
        state.clipID = id
    }

    // MARK: Color

    fileprivate func setDeviceColor(_ scanner: CGPDFScannerRef, _ space: ColorSpace, stroke: Bool) {
        guard let v = popNumbers(scanner, space.componentCount) else { return }
        apply(space: space, components: v, stroke: stroke)
    }

    fileprivate func setColorSpace(_ scanner: CGPDFScannerRef, stroke: Bool) {
        guard let name = popName(scanner) else { return }
        let space = colorSpace(named: name, scanner: scanner)
        apply(space: space, components: space.initialComponents, stroke: stroke)
    }

    fileprivate func setColor(_ scanner: CGPDFScannerRef, stroke: Bool) {
        let space = stroke ? state.strokeSpace : state.fillSpace
        if case .pattern = space {
            guard let name = popName(scanner) else { return }
            if stroke { warn("描边图案无法转换") } else { state.fillPattern = name }
            return
        }
        guard let v = popNumbers(scanner, space.componentCount) else { return }
        apply(space: space, components: v, stroke: stroke)
    }

    private func apply(space: ColorSpace, components: [CGFloat], stroke: Bool) {
        let color = convert(components, space)
        if stroke {
            state.strokeSpace = space
            state.strokeColor = color
        } else {
            state.fillSpace = space
            state.fillColor = color
            state.fillPattern = nil
        }
    }

    private func colorSpace(named name: String, scanner: CGPDFScannerRef) -> ColorSpace {
        switch name {
        case "DeviceGray", "G", "CalGray": return .gray
        case "DeviceRGB", "RGB", "CalRGB": return .rgb
        case "DeviceCMYK", "CMYK": return .cmyk
        case "Pattern": return .pattern
        default:
            guard let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "ColorSpace", name)
            else { return .rgb }
            return colorSpace(object: object, scanner: scanner)
        }
    }

    private func colorSpace(object: CGPDFObjectRef, scanner: CGPDFScannerRef) -> ColorSpace {
        if let name = objectName(object), CGPDFObjectGetType(object) == .name {
            return colorSpace(named: name, scanner: scanner)
        }
        var arrayRef: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &arrayRef), let array = arrayRef, let family = arrayName(array, 0) else {
            return .rgb
        }
        switch family {
        case "ICCBased":
            var streamRef: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, 1, &streamRef), let stream = streamRef else { return .rgb }
            let key = unsafeBitCast(stream, to: Int.self)
            if let cached = iccCache[key] { return cached }
            var count: CGPDFInteger = 3
            if let dict = CGPDFStreamGetDictionary(stream) { _ = CGPDFDictionaryGetInteger(dict, "N", &count) }
            var result: ColorSpace = count == 1 ? .gray : (count == 4 ? .cmyk : .rgb)
            var format = CGPDFDataFormat.raw
            if let data = CGPDFStreamCopyData(stream, &format), format == .raw,
               let space = CGColorSpace(iccData: data) {
                result = .icc(space, count)
            }
            iccCache[key] = result
            return result
        case "CalRGB": return .rgb
        case "CalGray": return .gray
        case "Pattern": return .pattern
        case "Lab":
            warn("Lab 颜色空间未完整支持")
            return .unsupported(3)
        default:
            warn("颜色空间 \(family) 未完整支持")
            return .unsupported(1)
        }
    }

    private func convert(_ components: [CGFloat], _ space: ColorSpace) -> RGBA {
        func c(_ i: Int) -> Double { i < components.count ? Double(components[i]) : 0 }
        switch space {
        case .gray, .pattern, .unsupported:
            return RGBA(red: c(0), green: c(0), blue: c(0))
        case .rgb:
            return RGBA(red: c(0), green: c(1), blue: c(2))
        case .cmyk:
            let k = 1 - c(3)
            return RGBA(red: (1 - c(0)) * k, green: (1 - c(1)) * k, blue: (1 - c(2)) * k)
        case .icc(let space, let count):
            var values = Array(components.prefix(count))
            while values.count < count { values.append(0) }
            values.append(1)
            if let sRGB = Self.sRGB,
               let color = CGColor(colorSpace: space, components: values),
               let converted = color.converted(to: sRGB, intent: .defaultIntent, options: nil),
               let rgb = converted.components, rgb.count >= 3 {
                return RGBA(red: Double(rgb[0]), green: Double(rgb[1]), blue: Double(rgb[2]))
            }
            switch count {
            case 1: return convert(components, .gray)
            case 4: return convert(components, .cmyk)
            default: return convert(components, .rgb)
            }
        }
    }

    // MARK: Gradients

    fileprivate func shade(_ scanner: CGPDFScannerRef) {
        guard let name = popName(scanner),
              let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "Shading", name)
        else { return }
        guard let id = addGradient(object, transform: state.ctm.concatenating(flip), scanner: scanner) else { return }
        // `sh` paints the whole clip region. When the newest clip is a path,
        // fill that path with the gradient instead of a clipped rectangle.
        let savedClip = state.clipID
        var shape: VectorShape
        if let last = state.lastClip, last.id == state.clipID {
            shape = VectorShape(path: last.path)
            shape.evenOdd = last.evenOdd
            state.clipID = last.parent
        } else {
            shape = VectorShape(path: CGPath(rect: pageRect, transform: nil))
        }
        shape.fill = .gradient(id)
        shape.fillOpacity = state.fillAlpha
        append(shape)
        state.clipID = savedClip
    }

    private func gradient(forPattern name: String, scanner: CGPDFScannerRef) -> String? {
        guard let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "Pattern", name)
        else { return nil }
        var dictRef: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dictRef), let dict = dictRef else { return nil } // tiling patterns are streams
        var type: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dict, "PatternType", &type), type == 2 else { return nil }
        var shadingRef: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dict, "Shading", &shadingRef), let shading = shadingRef else { return nil }
        let matrix = dictMatrix(dict, "Matrix") ?? .identity
        let base = baseCTMs.last ?? .identity
        return addGradient(shading, transform: matrix.concatenating(base).concatenating(flip), scanner: scanner)
    }

    private func addGradient(_ object: CGPDFObjectRef, transform: CGAffineTransform, scanner: CGPDFScannerRef) -> String? {
        var dictRef: CGPDFDictionaryRef?
        if !CGPDFObjectGetValue(object, .dictionary, &dictRef) {
            var streamRef: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &streamRef), let stream = streamRef {
                dictRef = CGPDFStreamGetDictionary(stream)
            }
        }
        guard let dict = dictRef else { return nil }
        var type: CGPDFInteger = 0
        _ = CGPDFDictionaryGetInteger(dict, "ShadingType", &type)
        guard type == 2 || type == 3 else {
            warn("第 \(type) 类渐变无法转换")
            return nil
        }
        guard let coords = numberArray(dict, "Coords"), coords.count == (type == 2 ? 4 : 6) else { return nil }
        var spaceObjectRef: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dict, "ColorSpace", &spaceObjectRef), let spaceObject = spaceObjectRef else { return nil }
        let space = colorSpace(object: spaceObject, scanner: scanner)
        var functionObjectRef: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dict, "Function", &functionObjectRef), let functionObject = functionObjectRef,
              let function = PDFFunction(object: functionObject) else {
            warn("渐变颜色函数无法解析")
            return nil
        }
        var domain = numberArray(dict, "Domain") ?? [0, 1]
        if domain.count < 2 { domain = [0, 1] }
        let samples = 32
        var stops: [GradientStop] = []
        for i in 0...samples {
            let u = CGFloat(i) / CGFloat(samples)
            let t = domain[0] + (domain[1] - domain[0]) * u
            stops.append(GradientStop(offset: u, color: convert(function.evaluate(t), space)))
        }
        let id = makeID("grad")
        drawing.gradients[id] = VectorGradient(index: nextIndex, radial: type == 3, coords: coords,
                                               transform: transform, stops: simplify(stops))
        return id
    }

    /// Drops stops that lie on the straight line between their neighbours.
    private func simplify(_ stops: [GradientStop]) -> [GradientStop] {
        guard stops.count > 2 else { return stops }
        var result = [stops[0]]
        for i in 1..<(stops.count - 1) {
            let a = result[result.count - 1], b = stops[i], c = stops[i + 1]
            let t = (b.offset - a.offset) / max(c.offset - a.offset, 0.0001)
            let linear = abs(b.color.red - (a.color.red + (c.color.red - a.color.red) * Double(t))) < 0.006
                && abs(b.color.green - (a.color.green + (c.color.green - a.color.green) * Double(t))) < 0.006
                && abs(b.color.blue - (a.color.blue + (c.color.blue - a.color.blue) * Double(t))) < 0.006
            if !linear { result.append(b) }
        }
        result.append(stops[stops.count - 1])
        return result
    }

    // MARK: Soft masks and XObjects

    private func softMask(_ dict: CGPDFDictionaryRef, scanner: CGPDFScannerRef) -> String? {
        var groupRef: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(dict, "G", &groupRef), let group = groupRef,
              let groupDict = CGPDFStreamGetDictionary(group) else { return nil }
        var inner = GState()
        inner.ctm = state.ctm
        maskDepth += 1
        outputs.append([])
        runForm(group, groupDict, parent: scanner, initial: inner)
        let children = outputs.removeLast()
        maskDepth -= 1
        let alpha = dictName(dict, "S") == "Alpha"
        var backdrop: RGBA?
        if !alpha, let components = numberArray(dict, "BC"), !components.isEmpty {
            let space: ColorSpace = components.count == 1 ? .gray : (components.count == 4 ? .cmyk : .rgb)
            let color = convert(components, space)
            if color.red + color.green + color.blue > 0 { backdrop = color }
        }
        let id = makeID("mask")
        drawing.masks[id] = VectorMask(index: nextIndex, alpha: alpha, backdrop: backdrop, children: children)
        return id
    }

    fileprivate func xObject(_ scanner: CGPDFScannerRef) {
        guard let name = popName(scanner),
              let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", name)
        else { return }
        var streamRef: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &streamRef), let stream = streamRef,
              let dict = CGPDFStreamGetDictionary(stream) else { return }
        switch dictName(dict, "Subtype") {
        case "Image":
            rasterImage()
        case "Form":
            guard formDepth < 24 else {
                warn("嵌套层级过深，部分内容已跳过")
                return
            }
            var group: CGPDFDictionaryRef?
            let isGroup = CGPDFDictionaryGetDictionary(dict, "Group", &group)
            if isGroup && (state.fillAlpha < 0.999 || state.maskID != nil) {
                // A transparency group is composited as one unit: its alpha,
                // mask and clip go on an SVG <g>, not on each child.
                var inner = state
                inner.fillAlpha = 1
                inner.strokeAlpha = 1
                inner.maskID = nil
                inner.clipID = nil
                inner.lastClip = nil
                outputs.append([])
                runForm(stream, dict, parent: scanner, initial: inner)
                let children = outputs.removeLast()
                if !children.isEmpty {
                    let node = VectorGroup(opacity: state.fillAlpha, clipID: state.clipID,
                                           maskID: state.maskID, children: children)
                    outputs[outputs.count - 1].append(.group(node))
                }
            } else {
                runForm(stream, dict, parent: scanner, initial: state)
            }
        default:
            break
        }
    }

    private func runForm(_ stream: CGPDFStreamRef, _ dict: CGPDFDictionaryRef, parent: CGPDFScannerRef, initial: GState) {
        var resources: CGPDFDictionaryRef?
        if !CGPDFDictionaryGetDictionary(dict, "Resources", &resources) { resources = nil }
        let matrix = dictMatrix(dict, "Matrix") ?? .identity

        let outerState = state, outerSaved = saved, outerPath = path, outerClip = pendingClip
        state = initial
        state.ctm = matrix.concatenating(initial.ctm)
        saved = []
        path = CGMutablePath()
        pendingClip = nil
        baseCTMs.append(state.ctm)
        formDepth += 1

        // Without its own resources the form resolves names through its parent.
        let content = CGPDFContentStreamCreateWithStream(stream, resources ?? dict, CGPDFScannerGetContentStream(parent))
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)

        formDepth -= 1
        baseCTMs.removeLast()
        state = outerState
        saved = outerSaved
        path = outerPath
        pendingClip = outerClip
    }

    fileprivate func text() {
        drawing.textRuns += 1
        warn("包含文字，SVG 中缺少这部分")
    }

    fileprivate func rasterImage() {
        drawing.rasterImages += 1
        warn("包含位图，SVG 中缺少这部分")
    }

    // MARK: Cleanup

    /// Removes rectangular clips that do not cut anything, such as the page
    /// or layer bounds that SwiftUI and UIKit clip to.
    private func prune(_ nodes: [VectorNode]) -> [VectorNode] {
        nodes.map { node in
            switch node {
            case .shape(var shape):
                shape.clipID = effectiveClip(shape.clipID, covering: shape.bounds)
                return .shape(shape)
            case .group(var group):
                group.children = prune(group.children)
                group.clipID = effectiveClip(group.clipID, covering: bounds(of: group.children))
                return .group(group)
            }
        }
    }

    private func bounds(of nodes: [VectorNode]) -> CGRect {
        nodes.reduce(CGRect.null) { result, node in
            switch node {
            case .shape(let shape): return result.union(shape.bounds)
            case .group(let group): return result.union(bounds(of: group.children))
            }
        }
    }

    private func effectiveClip(_ id: String?, covering rect: CGRect) -> String? {
        guard !rect.isNull else { return id }
        var current = id
        while let clipID = current, let clip = drawing.clips[clipID] {
            var box = CGRect.zero
            guard clip.path.isRect(&box), box.insetBy(dx: -0.01, dy: -0.01).contains(rect) else { break }
            current = clip.parent
        }
        return current
    }

    // MARK: Helpers

    private func makeID(_ prefix: String) -> String {
        nextIndex += 1
        return "\(prefix)\(nextIndex)"
    }

    private func warn(_ message: String) {
        if !drawing.warnings.contains(message) { drawing.warnings.append(message) }
    }
}

private func extractor(_ info: UnsafeMutableRawPointer?) -> PDFVectorExtractor {
    Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
}

/// Pops `count` numeric operands, returned in their original order.
private func popNumbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
    var values = [CGFloat](repeating: 0, count: count)
    var index = count - 1
    while index >= 0 {
        var value: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
        values[index] = value
        index -= 1
    }
    return values
}

private func popName(_ scanner: CGPDFScannerRef) -> String? {
    var pointerRef: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(scanner, &pointerRef), let pointer = pointerRef else { return nil }
    return String(cString: pointer)
}

/// A name object, or the first name of an array of names.
private func objectName(_ object: CGPDFObjectRef) -> String? {
    var pointer: UnsafePointer<CChar>?
    if CGPDFObjectGetValue(object, .name, &pointer), let pointer { return String(cString: pointer) }
    var array: CGPDFArrayRef?
    if CGPDFObjectGetValue(object, .array, &array), let array { return arrayName(array, 0) }
    return nil
}

private func arrayName(_ array: CGPDFArrayRef, _ index: Int) -> String? {
    guard index < CGPDFArrayGetCount(array) else { return nil }
    var pointerRef: UnsafePointer<CChar>?
    guard CGPDFArrayGetName(array, index, &pointerRef), let pointer = pointerRef else { return nil }
    return String(cString: pointer)
}

private func dictName(_ dict: CGPDFDictionaryRef, _ key: String) -> String? {
    var pointerRef: UnsafePointer<CChar>?
    guard CGPDFDictionaryGetName(dict, key, &pointerRef), let pointer = pointerRef else { return nil }
    return String(cString: pointer)
}

private func numberArray(_ dict: CGPDFDictionaryRef, _ key: String) -> [CGFloat]? {
    var arrayRef: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(dict, key, &arrayRef), let array = arrayRef else { return nil }
    return numbers(in: array)
}

private func numbers(in array: CGPDFArrayRef) -> [CGFloat] {
    var result: [CGFloat] = []
    for index in 0..<CGPDFArrayGetCount(array) {
        var value: CGPDFReal = 0
        if CGPDFArrayGetNumber(array, index, &value) { result.append(value) }
    }
    return result
}

private func dictMatrix(_ dict: CGPDFDictionaryRef, _ key: String) -> CGAffineTransform? {
    guard let v = numberArray(dict, key), v.count == 6 else { return nil }
    return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
}

private func interpolate(_ x: CGFloat, _ x0: CGFloat, _ x1: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> CGFloat {
    x1 == x0 ? y0 : y0 + (x - x0) * (y1 - y0) / (x1 - x0)
}

/// The PDF function types CoreGraphics writes for gradients (0, 2, 3).
private enum PDFFunction {
    case exponential(domain: [CGFloat], c0: [CGFloat], c1: [CGFloat], n: CGFloat)
    case stitching(domain: [CGFloat], functions: [PDFFunction], bounds: [CGFloat], encode: [CGFloat])
    case sampled(domain: [CGFloat], encode: [CGFloat], decode: [CGFloat], size: Int, outputs: Int,
                 maxValue: CGFloat, samples: [CGFloat])
    case list([PDFFunction])

    init?(object: CGPDFObjectRef) {
        var arrayRef: CGPDFArrayRef?
        if CGPDFObjectGetValue(object, .array, &arrayRef), let array = arrayRef {
            guard let functions = PDFFunction.functions(in: array) else { return nil }
            self = .list(functions)
            return
        }
        var streamRef: CGPDFStreamRef?
        var dictRef: CGPDFDictionaryRef?
        if CGPDFObjectGetValue(object, .stream, &streamRef), let stream = streamRef {
            dictRef = CGPDFStreamGetDictionary(stream)
        } else {
            _ = CGPDFObjectGetValue(object, .dictionary, &dictRef)
        }
        guard let dict = dictRef else { return nil }
        var type: CGPDFInteger = -1
        _ = CGPDFDictionaryGetInteger(dict, "FunctionType", &type)
        var domain = numberArray(dict, "Domain") ?? [0, 1]
        if domain.count < 2 { domain = [0, 1] }
        switch type {
        case 2:
            var n: CGPDFReal = 1
            _ = CGPDFDictionaryGetNumber(dict, "N", &n)
            self = .exponential(domain: domain, c0: numberArray(dict, "C0") ?? [0],
                                c1: numberArray(dict, "C1") ?? [1], n: n)
        case 3:
            var listRef: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dict, "Functions", &listRef), let list = listRef,
                  let functions = PDFFunction.functions(in: list), !functions.isEmpty else { return nil }
            let bounds = numberArray(dict, "Bounds") ?? []
            var encode: [CGFloat] = numberArray(dict, "Encode") ?? []
            if encode.isEmpty {
                for _ in functions { encode += [0, 1] }
            }
            guard bounds.count == functions.count - 1, encode.count >= functions.count * 2 else { return nil }
            self = .stitching(domain: domain, functions: functions, bounds: bounds, encode: encode)
        case 0:
            guard let stream = streamRef, let sizeValue = numberArray(dict, "Size")?.first, sizeValue >= 1,
                  let range = numberArray(dict, "Range"), range.count >= 2 else { return nil }
            let size = Int(sizeValue)
            var bits: CGPDFInteger = 8
            _ = CGPDFDictionaryGetInteger(dict, "BitsPerSample", &bits)
            let outputs = range.count / 2
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format), format == .raw,
                  let samples = PDFFunction.readSamples(data as Data, bits: bits, count: size * outputs)
            else { return nil }
            let encode = numberArray(dict, "Encode") ?? [0, CGFloat(size - 1)]
            self = .sampled(domain: domain, encode: encode.count >= 2 ? encode : [0, CGFloat(size - 1)],
                            decode: numberArray(dict, "Decode") ?? range, size: size, outputs: outputs,
                            maxValue: pow(2, CGFloat(bits)) - 1, samples: samples)
        default:
            return nil
        }
    }

    private static func functions(in array: CGPDFArrayRef) -> [PDFFunction]? {
        var result: [PDFFunction] = []
        for index in 0..<CGPDFArrayGetCount(array) {
            var itemRef: CGPDFObjectRef?
            guard CGPDFArrayGetObject(array, index, &itemRef), let item = itemRef, let function = PDFFunction(object: item)
            else { return nil }
            result.append(function)
        }
        return result
    }

    private static func readSamples(_ data: Data, bits: Int, count: Int) -> [CGFloat]? {
        guard [1, 2, 4, 8, 12, 16, 24, 32].contains(bits), data.count * 8 >= bits * count else { return nil }
        let bytes = [UInt8](data)
        var result: [CGFloat] = []
        result.reserveCapacity(count)
        var position = 0
        for _ in 0..<count {
            var value: UInt64 = 0
            for _ in 0..<bits {
                let bit = (bytes[position >> 3] >> UInt8(7 - (position & 7))) & 1
                value = (value << 1) | UInt64(bit)
                position += 1
            }
            result.append(CGFloat(value))
        }
        return result
    }

    func evaluate(_ x: CGFloat) -> [CGFloat] {
        switch self {
        case let .exponential(domain, c0, c1, n):
            let t = min(max(x, domain[0]), domain[1])
            let p = n == 1 ? t : pow(max(t, 0), n)
            return (0..<max(c0.count, c1.count)).map { i in
                let a = i < c0.count ? c0[i] : 0
                let b = i < c1.count ? c1[i] : 1
                return a + p * (b - a)
            }
        case let .stitching(domain, functions, bounds, encode):
            let t = min(max(x, domain[0]), domain[1])
            var i = 0
            while i < bounds.count && t >= bounds[i] { i += 1 }
            let low = i == 0 ? domain[0] : bounds[i - 1]
            let high = i == bounds.count ? domain[1] : bounds[i]
            return functions[i].evaluate(interpolate(t, low, high, encode[2 * i], encode[2 * i + 1]))
        case let .sampled(domain, encode, decode, size, outputs, maxValue, samples):
            let t = min(max(x, domain[0]), domain[1])
            let e = min(max(interpolate(t, domain[0], domain[1], encode[0], encode[1]), 0), CGFloat(size - 1))
            let i0 = Int(e.rounded(.down))
            let i1 = min(i0 + 1, size - 1)
            let f = e - CGFloat(i0)
            return (0..<outputs).map { j in
                let sample = samples[i0 * outputs + j] * (1 - f) + samples[i1 * outputs + j] * f
                let d0 = 2 * j < decode.count ? decode[2 * j] : 0
                let d1 = 2 * j + 1 < decode.count ? decode[2 * j + 1] : 1
                return interpolate(sample, 0, maxValue, d0, d1)
            }
        case let .list(functions):
            return functions.flatMap { $0.evaluate(x) }
        }
    }
}
