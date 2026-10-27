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
        var canvas = 128
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
            Case(name: "xmark", style: style(.hierarchical, [.system(.secondary)], appearance: .dark), canvas: 0),
            Case(name: "heart.fill", style: style(.monochrome, [.system(.red)])),
            Case(name: "heart.fill", style: style(.monochrome, [.system(.red)], gradient: true), dumpPDF: true),
            Case(name: "xmark.circle.fill", style: style(.hierarchical, [.system(.blue)]), dumpPDF: true),
            Case(name: "person.crop.circle.badge.plus", style: style(.palette, [.system(.blue), .system(.green)]), dumpPDF: true),
            Case(name: "externaldrive.badge.checkmark", style: style(.hierarchical, [.system(.accent)], gradient: true, weight: .black)),
            Case(name: "person.3.sequence.fill", style: style(.palette, [.system(.red), .system(.orange), .system(.blue)], paletteCount: 3)),
            Case(name: "cloud.sun.rain.fill", style: style(.multicolor, [.system(.primary)]), dumpPDF: true),
            Case(name: "folder.badge.plus", style: style(.multicolor, [.system(.primary)])),
            Case(name: "wifi", style: style(.hierarchical, [.system(.blue)], variable: 0.5)),
            Case(name: "square.and.arrow.up", style: style(.monochrome, [.system(.primary)], weight: .bold, appearance: .dark)),
            Case(name: "bell.badge.fill", style: style(.palette, [.system(.red), .system(.primary)], gradient: true)),
            Case(name: "trash.slash", style: style(.hierarchical, [.custom(RGBA(red: 0.2, green: 0.4, blue: 0.6))]))
        ]
    }

    static func run() async {
        setvbuf(stdout, nil, _IONBF, 0)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SelfTest", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("SELFTEST-BEGIN iOS \(UIDevice.current.systemVersion) gradientAPI=\(SymbolGradientSupport.isAvailable)")
        var failures = 0
        for (index, test) in cases.enumerated() {
            var options = ExportOptions()
            options.canvas = test.canvas
            let label = "\(index)-\(test.name)-\(test.style.renderingMode.rawValue)"
            print("=== CASE \(label)")
            guard let output = SymbolPipeline.render(name: test.name, style: test.style, options: options) else {
                print("RESULT failed")
                failures += 1
                if let pdf = SymbolPipeline.capturePDF(name: test.name, style: test.style)?.pdf {
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
            print("RESULT ok shapes=\(drawing.shapeCount) gradients=\(drawing.gradients.count) masks=\(drawing.masks.count) clips=\(drawing.clips.count) raster=\(drawing.rasterImages) text=\(drawing.textRuns) page=\(drawing.pageSize) bounds=\(drawing.bounds) frame=\(output.frame)")
            for warning in drawing.warnings { print("WARNING \(warning)") }
            if drawing.isIncomplete { failures += 1 }
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
        failures += await batchTest(directory: directory)
        failures += await fileTest(directory: directory)
        print("SELFTEST-DONE failures=\(failures)")
        fflush(stdout)
        exit(0)
    }

    /// Exports the bundled sample plan, then feeds the resolver a broken plan and
    /// checks that every problem is reported.
    private static func batchTest(directory: URL) async -> Int {
        var failures = 0
        print("=== BATCH sample plan")
        do {
            guard let url = Bundle.main.url(forResource: "sample-plan", withExtension: "json") else {
                print("BATCH-ERROR sample-plan.json is not in the bundle")
                return 1
            }
            let plan = try IconPlan.decode(Data(contentsOf: url)).resolve()
            print("BATCH-PLAN icons=\(plan.icons.count) errors=\(plan.errorCount) warnings=\(plan.warningCount)")
            for issue in plan.issues { print("BATCH-ISSUE \(issue.severity) \(issue.icon ?? "-"): \(issue.message)") }
            if plan.errorCount > 0 || plan.icons.count != 6 { failures += 1 }
            var options = BatchOptions()
            options.formats = .both
            let summary = try await BatchExporter.export(plan, options: options) { _, _ in }
            print("BATCH-RESULT files=\(summary.fileCount) icons=\(summary.iconCount) skipped=\(summary.skipped.count) expected=\(plan.fileCount(options))")
            for item in summary.skipped { print("BATCH-SKIPPED \(item.icon): \(item.reason)") }
            if !summary.skipped.isEmpty || summary.fileCount != plan.fileCount(options) { failures += 1 }
            let zip = try Data(contentsOf: summary.url)
            try zip.write(to: directory.appendingPathComponent("sample-batch.zip"))
            print("BATCH-ZIP-BASE64 \(zip.base64EncodedString())")
        } catch {
            print("BATCH-ERROR \(error.localizedDescription)")
            failures += 1
        }

        print("=== BATCH broken plan")
        let broken = """
        { "version": 1, "colour": 1, "defaults": { "scales": [2] },
          "icons": [
            { "file": "ok1", "symbol": "house.fill", "color": "blue" },
            { "file": "OK1", "symbol": "heart.fill", "color": "red" },
            { "file": "bad_mode", "symbol": "house.fill", "mode": "palete" },
            { "file": "bad_color", "symbol": "house.fill", "light": ["#12345"] },
            { "file": "bad_symbol", "symbol": "not.a.symbol" },
            { "file": "bad_scales", "symbol": "house.fill", "scales": [2, 2] },
            { "symbol": "heart" },
            { "file": "x/../y", "symbol": "heart" },
            { "file": "warn_palette", "symbol": "person.2.fill", "mode": "palette", "colors": ["red"], "colour": "typo" }
          ] }
        """
        do {
            let plan = try IconPlan.decode(Data(broken.utf8)).resolve()
            print("BATCH-PLAN icons=\(plan.icons.count) errors=\(plan.errorCount) warnings=\(plan.warningCount)")
            for issue in plan.issues { print("BATCH-ISSUE \(issue.severity) \(issue.icon ?? "-"): \(issue.message)") }
            if plan.icons.map({ $0.names[0] }) != ["ok1", "warn_palette"] || plan.errorCount != 7 || plan.warningCount != 3 {
                print("BATCH-UNEXPECTED broken plan should keep ok1 + warn_palette with 7 errors and 3 warnings")
                failures += 1
            }
        } catch {
            print("BATCH-ERROR \(error.localizedDescription)")
            failures += 1
        }

        print("=== BATCH decode errors")
        for text in ["{ \"icons\": [ ", "{ \"icons\": [ { \"file\": \"a\", \"symbol\": \"heart\", \"scales\": \"2\" } ] }", "{ \"name\": \"x\" }"] {
            do {
                _ = try IconPlan.decode(Data(text.utf8))
                print("BATCH-UNEXPECTED decoded without error: \(text)")
                failures += 1
            } catch {
                print("BATCH-DECODE-ERROR \(error.localizedDescription)")
            }
        }
        return failures
    }

    /// Opens and closes both document pickers, then reads a plan back from a
    /// file the way a picked or opened file is read.
    private static func fileTest(directory: URL) async -> Int {
        var failures = 0
        print("=== FILES document pickers")
        let saved = directory.appendingPathComponent("picker-test.txt")
        try? Data("picker".utf8).write(to: saved)
        // The picker loads its remote view first and only then appears, so poll.
        func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Double? {
            let start = Date()
            while Date().timeIntervalSince(start) < seconds {
                if condition() { return Date().timeIntervalSince(start) }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return nil
        }
        for kind in ["open", "save"] {
            let shown = kind == "open"
                ? DocumentPicker.open(PlanFile.types) { _ in }
                : DocumentPicker.save(saved) { }
            let after = await waitFor(15) { DocumentPicker.topController() is UIDocumentPickerViewController }
            let top = DocumentPicker.topController()
            let ok = shown && after != nil
            print("FILES-PICKER \(kind) shown=\(shown) after=\(after.map { String(format: "%.1fs", $0) } ?? "-") top=\(top.map { String(describing: type(of: $0)) } ?? "none") \(ok ? "ok" : "FAILED")")
            if !ok { failures += 1 }
            if let top, top is UIDocumentPickerViewController { top.dismiss(animated: false) }
            _ = await waitFor(5) { !(DocumentPicker.topController() is UIDocumentPickerViewController) }
        }

        print("=== FILES plan from file")
        let text = """
        { "version": 1, "name": "named", "_comment": "notes", "_unmatched": [ { "placeholder": "W003" } ], "_skipped": [],
          "output": { "darkSuffix": "_dark", "scaleSuffix": "@{n}x", "svgFolder": "svg" },
          "icons": [
            { "file": "arrow_left_regular", "symbol": "chevron.left", "mode": "monochrome", "colors": ["#000000"],
              "appearances": ["light"], "formats": ["svg", "png"], "scales": [3], "_resource": "svg_tinted_by_wechat",
              "_wgp": { "placeholder": "W001", "designs_merged": ["W001"] } },
            { "file": "weapp_corner_icon_light", "symbol": "link.circle.fill", "mode": "palette",
              "light": ["#FFFFFF", "#6467F0"], "dark": ["#FFFFFF", "#7D80F5"], "scales": [3] }
          ] }
        """
        do {
            let url = directory.appendingPathComponent("opened-plan.json")
            try Data(text.utf8).write(to: url)
            let plan = try IconPlan.decode(PlanFile.read(url)).resolve()
            print("FILES-PLAN icons=\(plan.icons.count) errors=\(plan.errorCount) warnings=\(plan.warningCount)")
            for issue in plan.issues { print("FILES-ISSUE \(issue.severity) \(issue.icon ?? "-"): \(issue.message)") }
            if plan.icons.count != 2 || plan.errorCount + plan.warningCount > 0 { failures += 1 }
        } catch {
            print("FILES-ERROR \(error.localizedDescription)")
            failures += 1
        }
        return failures
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
                var subtype: UnsafePointer<CChar>?
                let isImage = CGPDFDictionaryGetName(dict, "Subtype", &subtype) && subtype.map { String(cString: $0) } == "Image"
                if !isImage { out.append(streamText(stream)) }
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
