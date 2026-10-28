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
        /// The SVG must come out as plain paths: no mask, no clip-path.
        var plain = false
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
        func fill(_ start: String, _ end: String) -> GradientFill { GradientFill(RGBA(hex: start) ?? .black, RGBA(hex: end) ?? .black) }
        func filled(_ base: SymbolStyle, _ fills: [GradientFill]) -> SymbolStyle {
            var style = base
            style.fills = fills
            return style
        }
        func badged(_ base: SymbolStyle, _ shape: BadgeShape, _ fill: GradientFill) -> SymbolStyle {
            var style = base
            style.badge = SymbolBadge(shape: shape, fill: fill)
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
            Case(name: "trash.slash", style: style(.hierarchical, [.custom(RGBA(red: 0.2, green: 0.4, blue: 0.6))])),
            Case(name: "heart.fill", style: filled(style(.monochrome, [.system(.red)]), [fill("#FF5F6D", "#FFC371")]), dumpPDF: true),
            Case(name: "person.2.fill", style: filled(style(.hierarchical, [.system(.blue)]), [fill("#7F5AF0", "#2CB5FF")])),
            Case(name: "bell.badge.fill", style: filled(style(.palette, [.system(.red), .system(.blue)]),
                                                        [fill("#FF3CAC", "#784BA0"), fill("#00DBDE", "#2B86C5")])),
            Case(name: "camera.fill", style: badged(style(.monochrome, [.system(.white)]), .squircle, fill("#6A5CFF", "#C04CFD")), dumpPDF: true),
            Case(name: "magnifyingglass", style: badged(style(.hierarchical, [.system(.white)]), .circle, fill("#FF7A45", "#FF3D71"))),
            // Symbols whose gaps between layers came out as masks.
            Case(name: "document.on.document.fill", style: style(.monochrome, [.system(.blue)]), plain: true),
            Case(name: "square.fill.on.square.fill", style: style(.hierarchical, [.system(.blue)]), plain: true),
            Case(name: "square.and.pencil", style: style(.monochrome, [.system(.blue)]), plain: true),
            Case(name: "bell.slash", style: style(.monochrome, [.system(.red)]), plain: true),
            Case(name: "building.2.fill", style: style(.hierarchical, [.system(.blue)]), plain: true),
            Case(name: "clock", style: style(.hierarchical, [.system(.orange)]), plain: true),
            Case(name: "captions.bubble.fill", style: style(.monochrome, [.system(.blue)]), plain: true),
            Case(name: "person.2.fill", style: filled(style(.hierarchical, [.system(.blue)]), [fill("#7F5AF0", "#2CB5FF")]), plain: true),
            // The "aurora" look on the compass, which looked soft in Files.
            Case(name: "safari.fill", style: filled(style(.hierarchical, [.system(.blue)], weight: .medium), [fill("#7F5AF0", "#2CB5FF")]), plain: true),
            Case(name: "safari", style: filled(style(.hierarchical, [.system(.blue)], weight: .medium), [fill("#7F5AF0", "#2CB5FF")]), plain: true)
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
            let masks = output.svg.components(separatedBy: "<mask").count - 1
            let clips = output.svg.components(separatedBy: "clip-path=").count - 1
            print("FLAT masks=\(masks) clips=\(clips)\(test.plain && masks + clips > 0 ? " FAILED" : "")")
            if test.plain && masks + clips > 0 { failures += 1 }
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
        failures += await captureTest()
        failures += await templateTest()
        failures += await sizingTest()
        failures += suggestionTest()
        failures += await schemeTest()
        failures += presetFlatTest()
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

    /// Imports a small capture zip (deflated, laid out like the capture tool's),
    /// applies a preset and a badge look, exports, checks the plan JSON reads
    /// back, merges the same capture again and reopens the saved project. Then
    /// merges a "newer version" capture and checks that no choice changes, that
    /// bulk apply leaves the hand-made choice alone and that a backup restores.
    private static func captureTest() async -> Int {
        var failures = 0
        print("=== CAPTURE import")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureSelfTest", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        guard let data = Data(base64Encoded: captureZip) else {
            print("CAPTURE-ERROR test zip does not decode")
            return 1
        }
        let store = CaptureStore(root: root)
        try? FileManager.default.removeItem(at: store.backupsFolder)
        do {
            let first = try await store.importCapture(data, merge: false)
            for icon in store.icons {
                let box = icon.inkBox.map { "\(SVGWriter.number($0.minX)),\(SVGWriter.number($0.minY)),\(SVGWriter.number($0.width)),\(SVGWriter.number($0.height))" } ?? "nil"
                print("CAPTURE-ICON \(icon.name) kind=\(icon.kind.rawValue) canvas=\(icon.sizeText) colors=\(icon.colors) box=\(box) symbols=\(store.symbols(for: icon))")
            }
            print("CAPTURE-IMPORT added=\(first.added) updated=\(first.updated) skipped=\(first.skipped)")
            if first.added != 3 || store.icons.count != 3 || store.icons.contains(where: { $0.inkBox == nil }) { failures += 1 }

            store.setGlobal(GlobalStyle(look: LookPreset.all[0].look(for: nil)))
            let applied = store.fillPending()
            print("CAPTURE-APPLY \(applied)")
            if applied != 3 { failures += 1 }
            if let icon = store.icons.first(where: { $0.name == "AS_Email" }), let preset = LookPreset.named("badgeViolet") {
                var choice = store.choice(for: icon)
                choice.look = preset.look(for: icon)
                choice.presetID = preset.id
                choice.manual = true
                choice.followsGlobal = false
                store.setChoice(choice, for: icon)
            }

            let options = CaptureExportOptions()
            let plan = store.resolvedPlan(options)
            let json = try store.planJSON(options)
            let reread = try IconPlan.decode(json).resolve()
            print("CAPTURE-PLAN icons=\(plan.icons.count) issues=\(plan.issues.count) json-icons=\(reread.icons.count) json-errors=\(reread.errorCount) json-warnings=\(reread.warningCount)")
            for issue in reread.issues { print("CAPTURE-JSON-ISSUE \(issue.severity) \(issue.icon ?? "-"): \(issue.message)") }
            if plan.icons.count != 3 || reread.icons.count != 3 || reread.errorCount > 0 { failures += 1 }

            let result = try await BatchExporter.export(plan, options: BatchOptions(), extras: ["plan.json": json]) { _, _ in }
            let zip = try Data(contentsOf: result.url)
            print("CAPTURE-EXPORT files=\(result.fileCount) icons=\(result.iconCount) skipped=\(result.skipped.map(\.reason))")
            let paths = try ZipReader(data: zip).entries.map(\.path).sorted()
            print("CAPTURE-ZIP \(paths)")
            print("CAPTURE-ZIP-BASE64 \(zip.base64EncodedString())")
            if result.fileCount != 6 || !result.skipped.isEmpty { failures += 1 }

            if let render = SymbolPipeline.renderDrawing(name: "heart.fill", style: SymbolStyle()) {
                let layout = SVGWriter.layout(for: render.drawing, frame: render.frame, width: 24, height: 24, padding: 0.1, fit: .contain)
                let svg = SVGWriter.svg(render.drawing, layout: layout, title: "scaled", background: nil, displayScale: 10)
                let scaled = svg.contains("width=\"240\" height=\"240\" viewBox=\"0 0 24 24\"")
                print("CAPTURE-SVG-SCALE \(scaled ? "ok" : "FAILED")")
                if !scaled { failures += 1 }
            }

            let second = try await store.importCapture(data, merge: true)
            let reopened = CaptureStore(root: root)
            print("CAPTURE-MERGE added=\(second.added) updated=\(second.updated) choices=\(store.choices.count) reopened=\(reopened.icons.count)/\(reopened.choices.count)")
            if second.added != 0 || second.updated != 3 || store.choices.count != 3
                || reopened.icons.count != 3 || reopened.choices.count != 3 { failures += 1 }

            // A newer WeChat: heart_filled is captured bigger and one icon is new.
            let before = store.choices
            let newer = try newerCapture(from: data)
            let third = try await store.importCapture(newer, merge: true)
            let heart = store.icons.first { $0.name == "heart_filled" }
            let fresh = store.icons.filter { store.isNew($0) }.map(\.name)
            let heartText = heart.map { "canvas=\(SVGWriter.number($0.canvas.width)) update=\($0.update.map { SVGWriter.number($0.canvas.width) } ?? "nil")" } ?? "missing"
            print("CAPTURE-NEWER version=\(third.version ?? "-") added=\(third.added) changedKept=\(third.changedKept) new=\(fresh) heart \(heartText) choicesSame=\(store.choices == before)")
            if third.added != 1 || third.changedKept != 1 || fresh != ["new_icon_test"] || store.choices != before
                || heart?.canvas.width != 24 || heart?.update?.canvas.width != 48 { failures += 1 }
            if let heart {
                store.adoptUpdate(for: heart)
                let adopted = store.icons.first { $0.name == "heart_filled" }
                print("CAPTURE-ADOPT canvas=\(adopted.map { SVGWriter.number($0.canvas.width) } ?? "-") update=\(adopted?.update != nil)")
                if adopted?.canvas.width != 48 || adopted?.update != nil { failures += 1 }
            }

            // Changing the global style moves the icons that follow it, not the one styled on its own.
            var sunset = store.global
            sunset.look = (LookPreset.named("sunset") ?? LookPreset.all[1]).look(for: nil)
            store.setGlobal(sunset)
            let looks = store.icons.compactMap { icon in store.choices[icon.name].map { (icon.name, store.effectiveLook(for: icon, choice: $0)) } }
            let heartFollows = looks.first { $0.0 == "heart_filled" }?.1 == sunset.look
            let emailOwn = looks.first { $0.0 == "AS_Email" }?.1.badge != nil
            let counts = store.styleCounts
            print("CAPTURE-GLOBAL heartFollows=\(heartFollows) emailOwn=\(emailOwn) following=\(counts.global) own=\(counts.own)")
            if !heartFollows || !emailOwn || counts.own != 1 { failures += 1 }

            let kept = store.choices
            _ = try await store.importCapture(newer, merge: false)
            let cleared = store.choices.count
            let backups = store.backups()
            if let latest = backups.first { try store.restore(latest) }
            print("CAPTURE-RESTORE cleared=\(cleared) backups=\(backups.map(\.reason)) restoredSame=\(store.choices == kept)")
            if cleared != 0 || backups.isEmpty || store.choices != kept { failures += 1 }
        } catch {
            print("CAPTURE-ERROR \(error.localizedDescription)")
            failures += 1
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: store.backupsFolder)
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent().appendingPathComponent("CaptureStyle.json"))
        return failures
    }

    /// Merges a replacement-plugin template into a captured project (an SVG
    /// resource drawn by the preview renderer, a bitmap with a dark copy, and
    /// an SVG for an icon the capture already has), then exports the plugin package.
    private static func templateTest() async -> Int {
        var failures = 0
        print("=== TEMPLATE import and plugin export")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TemplateSelfTest", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        guard let captureData = Data(base64Encoded: captureZip) else { return 1 }
        let store = CaptureStore(root: root)
        try? FileManager.default.removeItem(at: store.backupsFolder)
        do {
            _ = try await store.importCapture(captureData, merge: false)
            if let heart = store.icons.first(where: { $0.name == "heart_filled" }) {
                var choice = store.choice(for: heart)
                choice.replace = true
                choice.manual = true
                store.setChoice(choice, for: heart)
            }
            let result = try await store.importCapture(pluginTemplate(from: captureData), merge: true)
            let ring = store.icons.first { $0.name == "tpl_ring" }
            let heart = store.icons.first { $0.name == "heart_filled" }
            let email = store.icons.first { $0.name == "AS_Email" }
            func box(_ icon: CaptureIcon?) -> String {
                icon?.inkBox.map { "\(SVGWriter.number($0.minX)),\(SVGWriter.number($0.minY)),\(SVGWriter.number($0.width)),\(SVGWriter.number($0.height))" } ?? "nil"
            }
            print("TEMPLATE-IMPORT template=\(result.fromTemplate) added=\(result.added) updated=\(result.updated) changedKept=\(result.changedKept)")
            print("TEMPLATE-RING kind=\(ring?.kind.rawValue ?? "-") canvas=\(ring?.sizeText ?? "-") box=\(box(ring)) formats=\(ring?.plugin?.formats ?? []) inApp=\(ring?.plugin?.inApp ?? "-")")
            print("TEMPLATE-HEART canvas=\(heart.map { SVGWriter.number($0.canvas.width) } ?? "-") box=\(box(heart)) inApp=\(heart?.plugin?.inApp ?? "-") update=\(heart?.update != nil)")
            print("TEMPLATE-EMAIL formats=\(email?.plugin?.formats ?? []) dark=\(email?.plugin?.hasDark ?? false)")
            if let ring, let png = store.image(for: ring)?.pngData() { print("TEMPLATE-RING-PNG \(png.base64EncodedString())") }
            let ringBox = ring?.inkBox ?? .zero
            let ringOK = ring?.kind == .svg && abs(ringBox.minX - 2) < 0.7 && abs(ringBox.maxX - 22) < 0.7 && abs(ringBox.minY - 2) < 0.7
            if !result.fromTemplate || result.added != 1 || result.updated != 2 || result.changedKept != 0 || !ringOK
                || ring?.plugin?.inApp != "tpl_ring.svg" || heart?.plugin?.inApp != "heart_filled.svg" || heart?.update != nil
                || email?.plugin?.hasDark != true { failures += 1 }

            store.fillPending()
            let summary = try await PluginExporter.export(store, options: CaptureExportOptions()) { _, _ in }
            let zipData = try Data(contentsOf: summary.url)
            let zip = try ZipReader(data: zipData)
            let paths = zip.entries.map(\.path).sorted()
            let manifestData = try zip.entry("manifest.json").map { try zip.read($0) } ?? Data()
            let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
            let files = manifest?["files"] as? [[String: Any]] ?? []
            let heartEntry = files.first { $0["path"] as? String == "svg/heart_filled.svg" }
            print("TEMPLATE-EXPORT paths=\(paths) wechat=\(manifest?["wechat"] ?? "-") files=\(files.count) heart=\(heartEntry ?? [:]) skipped=\(summary.skipped.map(\.reason))")
            print("TEMPLATE-ZIP-BASE64 \(zipData.base64EncodedString())")
            let expected = ["manifest.json", "png-dark/AS_Email@3x.png", "png/AS_Email@3x.png", "svg/arrow_right_regular.svg", "svg/heart_filled.svg"]
            if paths != expected || manifest?["wechat"] as? String != "8.0.80" || files.count != 4
                || heartEntry?["inApp"] as? String != "heart_filled.svg" || heartEntry?["width"] as? Int != 24 { failures += 1 }
        } catch {
            print("TEMPLATE-ERROR \(error.localizedDescription)")
            failures += 1
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: store.backupsFolder)
        return failures
    }

    /// Global sizing: one point size per canvas size in `optical` (a circle
    /// covering the set share), slim canvases on the original's area, wide
    /// symbols kept inside the canvas, per-icon nudges, and the exported plan
    /// placing every icon where the app does.
    private static func sizingTest() async -> Int {
        var failures = 0
        print("=== SIZING")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SizingSelfTest", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        guard let data = Data(base64Encoded: captureZip) else { return 1 }
        let store = CaptureStore(root: root)
        func rect(_ output: (pdf: Data, drawing: VectorDrawing, layout: SVGLayout)?) -> CGRect {
            output.map { $0.drawing.bounds.applying($0.layout.transform) } ?? .null
        }
        func text(_ r: CGRect) -> String {
            [r.minX, r.minY, r.width, r.height].map { SVGWriter.number($0) }.joined(separator: ",")
        }
        func check(_ label: String, _ ok: Bool, _ detail: String) {
            print("SIZING-\(label) \(detail)\(ok ? "" : " FAILED")")
            if !ok { failures += 1 }
        }
        do {
            _ = try await store.importCapture(data, merge: false)
            check("DEFAULT", GlobalStyle().sizeMode == .original, GlobalStyle().sizeMode.rawValue)
            var opticalStyle = GlobalStyle()
            opticalStyle.sizeMode = .optical
            store.setGlobal(opticalStyle)
            store.fillPending()
            guard let heart = store.icons.first(where: { $0.name == "heart_filled" }),
                  let email = store.icons.first(where: { $0.name == "AS_Email" }),
                  let arrow = store.icons.first(where: { $0.name == "arrow_right_regular" }) else {
                print("SIZING-ERROR test icons missing")
                return 1
            }
            func geometry(_ icon: CaptureIcon) -> IconGeometry {
                let choice = store.choice(for: icon)
                return store.geometry(for: icon, choice: choice, look: store.effectiveLook(for: icon, choice: choice))
            }
            let g1 = geometry(heart), g2 = geometry(email), g3 = geometry(arrow)
            check("GEOMETRY", g1.sizing == .optical && g1.fit == .natural && abs(g2.pointSize / g1.pointSize - 32.0 / 24) < 0.01
                    && g3.sizing == .original && g3.fit == .contain,
                  "heart=\(g1.sizing) \(SVGWriter.number(g1.pointSize)) email=\(g2.sizing) \(SVGWriter.number(g2.pointSize)) arrow=\(g3.sizing) \(SVGWriter.number(g3.pointSize)) box=\(text(g3.box))")

            var circle = store.choice(for: heart)
            circle.symbol = "circle.fill"
            let round = rect(store.renderReplacement(for: heart, choice: circle))
            check("CIRCLE", abs(round.height - 19.2) < 0.4 && abs(round.midX - 12) < 0.05 && abs(round.midY - 12) < 0.05, text(round))

            var wide = circle
            wide.symbol = "person.3.sequence.fill"
            let wideRect = rect(store.renderReplacement(for: heart, choice: wide))
            check("WIDE", wideRect.minX >= 0.9 && wideRect.maxX <= 23.1 && wideRect.width > 20, text(wideRect))

            var nudged = circle
            nudged.adjust = IconAdjust(scale: 1.1, dx: 0.1, dy: -0.05)
            let moved = rect(store.renderReplacement(for: heart, choice: nudged))
            check("NUDGE", abs(moved.height - 21.12) < 0.45 && abs(moved.midX - 14.4) < 0.05 && abs(moved.midY - 10.8) < 0.05, text(moved))

            // The same font size for every symbol: a plus is smaller than a circle.
            var plus = circle
            plus.symbol = "plus"
            let plusRect = rect(store.renderReplacement(for: heart, choice: plus))
            check("PLUS", plusRect.height < round.height - 1, text(plusRect))

            // The exported plan puts every icon where the app does.
            func checkPlan() throws {
                let options = CaptureExportOptions()
                let plan = store.resolvedPlan(options)
                let reread = try IconPlan.decode(store.planJSON(options)).resolve()
                var planOK = reread.errorCount == 0 && reread.icons.count == plan.icons.count
                for icon in reread.icons {
                    guard let original = store.icons.first(where: { $0.name == icon.names[0] }),
                          let choice = store.choices[original.name],
                          let render = SymbolPipeline.renderDrawing(name: icon.symbol, style: icon.style(for: .light)) else { planOK = false; continue }
                    let layout = SVGWriter.layout(for: render.drawing, frame: render.frame, width: icon.canvas.width,
                                                  height: icon.canvas.height, padding: icon.padding, fit: icon.fit, box: icon.box)
                    let fromPlan = render.drawing.bounds.applying(layout.transform)
                    let inApp = rect(store.renderReplacement(for: original, choice: choice))
                    let same = abs(fromPlan.minX - inApp.minX) < 0.1 && abs(fromPlan.minY - inApp.minY) < 0.1
                        && abs(fromPlan.width - inApp.width) < 0.1 && abs(fromPlan.height - inApp.height) < 0.1
                    print("SIZING-PLAN \(store.global.sizeMode.rawValue) \(original.name) fit=\(icon.fit.rawValue) pointSize=\(SVGWriter.number(icon.pointSize)) plan=\(text(fromPlan)) app=\(text(inApp))\(same ? "" : " FAILED")")
                    if !same { planOK = false }
                }
                for issue in reread.issues { print("SIZING-JSON-ISSUE \(issue.severity) \(issue.icon ?? "-"): \(issue.message)") }
                if !planOK { failures += 1 }
            }
            try checkPlan()

            var uniform = store.global
            uniform.sizeMode = .uniform
            store.setGlobal(uniform)
            let uniformWide = rect(store.renderReplacement(for: heart, choice: wide))
            let uniformPlus = rect(store.renderReplacement(for: heart, choice: plus))
            check("UNIFORM", abs(max(uniformWide.width, uniformWide.height) - 19.2) < 0.05
                    && abs(max(uniformPlus.width, uniformPlus.height) - 19.2) < 0.05,
                  "wide=\(text(uniformWide)) plus=\(text(uniformPlus))")

            var original = store.global
            original.sizeMode = .original
            store.setGlobal(original)
            // The same area as the original's visible pixels, on its center, inside the canvas.
            let ink = heart.inkBox ?? .null
            let fitted = rect(store.renderReplacement(for: heart, choice: circle))
            let wideFitted = rect(store.renderReplacement(for: heart, choice: wide))
            check("ORIGINAL", abs(fitted.midX - ink.midX) < 0.05 && abs(fitted.midY - ink.midY) < 0.05
                    && abs((fitted.width * fitted.height) / (ink.width * ink.height) - 1) < 0.02
                    && wideFitted.minX >= -0.05 && wideFitted.maxX <= 24.05 && wideFitted.width > ink.width,
                  "ink=\(text(ink)) circle=\(text(fitted)) wide=\(text(wideFitted))")
            try checkPlan()

            // A sheet of symbols in each mode, for looking at.
            for mode in IconSizing.allCases {
                var style = store.global
                style.sizeMode = mode
                store.setGlobal(style)
                for symbol in ["heart.fill", "plus", "person.3.sequence.fill", "gearshape.fill", "chevron.right", "ellipsis", "bell.fill", "camera.fill"] {
                    var choice = circle
                    choice.symbol = symbol
                    guard let output = store.renderReplacement(for: heart, choice: choice) else { continue }
                    let svg = SVGWriter.svg(output.drawing, layout: output.layout, title: symbol, background: nil)
                    print("SIZING-SVG \(mode.rawValue) \(symbol) \(Data(svg.utf8).base64EncodedString())")
                }
            }

            // Old saved sizes move into the per-icon nudge.
            var legacy = store.choice(for: heart)
            legacy.followsGlobal = false
            legacy.look.size = 1.2
            legacy.adjust = nil
            store.setChoice(legacy, for: heart)
            try await Task.sleep(nanoseconds: 600_000_000)
            let reopened = CaptureStore(root: root)
            let migrated = reopened.choices["heart_filled"]
            check("MIGRATE", migrated?.look.size == 1 && abs((migrated?.adjust?.scale ?? 0) - 1.2) < 0.001,
                  "size=\(migrated?.look.size ?? -1) scale=\(migrated?.adjust?.scale ?? -1)")
        } catch {
            print("SIZING-ERROR \(error.localizedDescription)")
            failures += 1
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: store.backupsFolder)
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent().appendingPathComponent("CaptureStyle.json"))
        return failures
    }

    /// Exports a scheme in progress with and without its originals, opens it
    /// in an empty project, then merges it into a project with settings of
    /// its own, keeping them and then overwriting them, and undoes that.
    private static func schemeTest() async -> Int {
        var failures = 0
        print("=== SCHEME export and import")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SchemeSelfTest", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        // Each store in its own folder, so their global styles and backups stay apart.
        func root(_ name: String) -> URL { base.appendingPathComponent(name, isDirectory: true).appendingPathComponent("Capture", isDirectory: true) }
        func check(_ label: String, _ ok: Bool, _ detail: String) {
            print("SCHEME-\(label) \(detail)\(ok ? "" : " FAILED")")
            if !ok { failures += 1 }
        }
        guard let data = Data(base64Encoded: captureZip) else { return 1 }
        do {
            let a = CaptureStore(root: root("A"))
            _ = try await a.importCapture(data, merge: false)
            var style = GlobalStyle(look: (LookPreset.named("sunset") ?? LookPreset.all[1]).look(for: nil))
            style.sizeMode = .optical
            a.setGlobal(style)
            a.fillPending()
            guard let heart = a.icons.first(where: { $0.name == "heart_filled" }),
                  let arrow = a.icons.first(where: { $0.name == "arrow_right_regular" }) else {
                print("SCHEME-ERROR test icons missing")
                return 1
            }
            var heartChoice = a.choice(for: heart)
            heartChoice.symbol = "heart.circle.fill"
            heartChoice.adjust = IconAdjust(scale: 1.2, dx: 0.05, dy: 0)
            heartChoice.manual = true
            a.setChoice(heartChoice, for: heart)
            var arrowChoice = a.choice(for: arrow)
            arrowChoice.replace = false
            arrowChoice.manual = true
            a.setChoice(arrowChoice, for: arrow)

            let fullData = try Data(contentsOf: a.exportScheme(name: "测试方案", note: "自检", includeOriginals: true))
            let lightData = try Data(contentsOf: a.exportScheme(name: "只有设置", note: nil, includeOriginals: false))
            let fullPaths = try ZipReader(data: fullData).entries.map(\.path).sorted()
            let lightPaths = try ZipReader(data: lightData).entries.map(\.path).sorted()
            let notScheme = try SchemePackage.read(data) == nil
            check("EXPORT", fullPaths.count == 4 && fullPaths.first == "icons/AS_Email.png" && lightPaths == ["scheme.json"] && notScheme,
                  "full=\(fullPaths) light=\(lightPaths) captureIsScheme=\(!notScheme)")
            guard let full = try SchemePackage.read(fullData), let light = try SchemePackage.read(lightData) else {
                print("SCHEME-ERROR exported schemes do not read back")
                return failures + 1
            }

            // An empty project opens the scheme with its originals.
            let b = CaptureStore(root: root("B"))
            let opened = try b.importScheme(full, options: SchemeImportOptions())
            let images = b.icons.allSatisfy { b.image(for: $0) != nil }
            check("OPEN", b.icons.count == 3 && opened.addedIcons == 3 && b.choices == a.choices && b.global == a.global && images,
                  "icons=\(b.icons.count) applied=\(opened.applied) sameChoices=\(b.choices == a.choices) sameGlobal=\(b.global == a.global) images=\(images)")
            if let heartB = b.icons.first(where: { $0.name == "heart_filled" }), let choiceB = b.choices["heart_filled"] {
                let inA = a.renderReplacement(for: heart, choice: heartChoice).map { $0.drawing.bounds.applying($0.layout.transform) } ?? .null
                let inB = b.renderReplacement(for: heartB, choice: choiceB).map { $0.drawing.bounds.applying($0.layout.transform) } ?? .null
                check("SAME-RENDER", abs(inA.minX - inB.minX) < 0.01 && abs(inA.width - inB.width) < 0.01 && abs(inA.height - inB.height) < 0.01,
                      "a=\(inA) b=\(inB)")
            }

            // Without originals, an empty project cannot take it.
            let empty = CaptureStore(root: root("D"))
            var refused = false
            do { try empty.importScheme(light, options: SchemeImportOptions()) } catch { refused = true }
            check("NEEDS-ORIGINALS", refused && empty.project == nil, "refused=\(refused)")

            // A project with a setting of its own.
            let c = CaptureStore(root: root("C"))
            _ = try await c.importCapture(data, merge: false)
            guard let heartC = c.icons.first(where: { $0.name == "heart_filled" }) else { return failures + 1 }
            var own = c.choice(for: heartC)
            own.replace = true
            own.symbol = "star.fill"
            own.manual = true
            c.setChoice(own, for: heartC)
            let globalC = c.global
            let summary = c.schemeSummary(light)
            var keep = SchemeImportOptions()
            keep.useGlobal = false
            let first = try c.importScheme(light, options: keep)
            let kept = c.choices["heart_filled"] == own && c.choices["AS_Email"] == a.choices["AS_Email"]
                && c.choices["arrow_right_regular"] == arrowChoice && c.global == globalC
            check("MERGE-KEEP", summary.fills == 2 && summary.conflicts == 1 && summary.newIcons == 0 && first.applied == 2 && kept,
                  "fills=\(summary.fills) conflicts=\(summary.conflicts) same=\(summary.same) applied=\(first.applied) kept=\(kept)")
            var overwrite = SchemeImportOptions()
            overwrite.overwrite = true
            let second = try c.importScheme(light, options: overwrite)
            check("MERGE-OVERWRITE", second.applied == 1 && c.choices == a.choices && c.global == a.global,
                  "applied=\(second.applied) sameChoices=\(c.choices == a.choices) sameGlobal=\(c.global == a.global)")
            let latest = c.backups().first
            if let latest { try c.restore(latest) }
            check("UNDO", c.choices["heart_filled"] == own && c.global == globalC, "backup=\(latest?.reason ?? "-")")
        } catch {
            print("SCHEME-ERROR \(error.localizedDescription)")
            failures += 1
        }
        try? FileManager.default.removeItem(at: base)
        return failures
    }

    /// Draws the first suggested symbol of every bundled WeChat resource in the
    /// default global look: each must exist and render. The drawings (cropped
    /// to their painted area, at 64 pt) are printed for comparison sheets.
    private static func suggestionTest() -> Int {
        print("=== SUGGESTIONS")
        let book = SuggestionBook.bundled()
        let look = GlobalStyle().look
        var drawn = Set<String>()
        var failed: [String] = []
        var kept = 0
        var icons = 0
        for name in book.items.keys.sorted() where book.items[name]?.decorative != true {
            guard let symbol = book.symbols(for: name).first else { continue }
            icons += 1
            print("SUGGEST-ICON \(name) \(symbol)")
            guard drawn.insert(symbol).inserted else { continue }
            guard let render = SymbolPipeline.renderDrawing(name: symbol, style: look.style(pointSize: 64)) else {
                failed.append(symbol)
                continue
            }
            let bounds = render.drawing.bounds
            let layout = SVGLayout(width: bounds.width, height: bounds.height,
                                   transform: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            let svg = SVGWriter.svg(render.drawing, layout: layout, title: symbol, background: nil)
            if svg.contains("<mask") || svg.contains("clip-path=") { kept += 1 }
            print("SUGGEST-SVG \(symbol) \(Data(svg.utf8).base64EncodedString())")
        }
        let circle = SymbolPipeline.renderDrawing(name: "circle.fill", style: look.style(pointSize: 64))?.drawing.bounds
        print("SUGGEST-CIRCLE \(circle.map { SVGWriter.number($0.height) } ?? "-")")
        print("SUGGEST-DONE icons=\(icons) symbols=\(drawn.count) failed=\(failed) withMasks=\(kept)\(failed.isEmpty ? "" : " FAILED")")
        return failed.isEmpty && circle != nil ? 0 : 1
    }

    /// A plugin template like the plugin exports: version 8.0.80, a new SVG
    /// resource, an SVG for heart_filled, and AS_Email as a bitmap with a dark copy.
    private static func pluginTemplate(from captureData: Data) throws -> Data {
        let capture = try ZipReader(data: captureData)
        guard let email = capture.entries.first(where: { $0.path.hasSuffix("AS_Email_32x32@3x.png") }) else {
            throw StudioError.resource("test capture has no AS_Email")
        }
        let emailPNG = try capture.read(email)
        let ring = """
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">\
        <path fill-rule="evenodd" clip-rule="evenodd" d="M12 2a10 10 0 1 1 0 20a10 10 0 1 1 0-20zm0 4a6 6 0 1 0 0 12A6 6 0 1 0 12 6z" fill="#000"/>\
        <g transform="translate(12 12) rotate(45)"><rect x="-1" y="-9" width="2" height="18" rx="1" fill="black" fill-opacity=".5"/></g></svg>
        """
        let heart = """
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">\
        <rect x="2.7" y="4.7" width="18.6" height="16" rx="4" fill="#000"/></svg>
        """
        let manifest: [String: Any] = [
            "wechat": "8.0.80", "plan": "wechat-original-template", "generated": "test", "note": "test",
            "files": [
                ["format": "svg", "appearance": "light", "path": "svg/tpl_ring.svg", "icon": "tpl_ring", "width": 24, "height": 24, "inApp": "tpl_ring.svg"],
                ["format": "svg", "appearance": "light", "path": "svg/heart_filled.svg", "icon": "heart_filled", "width": 24, "height": 24, "inApp": "heart_filled.svg"],
                ["format": "png", "appearance": "light", "path": "png/AS_Email@3x.png", "icon": "AS_Email", "width": 32, "height": 32, "scale": 3, "mode": "original"],
                ["format": "png", "appearance": "dark", "path": "png-dark/AS_Email@3x.png", "icon": "AS_Email", "width": 32, "height": 32, "scale": 3]
            ] as [[String: Any]]
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-template-test.zip")
        try? FileManager.default.removeItem(at: url)
        let writer = try ZipWriter(url: url)
        try writer.add(path: "svg/tpl_ring.svg", data: Data(ring.utf8))
        try writer.add(path: "svg/heart_filled.svg", data: Data(heart.utf8))
        try writer.add(path: "png/AS_Email@3x.png", data: emailPNG)
        try writer.add(path: "png-dark/AS_Email@3x.png", data: emailPNG)
        try writer.add(path: "manifest.json", data: JSONSerialization.data(withJSONObject: manifest))
        try writer.finish()
        return try Data(contentsOf: url)
    }

    /// The test capture as a newer WeChat would give it: version 8.0.80,
    /// heart_filled requested at 48×48, and an icon that was not there before.
    private static func newerCapture(from data: Data) throws -> Data {
        let reader = try ZipReader(data: data)
        guard let manifestEntry = reader.entries.first(where: { $0.path.hasSuffix("manifest.json") }),
              var manifest = try JSONSerialization.jsonObject(with: reader.read(manifestEntry)) as? [String: Any],
              var icons = manifest["icons"] as? [[String: Any]] else {
            throw StudioError.resource("test manifest is missing")
        }
        manifest["app"] = ["version": "8.0.80"]
        for index in icons.indices where icons[index]["name"] as? String == "heart_filled" {
            icons[index]["renderSize"] = ["w": 48, "h": 48, "unit": "pt"] as [String: Any]
        }
        if var extra = icons.first(where: { $0["name"] as? String == "arrow_right_regular" }) {
            extra["name"] = "new_icon_test"
            icons.append(extra)
        }
        manifest["icons"] = icons
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("newer-capture.zip")
        try? FileManager.default.removeItem(at: url)
        let writer = try ZipWriter(url: url)
        for entry in reader.entries where entry.path != manifestEntry.path && !entry.isDirectory {
            try writer.add(path: entry.path, data: reader.read(entry))
        }
        try writer.add(path: manifestEntry.path, data: JSONSerialization.data(withJSONObject: manifest))
        try writer.finish()
        return try Data(contentsOf: url)
    }

    /// heart_filled, arrow_right_regular and AS_Email from a real capture, zipped with deflate.
    private static let captureZip = "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"

    /// Every preset on symbols with layers, gaps and multicolor parts, at an
    /// icon-sized canvas: the SVG must be plain paths, with no mask or clip.
    private static func presetFlatTest() -> Int {
        var failures = 0
        print("=== PRESET plain SVG")
        let symbols = ["safari.fill", "person.2.fill", "square.and.pencil", "folder.badge.plus", "bell.slash.fill", "camera.aperture"]
        for preset in LookPreset.all {
            for symbol in symbols {
                guard let render = SymbolPipeline.renderDrawing(name: symbol, style: preset.look(for: nil).style(pointSize: 64)) else {
                    print("PRESET \(preset.id) \(symbol) render failed")
                    failures += 1
                    continue
                }
                let layout = SVGWriter.layout(for: render.drawing, frame: render.frame, width: 24, height: 24, padding: 0.1, fit: .contain)
                let svg = SVGWriter.svg(render.drawing, layout: layout, title: symbol, background: nil)
                let masks = svg.components(separatedBy: "<mask").count - 1
                let clips = svg.components(separatedBy: "clip-path=").count - 1
                if masks + clips > 0 || render.drawing.isIncomplete {
                    print("PRESET \(preset.id) \(symbol) masks=\(masks) clips=\(clips) raster=\(render.drawing.rasterImages) FAILED")
                    print("SVG-BEGIN")
                    print(svg, terminator: "")
                    print("SVG-END")
                    failures += 1
                }
            }
        }
        print("PRESET checked \(LookPreset.all.count * symbols.count) combinations")
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
