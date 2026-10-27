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
}

struct CaptureBackup: Identifiable {
    let url: URL
    let date: Date
    let reason: String
    let count: Int
    var id: URL { url }
}

/// Reads a WeChatIconCapture zip: `manifest.json` plus one PNG per capture.
enum CaptureImporter {
    struct Imported {
        var icon: CaptureIcon
        var png: Data
    }

    struct Result {
        var appVersion: String?
        var device: String?
        var icons: [Imported]
        var skipped: [String]
    }

    static func read(zip data: Data) throws -> Result {
        let zip = try ZipReader(data: data)
        guard let manifestEntry = zip.entries
            .filter({ $0.path == "manifest.json" || $0.path.hasSuffix("/manifest.json") })
            .min(by: { $0.path.count < $1.path.count }) else {
            throw StudioError.resource("zip 里没有 manifest.json。请导入抓图工具导出的 zip。")
        }
        let base = String(manifestEntry.path.dropLast("manifest.json".count))
        let manifest: CaptureManifest
        do { manifest = try JSONDecoder().decode(CaptureManifest.self, from: zip.read(manifestEntry)) }
        catch let error as StudioError { throw error }
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
    /// Put each replacement where the original's visible pixels were.
    var alignToOriginal = true
}

/// The imported capture and the replacement chosen for each icon, kept in
/// `Documents/Capture` (project.json, choices.json and the original images).
@MainActor
final class CaptureStore: ObservableObject {
    @Published private(set) var project: CaptureProject?
    @Published private(set) var choices: [String: IconChoice] = [:]
    @Published var loadError: String?
    let suggestions = SuggestionBook.bundled()
    let root: URL
    private let images = NSCache<NSString, UIImage>()
    private var pendingSave: Task<Void, Never>?

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Capture", isDirectory: true)
        load()
    }

    private var projectURL: URL { root.appendingPathComponent("project.json") }
    private var choicesURL: URL { root.appendingPathComponent("choices.json") }
    private var imagesFolder: URL { root.appendingPathComponent("icons", isDirectory: true) }

    var icons: [CaptureIcon] { project?.icons ?? [] }

    func load() {
        guard let data = try? Data(contentsOf: projectURL) else { return }
        do {
            project = try JSONDecoder().decode(CaptureProject.self, from: data)
            if let saved = try? Data(contentsOf: choicesURL) {
                choices = try JSONDecoder().decode([String: IconChoice].self, from: saved)
            }
        } catch {
            loadError = "读取上次的项目失败：\(error.localizedDescription)"
        }
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
                for color in icon.colors where !known.colors.contains(color) { known.colors.append(color) }
                for angle in icon.angles where !known.angles.contains(angle) { known.angles.append(angle) }
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
                                    changedKept: changedKept, skipped: result.skipped)
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

    /// The saved choice, or what a new one would start from.
    func choice(for icon: CaptureIcon) -> IconChoice {
        if let saved = choices[icon.name] { return saved }
        let preset = LookPreset.all[0]
        return IconChoice(replace: false, symbol: symbols(for: icon).first ?? "questionmark.square.dashed",
                          look: preset.look(for: icon), presetID: preset.id)
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

    /// Whether bulk apply would change this icon. Undecided icons with a
    /// suggested symbol always; replaced ones only when their kind of choice
    /// (bulk or hand-made) is allowed; "keep" never.
    private func bulkTarget(_ icon: CaptureIcon, overwriteBulk: Bool, overwriteManual: Bool) -> Bool {
        guard let existing = choices[icon.name] else {
            return !isDecorative(icon) && !symbols(for: icon).isEmpty
        }
        guard existing.replace else { return false }
        return existing.isManual ? overwriteManual : overwriteBulk
    }

    func bulkCount(overwriteBulk: Bool, overwriteManual: Bool) -> Int {
        icons.filter { bulkTarget($0, overwriteBulk: overwriteBulk, overwriteManual: overwriteManual) }.count
    }

    /// Applies `preset` to the icons `bulkTarget` picks. A symbol that was
    /// already chosen stays. The choices are backed up first whenever an
    /// existing one would change.
    func apply(_ preset: LookPreset, overwriteBulk: Bool = false, overwriteManual: Bool = false) -> Int {
        let targets = icons.filter { bulkTarget($0, overwriteBulk: overwriteBulk, overwriteManual: overwriteManual) }
        if targets.contains(where: { choices[$0.name] != nil }) { backupChoices(reason: "一键套用「\(preset.title)」之前") }
        for icon in targets {
            guard let symbol = choices[icon.name]?.symbol ?? symbols(for: icon).first else { continue }
            choices[icon.name] = IconChoice(replace: true, symbol: symbol, look: preset.look(for: icon),
                                            presetID: preset.id, manual: false)
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

    // MARK: Export

    /// Where the replacement goes inside the canvas, in points.
    func box(for icon: CaptureIcon, look: IconLook, options: CaptureExportOptions) -> CGRect {
        let canvas = CGRect(origin: .zero, size: icon.canvas)
        let base = (options.alignToOriginal ? icon.inkBox : nil) ?? canvas.insetBy(dx: canvas.width * 0.1, dy: canvas.height * 0.1)
        let scale = CGFloat(min(max(look.size, 0.3), 2))
        let width = base.width * scale, height = base.height * scale
        return CGRect(x: base.midX - width / 2, y: base.midY - height / 2, width: width, height: height)
    }

    func resolvedPlan(_ options: CaptureExportOptions) -> ResolvedPlan {
        var icons: [ResolvedIcon] = []
        var issues: [PlanIssue] = []
        for icon in self.icons {
            guard let choice = choices[icon.name], choice.replace else { continue }
            guard UIImage(systemName: choice.symbol) != nil else {
                issues.append(PlanIssue(severity: .error, icon: icon.name, message: "这个系统里没有符号 “\(choice.symbol)”。"))
                continue
            }
            let look = choice.look
            let colors = look.fills.map { ColorChoice.custom($0.start) }
            icons.append(ResolvedIcon(index: icons.count, names: [icon.name], symbol: choice.symbol, mode: look.mode,
                                      weight: look.weight, scale: .medium, pointSize: 64, gradient: look.gradientRendering,
                                      variableValue: nil, colors: [.light: colors, .dark: colors], appearances: [.light],
                                      canvas: icon.canvas, padding: 0.1, box: box(for: icon, look: look, options: options),
                                      fit: .contain, scales: options.scales, formats: PlanFormat.allCases.filter(options.formats.contains),
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
            let look = choice.look
            let box = box(for: icon, look: look, options: options)
            var entry: [String: Any] = [
                "file": icon.name, "symbol": choice.symbol, "mode": look.mode.rawValue, "weight": look.weight.rawValue,
                "canvas": [Double(icon.canvas.width), Double(icon.canvas.height)],
                "box": [box.minX, box.minY, box.width, box.height].map { (Double($0) * 100).rounded() / 100 },
                "colors": look.fills.map(\.start.hexWithAlpha)
            ]
            if look.mode != .multicolor { entry["fills"] = look.fills.map(\.planText) }
            if let angle = look.fills.first?.angle, angle != 45 { entry["fillAngle"] = angle }
            if look.gradientRendering { entry["gradient"] = true }
            if let badge = look.badge {
                entry["badge"] = ["shape": badge.shape.rawValue, "fill": badge.fill.planText, "glyph": badge.glyphScale] as [String: Any]
            }
            if let title = title(for: icon) { entry["note"] = title }
            if let preset = choice.presetID { entry["_preset"] = preset }
            entries.append(entry)
        }
        let plan: [String: Any] = [
            "version": 1, "name": "wechat-icons",
            "_comment": "由“逐个替换”页导出。file 是微信的素材名，box 是原图内容所在的位置。",
            "defaults": ["scales": options.scales,
                         "formats": PlanFormat.allCases.filter(options.formats.contains).map(\.rawValue)] as [String: Any],
            "icons": entries
        ]
        return try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
