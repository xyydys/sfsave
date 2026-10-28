import Foundation
import ImageIO
import SwiftUI
import UIKit

struct CaptureProject: Codable {
    var appVersion: String?
    var device: String?
    var imported: Date
    var icons: [CaptureIcon]
    var imports: [CaptureImportRecord]? = nil

    /// Every import so far; projects saved before imports were recorded count as one.
    var history: [CaptureImportRecord] {
        imports ?? [CaptureImportRecord(version: appVersion, date: imported, added: icons.count, updated: 0)]
    }
}

struct CaptureImportRecord: Codable {
    var version: String?
    var date: Date
    var added: Int
    var updated: Int
}

struct CaptureImportSummary {
    var version: String?
    var added: Int
    var updated: Int
    /// Replaced icons whose new capture differs; set aside, not applied.
    var changedKept: Int
    var skipped: [String]
    /// The zip was the replacement plugin's template.
    var fromTemplate = false
}

struct CaptureBackup: Identifiable {
    let url: URL
    let date: Date
    let reason: String
    let count: Int
    var id: URL { url }
}

/// The icon-replacement plugin's template: `manifest.json` listing
/// `png/name@3x.png`, `png-dark/name@3x.png` and `svg/name.svg`.
struct PluginTemplate: Decodable {
    struct File: Decodable {
        var icon: String
        var path: String
        var format: String
        var appearance: String?
        var width: Double?
        var height: Double?
        var inApp: String?
    }

    var wechat: String?
    var files: [File]
}

/// Reads a WeChatIconCapture zip (`manifest.json` plus one PNG per capture)
/// or the icon-replacement plugin's template zip.
enum CaptureImporter {
    struct Imported {
        var icon: CaptureIcon
        var png: Data
        /// The resource's own SVG, from a plugin template.
        var svg: Data? = nil
    }

    struct Result {
        var appVersion: String?
        var device: String?
        var icons: [Imported]
        var skipped: [String]
        var isTemplate = false
    }

    static func read(zip data: Data) throws -> Result {
        let zip = try ZipReader(data: data)
        guard let manifestEntry = zip.entries
            .filter({ $0.path == "manifest.json" || $0.path.hasSuffix("/manifest.json") })
            .min(by: { $0.path.count < $1.path.count }) else {
            throw StudioError.resource("zip 里没有 manifest.json。请导入抓图工具或替换插件导出的 zip。")
        }
        let base = String(manifestEntry.path.dropLast("manifest.json".count))
        let manifestData = try zip.read(manifestEntry)
        if let template = try? JSONDecoder().decode(PluginTemplate.self, from: manifestData),
           !template.files.isEmpty, template.wechat != nil || template.files.contains(where: { $0.inApp != nil }) {
            return try readTemplate(template, zip: zip, base: base)
        }
        let manifest: CaptureManifest
        do { manifest = try JSONDecoder().decode(CaptureManifest.self, from: manifestData) }
        catch { throw StudioError.resource("manifest.json 读不懂：\(error.localizedDescription)") }

        var groups: [String: [CaptureManifest.Entry]] = [:]
        var order: [String] = []
        for entry in manifest.icons {
            let name = resourceName(entry.name)
            guard !name.isEmpty, IconPlan.isValidPath(name), !name.contains("/") else { continue }
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(entry)
        }

        var icons: [Imported] = []
        var skipped: [String] = []
        for name in order {
            let entries = groups[name] ?? []
            func area(_ entry: CaptureManifest.Entry) -> Double {
                let size = entry.renderSize ?? entry.imageSize
                return (size?.w ?? 0) * (size?.h ?? 0)
            }
            guard let best = entries.max(by: { area($0) < area($1) }),
                  let file = zip.entry(base + best.file), let png = try? zip.read(file),
                  let canvas = (best.renderSize ?? best.imageSize)?.cgSize, canvas.width > 0, canvas.height > 0 else {
                skipped.append(name)
                continue
            }
            var sizes: [CGSize] = []
            var colors: [String] = []
            var angles: [Double] = []
            var colorCounts: [String: Int] = [:]
            for entry in entries {
                if let size = (entry.renderSize ?? entry.imageSize)?.cgSize, !sizes.contains(size) { sizes.append(size) }
                if let color = entry.color?.uppercased(), RGBA(hex: color) != nil { colorCounts[color, default: 0] += 1 }
                if let angle = entry.angle, angle != 0, !angles.contains(angle) { angles.append(angle) }
            }
            colors = colorCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
            sizes.sort { $0.width * $0.height < $1.width * $1.height }
            let kind: CaptureIcon.Kind = best.type == "bitmap" ? .bitmap : (colors.isEmpty ? .colorful : .svg)
            let icon = CaptureIcon(name: name, kind: kind, sizes: sizes, colors: colors, angles: angles,
                                   image: "", canvas: canvas, inkBox: inkBox(png, canvas: canvas), captures: entries.count)
            icons.append(Imported(icon: icon, png: png))
        }
        if icons.isEmpty { throw StudioError.resource("manifest.json 里没有能读出来的图标。") }
        let device = [manifest.device?.model, manifest.device?.systemVersion.map { "iOS " + $0 }]
            .compactMap { $0 }.joined(separator: " ")
        return Result(appVersion: manifest.app?.version, device: device.isEmpty ? nil : device,
                      icons: icons, skipped: skipped)
    }

    private static func readTemplate(_ template: PluginTemplate, zip: ZipReader, base: String) throws -> Result {
        var groups: [String: [PluginTemplate.File]] = [:]
        var order: [String] = []
        for file in template.files {
            let name = resourceName(file.icon)
            guard !name.isEmpty, IconPlan.isValidPath(name), !name.contains("/") else { continue }
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(file)
        }
        var icons: [Imported] = []
        var skipped: [String] = []
        for name in order {
            let files = groups[name] ?? []
            let light = files.filter { $0.appearance != "dark" }
            let png = light.first { $0.format == "png" }
            let svg = light.first { $0.format == "svg" }
            guard let source = svg ?? png ?? files.first, let width = source.width, let height = source.height,
                  width > 0, height > 0 else {
                skipped.append(name)
                continue
            }
            let size = CGSize(width: width, height: height)
            let svgData = svg.flatMap { zip.entry(base + $0.path) }.flatMap { try? zip.read($0) }
            var preview = png.flatMap { zip.entry(base + $0.path) }.flatMap { try? zip.read($0) }
            var colors: [String] = []
            var kind = CaptureIcon.Kind.bitmap
            if let svgData {
                colors = svgColors(svgData)
                kind = colors.count > 1 || colors.contains(where: { $0 != "#000000" && $0 != "#FFFFFF" }) ? .colorful : .svg
                if preview == nil, let document = SVGPreview.parse(svgData) { preview = SVGPreview.png(document, scale: 3) }
            }
            guard let image = preview else {
                skipped.append(name)
                continue
            }
            var icon = CaptureIcon(name: name, kind: kind, sizes: [size], colors: colors, angles: [], image: "",
                                   canvas: size, inkBox: inkBox(image, canvas: size), captures: 0)
            icon.plugin = PluginResource(formats: Array(Set(light.map { $0.format.lowercased() })).sorted(),
                                         inApp: svg?.inApp, hasDark: files.contains { $0.appearance == "dark" && $0.format == "png" },
                                         size: size, svgFile: nil)
            icons.append(Imported(icon: icon, png: image, svg: svgData))
        }
        if icons.isEmpty { throw StudioError.resource("模板的 manifest.json 里没有能读出来的图标。") }
        return Result(appVersion: template.wechat, device: nil, icons: icons, skipped: skipped, isTemplate: true)
    }

    /// Colors an SVG paints with, most used first, as `#RRGGBB`.
    static func svgColors(_ data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        var counts: [String: Int] = [:]
        let pattern = try? NSRegularExpression(pattern: "(?:fill|stroke|stop-color)\\s*[=:]\\s*\"?\\s*(#[0-9A-Fa-f]{3,8}|black|white)")
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern?.matches(in: text, range: range) ?? [] {
            guard let valueRange = Range(match.range(at: 1), in: text) else { continue }
            var value = text[valueRange].lowercased()
            if value == "black" { value = "#000000" }
            if value == "white" { value = "#ffffff" }
            var hex = String(value.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8 else { continue }
            counts["#" + hex.prefix(6).uppercased(), default: 0] += 1
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// `Action_JD_cart.png` → `Action_JD_cart`.
    static func resourceName(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [".png", ".jpg", ".jpeg", ".PNG", ".JPG"] where result.hasSuffix(suffix) {
            result = String(result.dropLast(suffix.count))
        }
        for scale in ["@2x", "@3x"] where result.hasSuffix(scale) { result = String(result.dropLast(scale.count)) }
        return result
    }

    /// The bounding box of pixels that are not almost transparent, in canvas points.
    static func inkBox(_ png: Data, canvas: CGSize) -> CGRect? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= 16_000_000 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] > 12 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let sx = canvas.width / CGFloat(width), sy = canvas.height / CGFloat(height)
        return CGRect(x: CGFloat(minX) * sx, y: CGFloat(minY) * sy,
                      width: CGFloat(maxX - minX + 1) * sx, height: CGFloat(maxY - minY + 1) * sy)
    }
}

struct CaptureExportOptions {
    var scales: [Int] = [3]
    var formats: Set<PlanFormat> = [.png, .svg]
}

/// The imported capture and the replacement chosen for each icon, kept in
/// `Documents/Capture` (project.json, choices.json and the original images).
@MainActor
final class CaptureStore: ObservableObject {
    @Published private(set) var project: CaptureProject?
    @Published private(set) var choices: [String: IconChoice] = [:]
    @Published private(set) var global = GlobalStyle()
    @Published var loadError: String?
    let suggestions = SuggestionBook.bundled()
    let root: URL
    private let images = NSCache<NSString, UIImage>()
    private let previews = NSCache<NSString, UIImage>()
    private var pendingSave: Task<Void, Never>?
    private var pendingStyleSave: Task<Void, Never>?
    private var opticalFactors: [WeightChoice: Double] = [:]
    /// Painted size of a symbol drawn at 64 pt, by symbol and look.
    private var contentSizes: [String: CGSize] = [:]

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Capture", isDirectory: true)
        load()
    }

    private var projectURL: URL { root.appendingPathComponent("project.json") }
    private var choicesURL: URL { root.appendingPathComponent("choices.json") }
    private var imagesFolder: URL { root.appendingPathComponent("icons", isDirectory: true) }
    /// Next to the project folder, so the style outlives clearing the project.
    private var styleURL: URL { root.deletingLastPathComponent().appendingPathComponent("CaptureStyle.json") }

    var icons: [CaptureIcon] { project?.icons ?? [] }

    func load() {
        if let data = try? Data(contentsOf: styleURL), var style = try? JSONDecoder().decode(GlobalStyle.self, from: data) {
            // The old size slider becomes the share of the canvas.
            if style.look.size != 1 {
                if style.coverage == nil { style.share = 0.8 * style.look.size }
                style.look.size = 1
                try? JSONEncoder().encode(style).write(to: styleURL, options: .atomic)
            }
            global = style
        }
        guard let data = try? Data(contentsOf: projectURL) else { return }
        do {
            project = try JSONDecoder().decode(CaptureProject.self, from: data)
            if let saved = try? Data(contentsOf: choicesURL) {
                choices = try JSONDecoder().decode([String: IconChoice].self, from: saved)
                migrateSizes()
            }
        } catch {
            loadError = "读取上次的项目失败：\(error.localizedDescription)"
        }
    }

    /// Moves the size an icon's own look had into its adjustment, where the
    /// size slider now lives.
    private func migrateSizes() {
        var changed = false
        for (name, var choice) in choices where choice.look.size != 1 {
            if !choice.usesGlobal {
                var adjust = choice.adjust ?? IconAdjust()
                adjust.scale *= choice.look.size
                choice.adjust = adjust
            }
            choice.look.size = 1
            choices[name] = choice
            changed = true
        }
        if changed { try? saveChoices() }
    }

    // MARK: Import

    /// Imports a capture zip. With `merge`, new icons are added to the current
    /// project and known ones gain the new sizes and colors. Choices are never
    /// changed by a merge; an icon that already has one also keeps its original
    /// image and position, and a differing newer capture is set aside as
    /// `update` for the user to accept. The choices are backed up first.
    @discardableResult
    func importCapture(_ data: Data, merge: Bool) async throws -> CaptureImportSummary {
        let result = try await Task.detached(priority: .userInitiated) { try CaptureImporter.read(zip: data) }.value
        let fm = FileManager.default
        pendingSave?.cancel()
        backupChoices(reason: merge ? "合并导入之前" : "清空后重新导入之前")
        let previous = merge ? project : nil
        if previous == nil {
            try? fm.removeItem(at: root)
            choices = [:]
            images.removeAllObjects()
        }
        try fm.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        var icons = previous?.icons ?? []
        var history = previous?.history ?? []
        let importIndex = history.count + 1
        var added = 0, updated = 0, changedKept = 0
        for item in result.icons {
            var icon = item.icon
            if let index = icons.firstIndex(where: { $0.name == icon.name }) {
                var known = icons[index]
                for size in icon.sizes where !known.sizes.contains(size) { known.sizes.append(size) }
                for angle in icon.angles where !known.angles.contains(angle) { known.angles.append(angle) }
                if result.isTemplate {
                    try mergeTemplate(item, into: &known, taken: Set(icons.map(\.image)), changedKept: &changedKept)
                    icons[index] = known
                    updated += 1
                    continue
                }
                for color in icon.colors where !known.colors.contains(color) { known.colors.append(color) }
                known.captures += icon.captures
                let larger = icon.canvas.width * icon.canvas.height > known.canvas.width * known.canvas.height
                let moved = icon.canvas == known.canvas && !Self.sameBox(icon.inkBox, known.inkBox)
                if larger || moved {
                    if choices[known.name] != nil {
                        let file = known.update?.image ?? Self.imageFileName(known.name + "_new", taken: Set(icons.map(\.image)))
                        try item.png.write(to: imagesFolder.appendingPathComponent(file), options: .atomic)
                        images.removeObject(forKey: file as NSString)
                        known.update = CaptureUpdate(image: file, canvas: icon.canvas, inkBox: icon.inkBox, version: result.appVersion)
                        changedKept += 1
                    } else {
                        try item.png.write(to: imagesFolder.appendingPathComponent(known.image), options: .atomic)
                        images.removeObject(forKey: known.image as NSString)
                        known.canvas = icon.canvas
                        known.inkBox = icon.inkBox
                    }
                }
                icons[index] = known
                updated += 1
            } else {
                icon.image = Self.imageFileName(icon.name, taken: Set(icons.map(\.image)))
                icon.firstSeen = result.appVersion
                icon.importIndex = importIndex
                try item.png.write(to: imagesFolder.appendingPathComponent(icon.image), options: .atomic)
                if let svg = item.svg {
                    let file = (icon.image as NSString).deletingPathExtension + ".orig.svg"
                    try svg.write(to: imagesFolder.appendingPathComponent(file), options: .atomic)
                    icon.plugin?.svgFile = file
                }
                icons.append(icon)
                added += 1
            }
        }
        icons.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        history.append(CaptureImportRecord(version: result.appVersion, date: Date(), added: added, updated: updated))
        project = CaptureProject(appVersion: result.appVersion ?? previous?.appVersion,
                                 device: result.device ?? previous?.device, imported: Date(), icons: icons, imports: history)
        try saveProject()
        try saveChoices()
        return CaptureImportSummary(version: result.appVersion, added: added, updated: updated,
                                    changedKept: changedKept, skipped: result.skipped, fromTemplate: result.isTemplate)
    }

    /// Takes a plugin template entry into an icon that is already known. The
    /// template's size is the resource's own, so it becomes the canvas. A
    /// captured image stays as the preview when the visible area sits in the
    /// same place relative to the canvas; an icon that already has a
    /// replacement and whose original moved gets the template set aside.
    private func mergeTemplate(_ item: CaptureImporter.Imported, into known: inout CaptureIcon,
                               taken: Set<String>, changedKept: inout Int) throws {
        let icon = item.icon
        var resource = icon.plugin
        if let svg = item.svg {
            let file = known.plugin?.svgFile ?? ((known.image as NSString).deletingPathExtension + ".orig.svg")
            try svg.write(to: imagesFolder.appendingPathComponent(file), options: .atomic)
            resource?.svgFile = file
        }
        known.plugin = resource
        if known.colors.isEmpty { known.colors = icon.colors }
        if known.captures == 0 { known.kind = icon.kind }
        let sameShape = Self.sameRelativeBox(icon.inkBox, icon.canvas, known.inkBox, known.canvas)
        if sameShape && known.captures > 0 {
            // Keep the captured picture, measured on the resource's own canvas.
            let sx = icon.canvas.width / max(known.canvas.width, 0.001), sy = icon.canvas.height / max(known.canvas.height, 0.001)
            known.inkBox = known.inkBox.map { CGRect(x: $0.minX * sx, y: $0.minY * sy, width: $0.width * sx, height: $0.height * sy) }
            known.canvas = icon.canvas
        } else if sameShape || choices[known.name] == nil {
            try item.png.write(to: imagesFolder.appendingPathComponent(known.image), options: .atomic)
            images.removeObject(forKey: known.image as NSString)
            known.canvas = icon.canvas
            known.inkBox = icon.inkBox
        } else {
            let file = known.update?.image ?? Self.imageFileName(known.name + "_new", taken: taken)
            try item.png.write(to: imagesFolder.appendingPathComponent(file), options: .atomic)
            images.removeObject(forKey: file as NSString)
            known.update = CaptureUpdate(image: file, canvas: icon.canvas, inkBox: icon.inkBox, version: project?.appVersion)
            changedKept += 1
        }
    }

    /// Visible areas in the same place relative to their canvases, within 4%.
    private static func sameRelativeBox(_ a: CGRect?, _ canvasA: CGSize, _ b: CGRect?, _ canvasB: CGSize) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        func relative(_ r: CGRect, _ c: CGSize) -> [CGFloat] {
            [r.minX / max(c.width, 0.001), r.minY / max(c.height, 0.001), r.maxX / max(c.width, 0.001), r.maxY / max(c.height, 0.001)]
        }
        return zip(relative(a, canvasA), relative(b, canvasB)).allSatisfy { abs($0 - $1) < 0.04 }
    }

    /// Visible areas within 0.75 pt of each other count as the same.
    private static func sameBox(_ a: CGRect?, _ b: CGRect?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.minX - b.minX) < 0.75 && abs(a.minY - b.minY) < 0.75
            && abs(a.maxX - b.maxX) < 0.75 && abs(a.maxY - b.maxY) < 0.75
    }

    /// Which import is the latest, counting from 1.
    var latestImport: Int { project?.history.count ?? 0 }

    /// Added by the latest import, when there has been more than one.
    func isNew(_ icon: CaptureIcon) -> Bool { latestImport > 1 && (icon.importIndex ?? 1) == latestImport }

    /// Uses the newer capture that was set aside: the replacement is then
    /// exported on its canvas and at its visible area.
    func adoptUpdate(for icon: CaptureIcon) {
        guard var project, let index = project.icons.firstIndex(where: { $0.name == icon.name }),
              let update = project.icons[index].update else { return }
        var known = project.icons[index]
        let fm = FileManager.default
        let target = imagesFolder.appendingPathComponent(known.image)
        try? fm.removeItem(at: target)
        try? fm.moveItem(at: imagesFolder.appendingPathComponent(update.image), to: target)
        images.removeObject(forKey: known.image as NSString)
        images.removeObject(forKey: update.image as NSString)
        known.canvas = update.canvas
        known.inkBox = update.inkBox
        known.update = nil
        project.icons[index] = known
        self.project = project
        try? saveProject()
    }

    /// Drops the newer capture and keeps the original.
    func dismissUpdate(for icon: CaptureIcon) {
        guard var project, let index = project.icons.firstIndex(where: { $0.name == icon.name }),
              let update = project.icons[index].update else { return }
        try? FileManager.default.removeItem(at: imagesFolder.appendingPathComponent(update.image))
        images.removeObject(forKey: update.image as NSString)
        project.icons[index].update = nil
        self.project = project
        try? saveProject()
    }

    func updateImage(for icon: CaptureIcon) -> UIImage? {
        guard let update = icon.update else { return nil }
        return loadImage(update.image, canvasWidth: update.canvas.width)
    }

    // MARK: Backups

    private struct BackupFile: Codable {
        var reason: String
        var date: Date
        var choices: [String: IconChoice]
    }

    /// Next to the project folder, so clearing or deleting the project keeps them.
    var backupsFolder: URL { root.deletingLastPathComponent().appendingPathComponent("CaptureBackups", isDirectory: true) }

    /// Saves the current choices; does nothing when there are none. Keeps the newest 30.
    @discardableResult
    func backupChoices(reason: String) -> Bool {
        guard !choices.isEmpty else { return false }
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = backupsFolder.appendingPathComponent("choices-\(formatter.string(from: Date())).json")
        do {
            try fm.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
            try JSONEncoder().encode(BackupFile(reason: reason, date: Date(), choices: choices)).write(to: url, options: .atomic)
        } catch { return false }
        for old in backups().dropFirst(30) { try? fm.removeItem(at: old.url) }
        return true
    }

    /// Newest first.
    func backups() -> [CaptureBackup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupsFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url -> CaptureBackup? in
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(BackupFile.self, from: data) else { return nil }
            return CaptureBackup(url: url, date: file.date, reason: file.reason, count: file.choices.count)
        }
        .sorted { $0.date > $1.date }
    }

    /// Puts back every choice in the backup; choices for other icons stay.
    /// The current choices are backed up first, so a restore can be undone.
    @discardableResult
    func restore(_ backup: CaptureBackup) throws -> Int {
        let file = try JSONDecoder().decode(BackupFile.self, from: Data(contentsOf: backup.url))
        backupChoices(reason: "恢复备份之前")
        for (name, choice) in file.choices { choices[name] = choice }
        pendingSave?.cancel()
        try saveChoices()
        return file.choices.count
    }

    private static func imageFileName(_ name: String, taken: Set<String>) -> String {
        let safe = name.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? String($0) : "_" }.joined()
        var candidate = safe + ".png"
        var counter = 2
        while taken.contains(candidate) {
            candidate = "\(safe)-\(counter).png"
            counter += 1
        }
        return candidate
    }

    func removeProject() {
        pendingSave?.cancel()
        backupChoices(reason: "删除项目之前")
        try? FileManager.default.removeItem(at: root)
        project = nil
        choices = [:]
        images.removeAllObjects()
    }

    func image(for icon: CaptureIcon) -> UIImage? { loadImage(icon.image, canvasWidth: icon.canvas.width) }

    private func loadImage(_ file: String, canvasWidth: CGFloat) -> UIImage? {
        if let cached = images.object(forKey: file as NSString) { return cached }
        guard let data = try? Data(contentsOf: imagesFolder.appendingPathComponent(file)),
              let pixels = UIImage(data: data),
              let image = UIImage(data: data, scale: max(1, pixels.size.width / max(canvasWidth, 1))) else { return nil }
        images.setObject(image, forKey: file as NSString)
        return image
    }

    // MARK: Choices

    func title(for icon: CaptureIcon) -> String? { suggestions.title(for: icon.name) }
    func isDecorative(_ icon: CaptureIcon) -> Bool { suggestions.isDecorative(icon.name) }
    func symbols(for icon: CaptureIcon) -> [String] { suggestions.symbols(for: icon.name) }

    /// The saved choice, or what a new one would start from: the first
    /// suggested symbol in the global style.
    func choice(for icon: CaptureIcon) -> IconChoice {
        if let saved = choices[icon.name] { return saved }
        return IconChoice(replace: false, symbol: symbols(for: icon).first ?? "questionmark.square.dashed",
                          look: global.look, presetID: nil, manual: nil, followsGlobal: true)
    }

    /// How the icon is drawn: its own look, or the global style.
    func effectiveLook(for icon: CaptureIcon, choice: IconChoice) -> IconLook {
        guard choice.usesGlobal else { return choice.look }
        var look = global.look
        if global.useOriginalColor, look.mode != .multicolor, look.badge == nil,
           let original = icon.mainColor.flatMap({ RGBA(hex: $0) }) {
            let first = look.fills.first
            let fill = first.map { $0.isSolid ? GradientFill(solid: original) : GradientFill(original, original.shifted(), angle: $0.angle) }
                ?? GradientFill(solid: original)
            if look.fills.isEmpty { look.fills = [fill] } else { look.fills[0] = fill }
        }
        return look
    }

    func setGlobal(_ style: GlobalStyle) {
        global = style
        pendingStyleSave?.cancel()
        pendingStyleSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            try? FileManager.default.createDirectory(at: self.styleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(self.global).write(to: self.styleURL, options: .atomic)
        }
    }

    func setChoice(_ choice: IconChoice?, for icon: CaptureIcon) {
        choices[icon.name] = choice
        // Sliders change a choice many times a second; write once they settle.
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            try? self?.saveChoices()
        }
    }

    enum Status: String, CaseIterable, Identifiable {
        case all, pending, replaced, kept, decorative
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .pending: return "待定"
            case .replaced: return "已替换"
            case .kept: return "不替换"
            case .decorative: return "装饰"
            }
        }
    }

    func status(of icon: CaptureIcon) -> Status {
        if let choice = choices[icon.name] { return choice.replace ? .replaced : .kept }
        return isDecorative(icon) ? .decorative : .pending
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, pending, replaced, kept, decorative, new, changed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .pending: return "待定"
            case .replaced: return "已替换"
            case .kept: return "不替换"
            case .decorative: return "装饰"
            case .new: return "最近一次导入新增"
            case .changed: return "新版原图有变化"
            }
        }
    }

    func matches(_ icon: CaptureIcon, _ filter: Filter) -> Bool {
        switch filter {
        case .all: return true
        case .pending: return status(of: icon) == .pending
        case .replaced: return status(of: icon) == .replaced
        case .kept: return status(of: icon) == .kept
        case .decorative: return status(of: icon) == .decorative
        case .new: return isNew(icon)
        case .changed: return icon.update != nil
        }
    }

    /// Replaced icons drawn with the global style, and ones with their own look.
    var styleCounts: (global: Int, own: Int) {
        let replaced = choices.values.filter(\.replace)
        let following = replaced.filter(\.usesGlobal).count
        return (following, replaced.count - following)
    }

    /// Undecided icons that have a suggested symbol and are not decorative.
    var fillableIcons: [CaptureIcon] {
        icons.filter { choices[$0.name] == nil && !isDecorative($0) && !symbols(for: $0).isEmpty }
    }

    /// Marks every fillable icon as replaced with its first suggested symbol,
    /// drawn in the global style.
    @discardableResult
    func fillPending() -> Int {
        let targets = fillableIcons
        for icon in targets {
            guard let symbol = symbols(for: icon).first else { continue }
            choices[icon.name] = IconChoice(replace: true, symbol: symbol, look: global.look, presetID: nil,
                                            manual: false, followsGlobal: true)
        }
        pendingSave?.cancel()
        try? saveChoices()
        return targets.count
    }

    /// Puts every replaced icon with its own look back on the global style,
    /// after a backup. Symbols stay.
    @discardableResult
    func resetOwnStyles() -> Int {
        let targets = choices.filter { $0.value.replace && !$0.value.usesGlobal }
        guard !targets.isEmpty else { return 0 }
        backupChoices(reason: "全部改回跟随全局风格之前")
        for (name, var choice) in targets {
            choice.followsGlobal = true
            choices[name] = choice
        }
        pendingSave?.cancel()
        try? saveChoices()
        return targets.count
    }

    private func saveProject() throws {
        guard let project else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(project).write(to: projectURL, options: .atomic)
    }

    private func saveChoices() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(choices).write(to: choicesURL, options: .atomic)
    }

    // MARK: Size and position

    /// Canvases this much wider or taller than square (arrows, dots, bars)
    /// always follow the original's visible area.
    static let squareish: ClosedRange<CGFloat> = 0.75...1.34

    /// The sizing used for this icon: slim canvases always follow the original.
    func sizing(for icon: CaptureIcon) -> IconSizing {
        let mode = global.sizeMode
        if mode != .original, icon.inkBox != nil, !Self.squareish.contains(icon.canvas.width / max(icon.canvas.height, 0.001)) {
            return .original
        }
        return mode
    }

    /// Where the replacement goes inside the canvas: the global sizing,
    /// then the icon's own nudge.
    func geometry(for icon: CaptureIcon, choice: IconChoice, look: IconLook) -> IconGeometry {
        let canvas = CGRect(origin: .zero, size: icon.canvas)
        let adjust = choice.adjust ?? IconAdjust()
        let scale = CGFloat(min(max(look.size * adjust.scale, 0.3), 2))
        let shift = CGPoint(x: CGFloat(adjust.dx) * canvas.width, y: CGFloat(adjust.dy) * canvas.height)
        func centered(_ width: CGFloat, _ height: CGFloat, at center: CGPoint) -> CGRect {
            CGRect(x: center.x + shift.x - width / 2, y: center.y + shift.y - height / 2, width: width, height: height)
        }
        let sizing = sizing(for: icon)
        let middle = CGPoint(x: canvas.midX, y: canvas.midY)
        let side = min(canvas.width, canvas.height) * CGFloat(global.share) * scale
        switch sizing {
        case .original:
            let base = icon.inkBox ?? canvas.insetBy(dx: canvas.width * 0.1, dy: canvas.height * 0.1)
            let center = CGPoint(x: base.midX, y: base.midY)
            guard let content = contentSize(symbol: choice.symbol, look: look), content.width > 0, content.height > 0 else {
                return IconGeometry(pointSize: 64, fit: .contain, box: centered(base.width * scale, base.height * scale, at: center),
                                    sizing: .original)
            }
            // The same area as the original's visible pixels, so a symbol of
            // another shape is not shrunk to fit inside the original's box;
            // it still stays inside the canvas.
            var fit = sqrt(base.width * base.height / (content.width * content.height))
            fit = min(fit, 2 * min(center.x, canvas.width - center.x) / content.width,
                      2 * min(center.y, canvas.height - center.y) / content.height)
            fit = max(fit, min(base.width / content.width, base.height / content.height))
            return IconGeometry(pointSize: 64, fit: .contain,
                                box: centered(content.width * fit * scale, content.height * fit * scale, at: center),
                                sizing: .original)
        case .uniform:
            return IconGeometry(pointSize: 64, fit: .contain, box: centered(side, side, at: middle), sizing: .uniform)
        case .optical:
            // A badge is a plate as wide as its point size.
            let pointSize = look.badge == nil ? Double(side) * opticalFactor(look.weight) : Double(side)
            // Wide symbols may use more of the canvas than a circle, up to its edges.
            let limit = min(max(CGFloat(global.share) * scale, 0.92), 1)
            return IconGeometry(pointSize: min(max(pointSize, 4), 512), fit: .natural,
                                box: centered(canvas.width * limit, canvas.height * limit, at: middle), sizing: .optical)
        }
    }

    /// The painted size of the symbol drawn in `look` at 64 pt. Cached;
    /// `renderReplacement` fills the cache from the drawing it makes anyway.
    private func contentSize(symbol: String, look: IconLook) -> CGSize? {
        let key = Self.contentKey(symbol, look)
        if let known = contentSizes[key] { return known }
        guard let render = SymbolPipeline.renderDrawing(name: symbol, style: look.style(pointSize: 64)) else { return nil }
        let size = render.drawing.bounds.size
        contentSizes[key] = size
        return size
    }

    private static func contentKey(_ symbol: String, _ look: IconLook) -> String {
        let badge = look.badge.map { "\($0.shape.rawValue)\($0.glyphScale)" } ?? "-"
        return "\(symbol)|\(look.mode.rawValue)|\(look.weight.rawValue)|\(look.gradientRendering)|\(badge)"
    }

    /// Point size per point of height of an SF Symbols circle at this
    /// weight, so “80 %” means a circle symbol covers 80 % of the canvas.
    private func opticalFactor(_ weight: WeightChoice) -> Double {
        if let known = opticalFactors[weight] { return known }
        var style = SymbolStyle()
        style.weight = weight
        style.pointSize = 64
        var factor = 1.0
        if let render = SymbolPipeline.renderDrawing(name: "circle.fill", style: style) {
            let height = Double(render.drawing.bounds.height)
            if height > 1 { factor = 64 / height }
        }
        opticalFactors[weight] = factor
        return factor
    }

    /// The replacement drawn and placed the way every export does it.
    func renderReplacement(for icon: CaptureIcon, choice: IconChoice) -> (pdf: Data, drawing: VectorDrawing, layout: SVGLayout)? {
        let look = effectiveLook(for: icon, choice: choice)
        // Only `optical` draws at another size than 64 pt; the other modes
        // measure the 64 pt drawing, so draw it first and keep its size.
        let pointSize = sizing(for: icon) == .optical ? geometry(for: icon, choice: choice, look: look).pointSize : 64
        guard let render = SymbolPipeline.renderDrawing(name: choice.symbol, style: look.style(pointSize: pointSize)) else {
            return nil
        }
        if pointSize == 64 { contentSizes[Self.contentKey(choice.symbol, look)] = render.drawing.bounds.size }
        let geometry = geometry(for: icon, choice: choice, look: look)
        let layout = SVGWriter.layout(for: render.drawing, frame: render.frame, width: icon.canvas.width,
                                      height: icon.canvas.height, padding: 0, fit: geometry.fit, box: geometry.box)
        return (render.pdf, render.drawing, layout)
    }

    /// The replacement as exported, as an image of the whole canvas with
    /// enough pixels for `side` points on screen. Cached.
    func replacementPreview(for icon: CaptureIcon, choice: IconChoice, side: CGFloat, displayScale: CGFloat) -> UIImage? {
        let look = effectiveLook(for: icon, choice: choice)
        let ink = icon.inkBox.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? "-"
        let key = "\(icon.name)|\(choice.symbol)|\(look.hashValue)|\(choice.adjust?.hashValue ?? 0)|\(global.sizeMode.rawValue)|\(global.share)|\(icon.canvas.width)x\(icon.canvas.height)|\(ink)|\(side)|\(displayScale)" as NSString
        if let cached = previews.object(forKey: key) { return cached }
        guard let output = renderReplacement(for: icon, choice: choice) else { return nil }
        let scale = max(2, displayScale * side / max(icon.canvas.width, icon.canvas.height, 1))
        guard let image = SymbolPipeline.rasterize(pdf: output.pdf, layout: output.layout, pixelScale: scale, background: nil)
            .flatMap({ UIImage(data: $0, scale: scale) }) else { return nil }
        previews.setObject(image, forKey: key)
        return image
    }

    /// How much of the canvas the originals cover, middle value over the
    /// non-decorative icons with a square-ish canvas.
    var originalShare: Double? {
        let shares = icons.compactMap { icon -> Double? in
            guard !isDecorative(icon), let ink = icon.inkBox else { return nil }
            let side = min(icon.canvas.width, icon.canvas.height)
            guard side > 0, Self.squareish.contains(icon.canvas.width / max(icon.canvas.height, 0.001)) else { return nil }
            return Double(max(ink.width, ink.height) / side)
        }.sorted()
        return shares.isEmpty ? nil : shares[shares.count / 2]
    }

    /// Replaced icons with a size or position nudge of their own.
    var adjustedCount: Int { choices.values.filter { $0.replace && !($0.adjust?.isIdentity ?? true) }.count }

    /// Clears every icon's nudge, after a backup.
    @discardableResult
    func resetAdjustments() -> Int {
        let targets = choices.filter { !($0.value.adjust?.isIdentity ?? true) }
        guard !targets.isEmpty else { return 0 }
        backupChoices(reason: "清除单独的大小和位置之前")
        for (name, var choice) in targets {
            choice.adjust = nil
            choices[name] = choice
        }
        pendingSave?.cancel()
        try? saveChoices()
        return targets.count
    }

    // MARK: Export

    func resolvedPlan(_ options: CaptureExportOptions) -> ResolvedPlan {
        var icons: [ResolvedIcon] = []
        var issues: [PlanIssue] = []
        for icon in self.icons {
            guard let choice = choices[icon.name], choice.replace else { continue }
            guard UIImage(systemName: choice.symbol) != nil else {
                issues.append(PlanIssue(severity: .error, icon: icon.name, message: "这个系统里没有符号 “\(choice.symbol)”。"))
                continue
            }
            let look = effectiveLook(for: icon, choice: choice)
            let geometry = geometry(for: icon, choice: choice, look: look)
            let colors = look.fills.map { ColorChoice.custom($0.start) }
            icons.append(ResolvedIcon(index: icons.count, names: [icon.name], symbol: choice.symbol, mode: look.mode,
                                      weight: look.weight, scale: .medium, pointSize: geometry.pointSize, gradient: look.gradientRendering,
                                      variableValue: nil, colors: [.light: colors, .dark: colors], appearances: [.light],
                                      canvas: icon.canvas, padding: 0, box: geometry.box,
                                      fit: geometry.fit, scales: options.scales, formats: PlanFormat.allCases.filter(options.formats.contains),
                                      background: nil, note: title(for: icon),
                                      fills: look.mode == .multicolor ? nil : look.fills, badge: look.badge))
        }
        return ResolvedPlan(name: "wechat-icons", naming: PlanNaming(), icons: icons, issues: issues)
    }

    /// The same replacements as a plan JSON, for the batch tab or for sharing.
    func planJSON(_ options: CaptureExportOptions) throws -> Data {
        var entries: [[String: Any]] = []
        for icon in icons {
            guard let choice = choices[icon.name], choice.replace else { continue }
            let look = effectiveLook(for: icon, choice: choice)
            let geometry = geometry(for: icon, choice: choice, look: look)
            let box = geometry.box
            var entry: [String: Any] = [
                "file": icon.name, "symbol": choice.symbol, "mode": look.mode.rawValue, "weight": look.weight.rawValue,
                "canvas": [Double(icon.canvas.width), Double(icon.canvas.height)],
                "box": [box.minX, box.minY, box.width, box.height].map { (Double($0) * 100).rounded() / 100 },
                "fit": geometry.fit.rawValue, "pointSize": (geometry.pointSize * 100).rounded() / 100,
                "colors": look.fills.map(\.start.hexWithAlpha)
            ]
            if look.mode != .multicolor { entry["fills"] = look.fills.map(\.planText) }
            if let angle = look.fills.first?.angle, angle != 45 { entry["fillAngle"] = angle }
            if look.gradientRendering { entry["gradient"] = true }
            if let badge = look.badge {
                entry["badge"] = ["shape": badge.shape.rawValue, "fill": badge.fill.planText, "glyph": badge.glyphScale] as [String: Any]
            }
            if let title = title(for: icon) { entry["note"] = title }
            if choice.usesGlobal { entry["_global"] = true } else if let preset = choice.presetID { entry["_preset"] = preset }
            entries.append(entry)
        }
        let plan: [String: Any] = [
            "version": 1, "name": "wechat-icons",
            "_comment": "由“逐个替换”页导出。file 是微信的素材名；box 是替换图在画布里的位置，fit 为 natural 时按 pointSize 画、居中放进 box。",
            "defaults": ["scales": options.scales,
                         "formats": PlanFormat.allCases.filter(options.formats.contains).map(\.rawValue)] as [String: Any],
            "icons": entries
        ]
        return try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
