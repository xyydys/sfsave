import Foundation
import UIKit

enum IconFit: String, CaseIterable, Codable, Sendable {
    /// Scale the painted shape to fill the canvas minus padding.
    case contain
    /// Keep the rendered point size and only center the shape; shrink it
    /// only when it would not fit.
    case natural
}

enum PlanFormat: String, CaseIterable, Codable, Sendable {
    case png, svg
}

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// An icon plan as written in JSON: which symbol becomes which file, how it is
/// colored in light and dark appearance, and how big the files are.
/// Everything except `icons[].file` and `icons[].symbol` is optional, and any
/// style field can be set once in `defaults` and overridden per icon.
struct IconPlan: Decodable {
    var version: Int?
    var name: String?
    var defaults: PlanStyle?
    var output: Output?
    var icons: [Icon]
    var unknownKeys: [String] = []

    struct Output: Decodable {
        var darkSuffix: String?
        var darkFolder: String?
        var scaleSuffix: String?
        var svgFolder: String?
        var unknownKeys: [String] = []

        private static let known: Set<String> = ["darkSuffix", "darkFolder", "scaleSuffix", "svgFolder"]
        private enum CodingKeys: String, CodingKey { case darkSuffix, darkFolder, scaleSuffix, svgFolder }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            darkSuffix = try c.decodeIfPresent(String.self, forKey: .darkSuffix)
            darkFolder = try c.decodeIfPresent(String.self, forKey: .darkFolder)
            scaleSuffix = try c.decodeIfPresent(String.self, forKey: .scaleSuffix)
            svgFolder = try c.decodeIfPresent(String.self, forKey: .svgFolder)
            unknownKeys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
                .filter { !Self.known.contains($0) && !IconPlan.isIgnorable($0) }
        }
    }

    struct Icon: Decodable {
        var file: String?
        var aliases: [String]?
        var symbol: String?
        var note: String?
        var style: PlanStyle
        var unknownKeys: [String] = []

        private static let known: Set<String> = ["file", "aliases", "symbol", "note"]
        private enum CodingKeys: String, CodingKey { case file, aliases, symbol, note }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            file = try c.decodeIfPresent(String.self, forKey: .file)
            aliases = try c.decodeIfPresent([String].self, forKey: .aliases)
            symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
            note = try c.decodeIfPresent(String.self, forKey: .note)
            style = try PlanStyle(from: decoder)
            unknownKeys = style.presentKeys
                .filter { !PlanStyle.known.contains($0) && !Self.known.contains($0) && !IconPlan.isIgnorable($0) }
        }
    }

    private static let known: Set<String> = ["version", "name", "defaults", "output", "icons"]
    private enum CodingKeys: String, CodingKey { case version, name, defaults, output, icons }

    /// Keys such as `"_comment"` or `"$schema"` are allowed for notes and tooling.
    fileprivate static func isIgnorable(_ key: String) -> Bool {
        key.hasPrefix("_") || key.hasPrefix("$") || key == "comment"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        defaults = try c.decodeIfPresent(PlanStyle.self, forKey: .defaults)
        output = try c.decodeIfPresent(Output.self, forKey: .output)
        icons = try c.decode([Icon].self, forKey: .icons)
        unknownKeys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
            .filter { !Self.known.contains($0) && !Self.isIgnorable($0) }
    }

    static func decode(_ data: Data) throws -> IconPlan {
        do { return try JSONDecoder().decode(IconPlan.self, from: data) }
        catch { throw StudioError.resource(describe(error)) }
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let text = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? "." + $0.stringValue }.joined()
            return text.hasPrefix(".") ? String(text.dropFirst()) : text
        }
        switch error {
        case .typeMismatch(_, let context):
            return "字段类型不对：\(path(context))。\(context.debugDescription)"
        case .valueNotFound(_, let context):
            return "字段没有值：\(path(context))"
        case .keyNotFound(let key, let context):
            let where_ = path(context)
            return "缺少必需字段 “\(key.stringValue)”" + (where_.isEmpty ? "" : "（位置：\(where_)）")
        case .dataCorrupted(let context):
            let detail = ((context.underlyingError as NSError?)?.userInfo["NSDebugDescription"] as? String)
                ?? context.debugDescription
            return "不是有效的 JSON：\(detail)"
        @unknown default:
            return error.localizedDescription
        }
    }
}

/// The style fields shared by `defaults` and every icon.
struct PlanStyle: Decodable {
    var mode: String?
    var weight: String?
    var scale: String?
    var pointSize: Double?
    var variableValue: Double?
    var gradient: Bool?
    /// Used for both appearances unless `light` / `dark` say otherwise.
    var colors: [String]?
    var light: [String]?
    var dark: [String]?
    /// Width and height in points.
    var canvas: [Double]?
    var padding: Double?
    /// x, y, width, height in canvas points; replaces padding.
    var box: [Double]?
    var fit: String?
    var scales: [Int]?
    var formats: [String]?
    var appearances: [String]?
    var background: String?
    /// Per-layer fills: `#RRGGBB`, or `#start>#end` for a gradient.
    var fills: [String]?
    var fillAngle: Double?
    var badge: Badge?
    var presentKeys: [String] = []

    struct Badge: Decodable {
        var shape: String?
        var fill: String?
        var glyph: Double?
    }

    fileprivate static let known: Set<String> = [
        "mode", "weight", "scale", "pointSize", "variableValue", "gradient", "colors", "color",
        "light", "dark", "canvas", "padding", "box", "fit", "scales", "formats", "appearances", "background",
        "fills", "fillAngle", "badge"
    ]

    private enum CodingKeys: String, CodingKey {
        case mode, weight, scale, pointSize, variableValue, gradient, colors, color
        case light, dark, canvas, padding, box, fit, scales, formats, appearances, background
        case fills, fillAngle, badge
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        weight = try c.decodeIfPresent(String.self, forKey: .weight)
        scale = try c.decodeIfPresent(String.self, forKey: .scale)
        pointSize = try c.decodeIfPresent(Double.self, forKey: .pointSize)
        variableValue = try c.decodeIfPresent(Double.self, forKey: .variableValue)
        gradient = try c.decodeIfPresent(Bool.self, forKey: .gradient)
        colors = try Self.strings(c, .colors) ?? Self.strings(c, .color)
        light = try Self.strings(c, .light)
        dark = try Self.strings(c, .dark)
        canvas = try Self.numbers(c, .canvas)
        padding = try c.decodeIfPresent(Double.self, forKey: .padding)
        box = try c.decodeIfPresent([Double].self, forKey: .box)
        fit = try c.decodeIfPresent(String.self, forKey: .fit)
        scales = try c.decodeIfPresent([Int].self, forKey: .scales)
        formats = try Self.strings(c, .formats)
        appearances = try Self.strings(c, .appearances)
        background = try c.decodeIfPresent(String.self, forKey: .background)
        fills = try Self.strings(c, .fills)
        fillAngle = try c.decodeIfPresent(Double.self, forKey: .fillAngle)
        badge = try c.decodeIfPresent(Badge.self, forKey: .badge)
        presentKeys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
    }

    /// A list, or a single value standing for a list of one.
    private static func strings(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> [String]? {
        if let list = try? c.decode([String].self, forKey: key) { return list }
        return try c.decodeIfPresent(String.self, forKey: key).map { [$0] }
    }

    private static func numbers(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> [Double]? {
        if let list = try? c.decode([Double].self, forKey: key) { return list }
        return try c.decodeIfPresent(Double.self, forKey: key).map { [$0] }
    }
}

// MARK: - Resolution

struct PlanIssue: Identifiable {
    enum Severity { case error, warning }
    let id = UUID()
    let severity: Severity
    let icon: String?
    let message: String
}

/// How output files are named inside the zip.
struct PlanNaming {
    var darkSuffix = "_dark"
    var darkFolder = ""
    var scaleSuffix = "@{n}x"
    var svgFolder = "svg"

    func pngPath(_ name: String, _ appearance: AppearanceChoice, scale: Int) -> String {
        base(name, appearance) + (scale == 1 ? "" : scaleSuffix.replacingOccurrences(of: "{n}", with: String(scale))) + ".png"
    }

    func svgPath(_ name: String, _ appearance: AppearanceChoice) -> String {
        (svgFolder.isEmpty ? "" : svgFolder + "/") + base(name, appearance) + ".svg"
    }

    private func base(_ name: String, _ appearance: AppearanceChoice) -> String {
        guard appearance == .dark else { return name }
        return (darkFolder.isEmpty ? "" : darkFolder + "/") + name + darkSuffix
    }
}

struct ResolvedIcon: Identifiable {
    let index: Int
    var id: Int { index }
    /// `file` first, then `aliases`. Each name gets its own copy of every output file.
    var names: [String]
    var symbol: String
    var mode: RenderModeChoice
    var weight: WeightChoice
    var scale: ScaleChoice
    var pointSize: Double
    var gradient: Bool
    var variableValue: Double?
    var colors: [AppearanceChoice: [ColorChoice]]
    var appearances: [AppearanceChoice]
    var canvas: CGSize
    var padding: Double
    var box: CGRect?
    var fit: IconFit
    var scales: [Int]
    var formats: [PlanFormat]
    var background: RGBA?
    var note: String?
    var fills: [GradientFill]? = nil
    var badge: SymbolBadge? = nil

    func style(for appearance: AppearanceChoice) -> SymbolStyle {
        var style = SymbolStyle()
        style.renderingMode = mode
        let list = colors[appearance] ?? [.system(.primary)]
        style.colors = list
        style.paletteCount = min(max(fills?.count ?? list.count, 2), 3)
        style.fills = fills
        style.badge = badge
        style.gradient = gradient
        style.weight = weight
        style.scale = scale
        style.pointSize = pointSize
        style.usesVariableValue = variableValue != nil
        style.variableValue = variableValue ?? 0.5
        style.appearance = appearance
        return style
    }

    func outputPaths(_ naming: PlanNaming, formats: Set<PlanFormat>, includeDark: Bool) -> [String] {
        var paths: [String] = []
        for appearance in appearances where includeDark || appearance == .light {
            for name in names {
                if formats.contains(.png) { paths += scales.map { naming.pngPath(name, appearance, scale: $0) } }
                if formats.contains(.svg) { paths.append(naming.svgPath(name, appearance)) }
            }
        }
        return paths
    }
}

struct ResolvedPlan {
    var name: String
    var naming: PlanNaming
    /// Icons that passed validation. Icons with errors are left out.
    var icons: [ResolvedIcon]
    var issues: [PlanIssue]

    var errorCount: Int { issues.filter { $0.severity == .error }.count }
    var warningCount: Int { issues.filter { $0.severity == .warning }.count }
}

extension GradientFill {
    /// `#RRGGBB` for a solid fill or `#start>#end` for a gradient; system
    /// color names are taken in their light appearance.
    static func parse(_ text: String, angle: Double) -> GradientFill? {
        let parts = text.split(separator: ">", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count) else { return nil }
        let colors = parts.compactMap { ColorChoice.parse($0)?.resolved(.light) }
        guard colors.count == parts.count, let first = colors.first, let last = colors.last else { return nil }
        return GradientFill(first, last, angle: angle)
    }

    /// The plan JSON form of this fill.
    var planText: String { isSolid ? start.hexWithAlpha : start.hexWithAlpha + ">" + end.hexWithAlpha }
}

extension ColorChoice {
    /// `#RRGGBB`, `#RRGGBBAA`, or a system color name such as `blue` or `secondary`.
    static func parse(_ text: String) -> ColorChoice? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { return RGBA(hex: trimmed).map { .custom($0) } }
        return SystemColor(rawValue: trimmed.lowercased()).map { .system($0) }
    }
}

extension IconPlan {
    static let maxCanvas = 2048.0

    func resolve() -> ResolvedPlan {
        var issues: [PlanIssue] = []
        func error(_ icon: String?, _ message: String) { issues.append(PlanIssue(severity: .error, icon: icon, message: message)) }
        func warn(_ icon: String?, _ message: String) { issues.append(PlanIssue(severity: .warning, icon: icon, message: message)) }

        if let version, version != 1 { warn(nil, "方案版本是 \(version)，这个 App 只认识版本 1，部分字段可能被忽略。") }
        for key in unknownKeys { warn(nil, "未知字段 “\(key)”会被忽略，是不是拼错了？") }
        for key in defaults?.presentKeys.filter({ !PlanStyle.known.contains($0) && !Self.isIgnorable($0) }) ?? [] {
            warn(nil, "defaults 里有未知字段 “\(key)”，会被忽略。")
        }
        for key in output?.unknownKeys ?? [] { warn(nil, "output 里有未知字段 “\(key)”，会被忽略。") }
        if icons.isEmpty { error(nil, "icons 是空的，没有可导出的图标。") }

        var naming = PlanNaming()
        if let value = output?.darkSuffix { naming.darkSuffix = value }
        if let value = output?.darkFolder { naming.darkFolder = value }
        if let value = output?.scaleSuffix { naming.scaleSuffix = value }
        if let value = output?.svgFolder { naming.svgFolder = value }
        for (label, value) in [("darkFolder", naming.darkFolder), ("svgFolder", naming.svgFolder)]
        where !value.isEmpty && !Self.isValidPath(value) {
            error(nil, "output.\(label) 不是有效的文件夹名：\(value)")
        }
        if naming.darkSuffix.isEmpty && naming.darkFolder.isEmpty {
            warn(nil, "darkSuffix 和 darkFolder 都是空的，深色图标会和浅色图标重名。")
        }
        if !naming.scaleSuffix.contains("{n}") {
            warn(nil, "scaleSuffix 里没有 {n}，@2x 和 @3x 的文件会重名。")
        }

        var resolved: [ResolvedIcon] = []
        var claimed: [String: String] = [:]

        for (index, icon) in icons.enumerated() {
            let label = icon.file.map { "“\($0)”" } ?? "第 \(index + 1) 项"
            var failed = false
            func fail(_ message: String) { error(label, message); failed = true }

            for key in icon.unknownKeys { warn(label, "未知字段 “\(key)”会被忽略，是不是拼错了？") }

            guard let file = icon.file?.trimmingCharacters(in: .whitespaces), !file.isEmpty else {
                fail("缺少 file（输出文件名，不含扩展名）。")
                continue
            }
            let names = [file] + (icon.aliases ?? [])
            if Set(names.map { $0.lowercased() }).count != names.count { fail("file 和 aliases 里有重复的名字。") }
            for name in names where !Self.isValidPath(name) {
                fail("文件名不合法：“\(name)”。不能为空，不能含 ..、反斜杠或这些字符：: * ? \" < > |")
            }
            guard let symbol = icon.symbol?.trimmingCharacters(in: .whitespaces), !symbol.isEmpty else {
                fail("缺少 symbol（SF Symbol 名称）。")
                continue
            }
            if UIImage(systemName: symbol) == nil { fail("这个系统里没有符号 “\(symbol)”。") }

            let d = defaults, s = icon.style
            func pick<T>(_ keyPath: KeyPath<PlanStyle, T?>) -> T? { s[keyPath: keyPath] ?? d?[keyPath: keyPath] }

            func choice<T: RawRepresentable & CaseIterable>(_ field: String, _ text: String?, _ fallback: T) -> T where T.RawValue == String {
                guard let text else { return fallback }
                if let match = T.allCases.first(where: { $0.rawValue.lowercased() == text.lowercased() }) { return match }
                fail("\(field) 不能是 “\(text)”，可选：" + T.allCases.map(\.rawValue).joined(separator: " / "))
                return fallback
            }
            let mode = choice("mode", pick(\.mode), RenderModeChoice.monochrome)
            let weight = choice("weight", pick(\.weight), WeightChoice.regular)
            let scaleChoice = choice("scale", pick(\.scale), ScaleChoice.medium)
            let fit = choice("fit", pick(\.fit), IconFit.contain)

            var canvas = CGSize(width: 60, height: 60)
            if let values = pick(\.canvas) {
                if values.count == 1 { canvas = CGSize(width: values[0], height: values[0]) }
                else if values.count == 2 { canvas = CGSize(width: values[0], height: values[1]) }
                else { fail("canvas 要写成 [宽, 高]（单位：点）。") }
                if !(1...Self.maxCanvas).contains(Double(canvas.width)) || !(1...Self.maxCanvas).contains(Double(canvas.height)) {
                    fail("canvas 每一边要在 1 到 \(Int(Self.maxCanvas)) 点之间。")
                }
            }

            var padding = pick(\.padding) ?? 0.1
            if !(0...0.45).contains(padding) {
                warn(label, "padding 要在 0 到 0.45 之间，已调整。")
                padding = min(max(padding, 0), 0.45)
            }
            var box: CGRect?
            if let values = pick(\.box) {
                if values.count == 4, values[2] > 0, values[3] > 0 {
                    box = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
                    if let rect = box, !CGRect(origin: .zero, size: canvas).insetBy(dx: -0.01, dy: -0.01).contains(rect) {
                        warn(label, "box 超出了画布，超出的部分会被裁掉。")
                    }
                } else {
                    fail("box 要写成 [x, y, 宽, 高]（单位：点），宽和高要大于 0。")
                }
            }
            var pointSize = pick(\.pointSize) ?? (fit == .natural ? 24 : 64)
            if !(4...512).contains(pointSize) {
                warn(label, "pointSize 要在 4 到 512 之间，已调整。")
                pointSize = min(max(pointSize, 4), 512)
            }
            var variable = pick(\.variableValue)
            if let value = variable, !(0...1).contains(value) {
                warn(label, "variableValue 要在 0 到 1 之间，已调整。")
                variable = min(max(value, 0), 1)
            }

            let scales = pick(\.scales) ?? [1]
            if scales.isEmpty || scales.contains(where: { !(1...4).contains($0) }) || Set(scales).count != scales.count {
                fail("scales 要写成 1 到 4 之间不重复的整数，例如 [2, 3]。")
            }

            var formats: [PlanFormat] = []
            for text in pick(\.formats) ?? ["png"] {
                if let format = PlanFormat(rawValue: text.lowercased()) { if !formats.contains(format) { formats.append(format) } }
                else { fail("formats 里的 “\(text)” 不认识，可选：png / svg。") }
            }
            if formats.isEmpty { fail("formats 不能是空的。") }

            var background: RGBA?
            if let text = pick(\.background) {
                if let color = ColorChoice.parse(text), case .custom(let rgba) = color { background = rgba }
                else { fail("background 要写成 #RRGGBB 或 #RRGGBBAA：“\(text)”。") }
            }

            // Colors: the icon's own light/dark, then its colors, then the same from defaults.
            func colorList(_ keyPath: KeyPath<PlanStyle, [String]?>) -> [String]? {
                s[keyPath: keyPath] ?? s.colors ?? d?[keyPath: keyPath] ?? d?.colors
            }
            // A dark variant is exported whenever the icon or `defaults` defines dark colors.
            var appearances: [AppearanceChoice] = (s.dark ?? d?.dark) != nil ? [.light, .dark] : [.light]
            if let texts = pick(\.appearances) {
                appearances = []
                for text in texts {
                    if let match = AppearanceChoice(rawValue: text.lowercased()) { if !appearances.contains(match) { appearances.append(match) } }
                    else { fail("appearances 里的 “\(text)” 不认识，可选：light / dark。") }
                }
                if appearances.isEmpty { fail("appearances 不能是空的。") }
            }

            var colors: [AppearanceChoice: [ColorChoice]] = [:]
            for appearance in AppearanceChoice.allCases {
                let key: KeyPath<PlanStyle, [String]?> = appearance == .light ? \.light : \.dark
                let texts = colorList(key) ?? ["primary"]
                var parsed: [ColorChoice] = []
                for text in texts {
                    if let color = ColorChoice.parse(text) { parsed.append(color) }
                    else { fail("颜色 “\(text)” 看不懂。写成 #RRGGBB、#RRGGBBAA，或系统色名（blue、secondary…）。") }
                }
                if parsed.isEmpty { parsed = [.system(.primary)] }
                colors[appearance] = parsed
            }
            let fillAngle = pick(\.fillAngle) ?? 45
            var fills: [GradientFill]?
            if let texts = pick(\.fills) {
                var parsed: [GradientFill] = []
                for text in texts {
                    if let fill = GradientFill.parse(text, angle: fillAngle) { parsed.append(fill) }
                    else { fail("fills 里的 “\(text)” 看不懂。写成 #RRGGBB，或用 #起始色>#结束色 表示渐变。") }
                }
                if parsed.count > 3 { warn(label, "fills 最多用 3 层，多余的会被忽略。") }
                if mode == .multicolor && !parsed.isEmpty { warn(label, "multicolor 模式不使用 fills。") }
                fills = parsed.isEmpty ? nil : Array(parsed.prefix(3))
            }
            var badge: SymbolBadge?
            if let plan = pick(\.badge) {
                let shape = choice("badge.shape", plan.shape, BadgeShape.squircle)
                var glyph = plan.glyph ?? 0.5
                if !(0.2...0.9).contains(glyph) {
                    warn(label, "badge.glyph 要在 0.2 到 0.9 之间，已调整。")
                    glyph = min(max(glyph, 0.2), 0.9)
                }
                if let fill = plan.fill.flatMap({ GradientFill.parse($0, angle: fillAngle) }) {
                    badge = SymbolBadge(shape: shape, fill: fill, glyphScale: glyph)
                } else {
                    fail("badge.fill 要写成 #RRGGBB，或用 #起始色>#结束色 表示渐变。")
                }
            }

            for appearance in appearances where fills == nil || mode == .multicolor {
                let count = colors[appearance]?.count ?? 1
                if mode == .palette && count < 2 {
                    warn(label, "palette 模式至少要 2 个颜色（\(appearance.rawValue)），不够的会重复最后一个。")
                } else if mode == .palette && count > 3 {
                    warn(label, "palette 模式最多用 3 个颜色（\(appearance.rawValue)），多余的会被忽略。")
                } else if mode != .palette && count > 1 {
                    warn(label, "\(mode.rawValue) 模式只用第一个颜色（\(appearance.rawValue)），其余会被忽略。")
                }
            }

            let gradient = pick(\.gradient) ?? false
            if gradient && !SymbolGradientSupport.isAvailable { warn(label, "渐变需要 iOS 26，这台设备上会按纯色导出。") }
            if failed { continue }

            let item = ResolvedIcon(index: index, names: names, symbol: symbol, mode: mode, weight: weight,
                                    scale: scaleChoice, pointSize: pointSize, gradient: gradient,
                                    variableValue: variable, colors: colors, appearances: appearances,
                                    canvas: canvas, padding: padding, box: box, fit: fit, scales: scales,
                                    formats: formats, background: background, note: icon.note,
                                    fills: fills, badge: badge)

            let paths = item.outputPaths(naming, formats: Set(formats), includeDark: true)
            if let clash = paths.first(where: { claimed[$0.lowercased()] != nil }) {
                error(label, "输出文件 “\(clash)” 和 \(claimed[clash.lowercased()] ?? "另一项") 重名（文件名不区分大小写）。")
                continue
            }
            for path in paths { claimed[path.lowercased()] = label }
            resolved.append(item)
        }

        return ResolvedPlan(name: name ?? "icons", naming: naming, icons: resolved, issues: issues)
    }

    /// A relative path of plain components: no empty parts, `.`/`..`, or reserved characters.
    static func isValidPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 120, !path.contains("\\") else { return false }
        for part in path.split(separator: "/", omittingEmptySubsequences: false) where part.isEmpty || part == "." || part == ".." {
            return false
        }
        let reserved = Set(":*?\"<>|".unicodeScalars)
        return path.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 && !reserved.contains($0) }
    }
}
