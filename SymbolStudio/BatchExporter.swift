import CoreGraphics
import Foundation

/// Which file types a batch export writes.
enum BatchFormats: String, CaseIterable, Identifiable {
    case plan, png, svg, both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan: return "按方案"
        case .png: return "仅 PNG"
        case .svg: return "仅 SVG"
        case .both: return "PNG + SVG"
        }
    }

    /// `nil` means every icon uses the formats its plan entry lists.
    var override: Set<PlanFormat>? {
        switch self {
        case .plan: return nil
        case .png: return [.png]
        case .svg: return [.svg]
        case .both: return [.png, .svg]
        }
    }
}

struct BatchOptions {
    var formats = BatchFormats.plan
    var includeDark = true

    func formats(for icon: ResolvedIcon) -> Set<PlanFormat> { formats.override ?? Set(icon.formats) }
}

extension ResolvedPlan {
    func fileCount(_ options: BatchOptions) -> Int {
        icons.reduce(0) { $0 + $1.outputPaths(naming, formats: options.formats(for: $1), includeDark: options.includeDark).count }
    }
}

struct BatchSummary {
    struct Skipped: Codable {
        let icon: String
        let reason: String
    }

    let url: URL
    let fileCount: Int
    let iconCount: Int
    var skipped: [Skipped]
}

private struct ManifestFile: Codable {
    let path: String
    let icon: String
    let symbol: String
    let appearance: String
    let format: String
    let scale: Int?
    let width: Int
    let height: Int
}

private struct Manifest: Codable {
    let plan: String
    let generated: String
    let files: [ManifestFile]
    let skipped: [BatchSummary.Skipped]
}

/// Renders every icon of a plan and packs the results into one zip:
/// `name.png`, `name@2x.png`, `name_dark@2x.png`, `svg/name.svg`, … plus
/// a `manifest.json` that lists each file and anything that was skipped.
@MainActor
enum BatchExporter {
    /// `extras` are added to the zip as they are, e.g. `["plan.json": data]`.
    static func export(_ plan: ResolvedPlan, options: BatchOptions, extras: [String: Data] = [:],
                       progress: (Int, Int) -> Void) async throws -> BatchSummary {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SymbolStudio-exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let safeName = plan.name.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "_" }.joined()
        let zip = try ZipWriter(url: folder.appendingPathComponent((safeName.isEmpty ? "icons" : safeName) + ".zip"))
        var files: [ManifestFile] = []
        var skipped: [BatchSummary.Skipped] = []
        var exported = 0

        do {
            for (position, icon) in plan.icons.enumerated() {
                progress(position, plan.icons.count)
                await Task.yield()
                let label = icon.names[0]
                let formats = options.formats(for: icon)
                var wroteAny = false

                for appearance in icon.appearances where options.includeDark || appearance == .light {
                    guard let render = SymbolPipeline.renderDrawing(name: icon.symbol, style: icon.style(for: appearance)) else {
                        skipped.append(.init(icon: label, reason: "系统没能画出符号 “\(icon.symbol)”（\(appearance.rawValue)）。"))
                        continue
                    }
                    let layout = SVGWriter.layout(for: render.drawing, frame: render.frame,
                                                  width: icon.canvas.width, height: icon.canvas.height,
                                                  padding: icon.padding, fit: icon.fit, box: icon.box)

                    if formats.contains(.png) {
                        for scale in icon.scales {
                            guard let png = SymbolPipeline.rasterize(pdf: render.pdf, layout: layout,
                                                                    pixelScale: CGFloat(scale), background: icon.background) else {
                                skipped.append(.init(icon: label, reason: "PNG 生成失败（\(appearance.rawValue) @\(scale)x）。"))
                                continue
                            }
                            for name in icon.names {
                                let path = plan.naming.pngPath(name, appearance, scale: scale)
                                guard !zip.contains(path) else {
                                    skipped.append(.init(icon: name, reason: "文件名重复，已跳过：\(path)"))
                                    continue
                                }
                                try zip.add(path: path, data: png)
                                files.append(ManifestFile(path: path, icon: name, symbol: icon.symbol,
                                                          appearance: appearance.rawValue, format: "png", scale: scale,
                                                          width: Int((layout.width * CGFloat(scale)).rounded()),
                                                          height: Int((layout.height * CGFloat(scale)).rounded())))
                                wroteAny = true
                            }
                        }
                    }

                    if formats.contains(.svg) {
                        for name in icon.names {
                            let path = plan.naming.svgPath(name, appearance)
                            guard !zip.contains(path) else {
                                skipped.append(.init(icon: name, reason: "文件名重复，已跳过：\(path)"))
                                continue
                            }
                            let svg = SVGWriter.svg(render.drawing, layout: layout, title: name, background: icon.background)
                            try zip.add(path: path, data: Data(svg.utf8))
                            files.append(ManifestFile(path: path, icon: name, symbol: icon.symbol,
                                                      appearance: appearance.rawValue, format: "svg", scale: nil,
                                                      width: Int(layout.width.rounded()), height: Int(layout.height.rounded())))
                            wroteAny = true
                        }
                    }
                }
                if wroteAny { exported += 1 }
            }
            progress(plan.icons.count, plan.icons.count)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let manifest = Manifest(plan: plan.name, generated: ISO8601DateFormatter().string(from: Date()),
                                    files: files, skipped: skipped)
            try zip.add(path: "manifest.json", data: try encoder.encode(manifest))
            for (path, data) in extras.sorted(by: { $0.key < $1.key }) where !zip.contains(path) {
                try zip.add(path: path, data: data)
            }
            try zip.finish()
        } catch {
            zip.cancel()
            throw error
        }
        return BatchSummary(url: zip.url, fileCount: files.count, iconCount: exported, skipped: skipped)
    }
}
