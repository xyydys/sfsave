import Foundation
import UIKit

/// Writes the replaced icons in the icon-replacement plugin's layout, the
/// same as its template: `png/name@3x.png`, `png-dark/name@3x.png` for
/// resources that have a dark bitmap, `svg/name.svg`, and a `manifest.json`
/// with `wechat` and one entry per file (`icon`, `format`, `appearance`,
/// `path`, `width`, `height`, plus `scale` for PNG and `inApp` for SVG).
@MainActor
enum PluginExporter {
    static func export(_ store: CaptureStore, options: CaptureExportOptions,
                       progress: (Int, Int) -> Void) async throws -> BatchSummary {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let stamp = formatter.string(from: Date())
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SymbolStudio-exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let zip = try ZipWriter(url: folder.appendingPathComponent("wechat-icons-\(stamp).zip"))
        var files: [[String: Any]] = []
        var skipped: [BatchSummary.Skipped] = []
        var exported = 0
        let targets: [(icon: CaptureIcon, choice: IconChoice)] = store.icons.compactMap { icon in
            guard let choice = store.choices[icon.name], choice.replace else { return nil }
            return (icon, choice)
        }

        do {
            for (position, target) in targets.enumerated() {
                progress(position, targets.count)
                await Task.yield()
                let icon = target.icon, choice = target.choice
                guard UIImage(systemName: choice.symbol) != nil else {
                    skipped.append(.init(icon: icon.name, reason: "这个系统里没有符号 “\(choice.symbol)”。"))
                    continue
                }
                guard let render = store.renderReplacement(for: icon, choice: choice) else {
                    skipped.append(.init(icon: icon.name, reason: "系统没能画出符号 “\(choice.symbol)”。"))
                    continue
                }
                let layout = render.layout
                let formats = icon.plugin?.formats ?? [icon.kind == .bitmap ? "png" : "svg"]
                let width = number(icon.canvas.width), height = number(icon.canvas.height)

                if formats.contains("svg") {
                    let path = "svg/\(icon.name).svg"
                    let svg = SVGWriter.svg(render.drawing, layout: layout, title: icon.name, background: nil)
                    try zip.add(path: path, data: Data(svg.utf8))
                    files.append(["format": "svg", "appearance": "light", "path": path, "icon": icon.name,
                                  "width": width, "height": height, "inApp": icon.plugin?.inApp ?? icon.name + ".svg"])
                }
                if formats.contains("png") {
                    guard let png = SymbolPipeline.rasterize(pdf: render.pdf, layout: layout, pixelScale: 3, background: nil) else {
                        skipped.append(.init(icon: icon.name, reason: "PNG 生成失败。"))
                        continue
                    }
                    var folders = [("png", "light")]
                    if icon.plugin?.hasDark == true { folders.append(("png-dark", "dark")) }
                    for (directory, appearance) in folders {
                        let path = "\(directory)/\(icon.name)@3x.png"
                        try zip.add(path: path, data: png)
                        files.append(["format": "png", "appearance": appearance, "path": path, "icon": icon.name,
                                      "width": width, "height": height, "scale": 3, "mode": "replaced"])
                    }
                }
                exported += 1
            }
            progress(targets.count, targets.count)
            let manifest: [String: Any] = [
                "wechat": store.project?.appVersion ?? "",
                "files": files,
                "plan": "symbolstudio",
                "generated": stamp,
                "note": "符号工坊导出的替换图标，目录和字段与替换插件的模板相同，只包含要替换的图标。"
            ]
            try zip.add(path: "manifest.json",
                        data: JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            try zip.finish()
        } catch {
            zip.cancel()
            throw error
        }
        return BatchSummary(url: zip.url, fileCount: files.count, iconCount: exported, skipped: skipped)
    }

    /// Whole numbers as integers, like the template writes them.
    private static func number(_ value: CGFloat) -> Any {
        value == value.rounded() && abs(value) < 1_000_000 ? Int(value) : Double(value)
    }
}
