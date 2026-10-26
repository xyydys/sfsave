import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// Launched with `-SymbolStudioSelfTest`, the app renders a fixed set of
/// symbols through the SVG pipeline, prints the results to stdout and exits.
/// CI runs this in the simulator to check the conversion end to end.
@MainActor
enum SelfTest {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-SymbolStudioSelfTest") }

    private struct Case {
        let name: String
        var style = SymbolStyle()
        var engine = RenderEngine.swiftUI
        var dumpPDF = false
    }

    private static var cases: [Case] {
        func style(_ mode: RenderModeChoice, _ colors: [ColorChoice], paletteCount: Int = 2, gradient: Bool = false,
                   weight: WeightChoice = .regular, appearance: AppearanceChoice = .light,
                   variable: Double? = nil) -> SymbolStyle {
            var style = SymbolStyle()
            style.renderingMode = mode
            for (index, color) in colors.enumerated() { style.setColor(color, at: index) }
            style.paletteCount = paletteCount
            style.gradient = gradient
            style.weight = weight
            style.appearance = appearance
            if let variable { style.usesVariableValue = true; style.variableValue = variable }
            return style
        }
        return [
            Case(name: "xmark", style: style(.hierarchical, [.system(.secondary)]), dumpPDF: true),
            Case(name: "xmark", style: style(.hierarchical, [.system(.secondary)]), engine: .uiKit, dumpPDF: true),
            Case(name: "heart.fill", style: style(.monochrome, [.system(.red)])),
            Case(name: "heart.fill", style: style(.monochrome, [.system(.red)], gradient: true), dumpPDF: true),
            Case(name: "xmark.circle.fill", style: style(.hierarchical, [.system(.blue)]), dumpPDF: true),
            Case(name: "person.crop.circle.badge.plus", style: style(.palette, [.system(.blue), .system(.green)]), dumpPDF: true),
            Case(name: "person.crop.circle.badge.plus", style: style(.palette, [.system(.blue), .system(.green)]), engine: .uiKit),
            Case(name: "person.3.sequence.fill", style: style(.palette, [.system(.red), .system(.orange), .system(.blue)], paletteCount: 3)),
            Case(name: "cloud.sun.rain.fill", style: style(.multicolor, [.system(.primary)]), dumpPDF: true),
            Case(name: "folder.badge.plus", style: style(.multicolor, [.system(.primary)])),
            Case(name: "wifi", style: style(.hierarchical, [.system(.blue)], variable: 0.5)),
            Case(name: "square.and.arrow.up", style: style(.monochrome, [.system(.primary)], weight: .bold, appearance: .dark)),
            Case(name: "bell.badge.fill", style: style(.palette, [.system(.red), .system(.primary)], gradient: true)),
            Case(name: "trash.slash", style: style(.hierarchical, [.custom(RGBA(red: 0.2, green: 0.4, blue: 0.6))]))
        ]
    }

    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SelfTest", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("SELFTEST-BEGIN iOS \(UIDevice.current.systemVersion) gradientAPI=\(SymbolGradientSupport.isAvailable)")
        var failures = 0
        for (index, test) in cases.enumerated() {
            var options = ExportOptions()
            options.canvas = 128
            options.engine = test.engine
            let label = "\(index)-\(test.name)-\(test.style.renderingMode.rawValue)-\(test.engine.rawValue)"
            print("=== CASE \(label)")
            guard let output = SymbolPipeline.render(name: test.name, style: test.style, options: options) else {
                print("RESULT failed")
                failures += 1
                if let pdf = SymbolPipeline.capturedPDF(name: test.name, style: test.style, engine: test.engine) {
                    let drawing = PDFVectorExtractor.extract(pdf: pdf)
                    print("CAPTURE bytes=\(pdf.count) shapes=\(drawing?.shapeCount ?? -1) raster=\(drawing?.rasterImages ?? -1) text=\(drawing?.textRuns ?? -1) warnings=\(drawing?.warnings ?? [])")
                    print("PDF-BEGIN")
                    print(contentDump(pdf))
                    print("PDF-END")
                } else {
                    print("CAPTURE none")
                }
                continue
            }
            let drawing = output.drawing
            print("RESULT ok engine=\(output.engine.rawValue) shapes=\(drawing.shapeCount) gradients=\(drawing.gradients.count) masks=\(drawing.masks.count) clips=\(drawing.clips.count) raster=\(drawing.rasterImages) text=\(drawing.textRuns) page=\(drawing.pageSize) bounds=\(drawing.bounds) frame=\(output.frame)")
            for note in output.notes + drawing.warnings { print("WARNING \(note)") }
            if output.engine != test.engine, let pdf = SymbolPipeline.capturedPDF(name: test.name, style: test.style, engine: test.engine) {
                let requested = PDFVectorExtractor.extract(pdf: pdf)
                print("FALLBACK from \(test.engine.rawValue): bytes=\(pdf.count) shapes=\(requested?.shapeCount ?? -1) raster=\(requested?.rasterImages ?? -1) text=\(requested?.textRuns ?? -1)")
                print("PDF-BEGIN")
                print(contentDump(pdf))
                print("PDF-END")
            }
            print("SVG-BEGIN")
            print(output.svg, terminator: "")
            print("SVG-END")
            let reference = referencePNG(test.name, test.style)
            print("REFERENCE-PNG \(reference?.base64EncodedString() ?? "none")")
            if test.dumpPDF {
                print("PDF-BEGIN")
                print(contentDump(output.pdf))
                print("PDF-END")
            }
            try? Data(output.svg.utf8).write(to: directory.appendingPathComponent(label + ".svg"))
            try? output.pdf.write(to: directory.appendingPathComponent(label + ".pdf"))
            if let reference { try? reference.write(to: directory.appendingPathComponent(label + ".png")) }
        }
        print("SELFTEST-DONE failures=\(failures)")
        fflush(stdout)
        exit(0)
    }

    /// The system's own bitmap rendering, for comparison with the SVG.
    private static func referencePNG(_ name: String, _ style: SymbolStyle) -> Data? {
        let view = StyledSymbol(name: name, style: style, pointSize: 48)
            .padding(8)
            .environment(\.colorScheme, style.appearance.colorScheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.uiImage?.pngData()
    }

    /// Decoded content streams of the page and its form XObjects, plus the
    /// graphics state dictionaries, so CI logs show what the system drew.
    private static func contentDump(_ pdf: Data) -> String {
        guard let provider = CGDataProvider(data: pdf as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1),
              let pageDict = page.dictionary else { return "unreadable" }
        var out: [String] = []
        var contents: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(pageDict, "Contents", &contents), let contents {
            out.append("-- page\n" + streamText(contents))
        }
        var resources: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources), let resources {
            dumpResources(resources, depth: 0, into: &out)
        }
        return out.joined(separator: "\n")
    }

    private static func dumpResources(_ resources: CGPDFDictionaryRef, depth: Int, into out: inout [String]) {
        guard depth < 4 else { return }
        var extStates: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "ExtGState", &extStates), let extStates {
            for (name, object) in entries(extStates) {
                var dictRef: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(object, .dictionary, &dictRef), let dict = dictRef else { continue }
                out.append("-- gs \(name): " + entries(dict).map { "\($0.0)=\(describe($0.1))" }.joined(separator: " "))
            }
        }
        for category in ["Shading", "Pattern", "ColorSpace"] {
            var dict: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(resources, category, &dict), let dict {
                for (name, object) in entries(dict) { out.append("-- \(category) \(name): \(describe(object))") }
            }
        }
        var xObjects: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects {
            for (name, object) in entries(xObjects) {
                var streamRef: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &streamRef), let stream = streamRef,
                      let dict = CGPDFStreamGetDictionary(stream) else { continue }
                out.append("-- xobject \(name) depth \(depth): " + entries(dict).map { "\($0.0)=\(describe($0.1))" }.joined(separator: " "))
                out.append(streamText(stream))
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dict, "Resources", &inner), let inner {
                    dumpResources(inner, depth: depth + 1, into: &out)
                }
            }
        }
    }

    private static func entries(_ dict: CGPDFDictionaryRef) -> [(String, CGPDFObjectRef)] {
        final class Box { var items: [(String, CGPDFObjectRef)] = [] }
        let box = Box()
        CGPDFDictionaryApplyBlock(dict, { key, object, info in
            let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
            box.items.append((String(cString: key), object))
            return true
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.items.sorted { $0.0 < $1.0 }
    }

    private static func describe(_ object: CGPDFObjectRef) -> String {
        switch CGPDFObjectGetType(object) {
        case .name:
            var pointer: UnsafePointer<CChar>?
            return CGPDFObjectGetValue(object, .name, &pointer) && pointer != nil ? "/" + String(cString: pointer!) : "/?"
        case .integer, .real:
            var value: CGPDFReal = 0
            return CGPDFObjectGetValue(object, .real, &value) ? SVGWriter.number(value) : "?"
        case .boolean: return "bool"
        case .array:
            var arrayRef: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &arrayRef), let array = arrayRef else { return "[]" }
            var items: [String] = []
            for index in 0..<min(CGPDFArrayGetCount(array), 12) {
                var item: CGPDFObjectRef?
                if CGPDFArrayGetObject(array, index, &item), let item { items.append(describe(item)) }
            }
            return "[" + items.joined(separator: " ") + "]"
        case .dictionary:
            var dictRef: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictRef), let dict = dictRef else { return "<<>>" }
            return "<<" + entries(dict).map { "\($0.0)=\(describe($0.1))" }.joined(separator: " ") + ">>"
        case .stream: return "stream"
        case .string: return "string"
        default: return "null"
        }
    }

    private static func streamText(_ stream: CGPDFStreamRef) -> String {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { return "(no data)" }
        guard format == .raw else { return "(\(CFDataGetLength(data)) bytes, not text)" }
        let text = String(decoding: data as Data, as: UTF8.self)
        return text.count > 6000 ? String(text.prefix(6000)) + "\n…(truncated)" : text
    }
}
