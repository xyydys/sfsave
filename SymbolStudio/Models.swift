import Foundation
import SwiftUI
import UIKit

struct SymbolItem: Codable, Identifiable, Hashable, Sendable {
    let name: String
    let categories: [String]
    let keywords: String
    var id: String { name }
    var searchableText: String { name + " " + keywords }
}

struct SymbolCategory: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let icon: String
    var count: Int
}

struct SymbolCatalog: Codable, Sendable {
    let version: String
    var categories: [SymbolCategory]
    var symbols: [SymbolItem]
}

struct RGBA: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let black = RGBA(red: 0, green: 0, blue: 0)
    static let white = RGBA(red: 1, green: 1, blue: 1)

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var hex: String {
        String(format: "#%02X%02X%02X", Int((red.clamped01 * 255).rounded()),
               Int((green.clamped01 * 255).rounded()), Int((blue.clamped01 * 255).rounded()))
    }
    var hexWithAlpha: String {
        hex + (alpha < 1 ? String(format: "%02X", Int((alpha * 255).rounded())) : "")
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = (red.clamped01 * 255).rounded() / 255
        self.green = (green.clamped01 * 255).rounded() / 255
        self.blue = (blue.clamped01 * 255).rounded() / 255
        self.alpha = alpha.clamped01
    }
    init(_ color: Color) {
        self.init(uiColor: UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
    }
    init(uiColor: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
    }
    init?(hex: String) {
        let input = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard [6, 8].contains(input.count), let n = UInt64(input, radix: 16) else { return nil }
        let rgb = input.count == 8 ? n >> 8 : n
        self.init(red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255,
                  blue: Double(rgb & 255) / 255,
                  alpha: input.count == 8 ? Double(n & 255) / 255 : 1)
    }
}

extension Double {
    var clamped01: Double { min(1, max(0, self)) }
}

/// The colors offered by the color menu, in the order SF Symbols uses.
enum SystemColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown
    case white, gray, black
    case primary, secondary, tertiary, quaternary, accent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: return "红色 Red"
        case .orange: return "橙色 Orange"
        case .yellow: return "黄色 Yellow"
        case .green: return "绿色 Green"
        case .mint: return "薄荷 Mint"
        case .teal: return "蓝绿 Teal"
        case .cyan: return "青色 Cyan"
        case .blue: return "蓝色 Blue"
        case .indigo: return "靛蓝 Indigo"
        case .purple: return "紫色 Purple"
        case .pink: return "粉色 Pink"
        case .brown: return "棕色 Brown"
        case .white: return "白色 White"
        case .gray: return "灰色 Gray"
        case .black: return "黑色 Black"
        case .primary: return "主要 Primary"
        case .secondary: return "次要 Secondary"
        case .tertiary: return "第三级 Tertiary"
        case .quaternary: return "第四级 Quaternary"
        case .accent: return "强调色 Accent"
        }
    }

    /// Primary, secondary and friends change with light and dark appearance.
    var isSemantic: Bool { [.primary, .secondary, .tertiary, .quaternary, .accent].contains(self) }

    var shapeStyle: AnyShapeStyle {
        switch self {
        case .red: return AnyShapeStyle(Color.red)
        case .orange: return AnyShapeStyle(Color.orange)
        case .yellow: return AnyShapeStyle(Color.yellow)
        case .green: return AnyShapeStyle(Color.green)
        case .mint: return AnyShapeStyle(Color.mint)
        case .teal: return AnyShapeStyle(Color.teal)
        case .cyan: return AnyShapeStyle(Color.cyan)
        case .blue: return AnyShapeStyle(Color.blue)
        case .indigo: return AnyShapeStyle(Color.indigo)
        case .purple: return AnyShapeStyle(Color.purple)
        case .pink: return AnyShapeStyle(Color.pink)
        case .brown: return AnyShapeStyle(Color.brown)
        case .white: return AnyShapeStyle(Color.white)
        case .gray: return AnyShapeStyle(Color.gray)
        case .black: return AnyShapeStyle(Color.black)
        case .primary: return AnyShapeStyle(HierarchicalShapeStyle.primary)
        case .secondary: return AnyShapeStyle(HierarchicalShapeStyle.secondary)
        case .tertiary: return AnyShapeStyle(HierarchicalShapeStyle.tertiary)
        case .quaternary: return AnyShapeStyle(HierarchicalShapeStyle.quaternary)
        case .accent: return AnyShapeStyle(Color.accentColor)
        }
    }

    var uiColor: UIColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .mint: return .systemMint
        case .teal: return .systemTeal
        case .cyan: return .systemCyan
        case .blue: return .systemBlue
        case .indigo: return .systemIndigo
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .brown: return .systemBrown
        case .white: return .white
        case .gray: return .systemGray
        case .black: return .black
        case .primary: return .label
        case .secondary: return .secondaryLabel
        case .tertiary: return .tertiaryLabel
        case .quaternary: return .quaternaryLabel
        case .accent: return .systemBlue
        }
    }
}

enum ColorChoice: Codable, Hashable, Sendable {
    case system(SystemColor)
    case custom(RGBA)

    static let customKey = "custom"

    var key: String {
        switch self {
        case .system(let color): return color.rawValue
        case .custom: return Self.customKey
        }
    }

    var title: String {
        switch self {
        case .system(let color): return color.title
        case .custom(let rgba): return rgba.hexWithAlpha
        }
    }

    var shapeStyle: AnyShapeStyle {
        switch self {
        case .system(let color): return color.shapeStyle
        case .custom(let rgba): return AnyShapeStyle(rgba.color)
        }
    }

    var uiColor: UIColor {
        switch self {
        case .system(let color): return color.uiColor
        case .custom(let rgba):
            return UIColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        }
    }

    func resolved(_ appearance: AppearanceChoice) -> RGBA {
        RGBA(uiColor: uiColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: appearance.interfaceStyle)))
    }
}

enum RenderModeChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case monochrome, hierarchical, palette, multicolor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monochrome: return "单色 Monochrome"
        case .hierarchical: return "分层 Hierarchical"
        case .palette: return "调色板 Palette"
        case .multicolor: return "多色 Multicolor"
        }
    }

    var footnote: String {
        switch self {
        case .monochrome: return "整个符号使用同一种颜色。"
        case .hierarchical: return "系统用一个颜色按层级派生出不同透明度。"
        case .palette: return "每一层分别指定颜色。不同符号的层数不同，多出来的颜色会被忽略。"
        case .multicolor: return "使用苹果预设的多色方案，这里的颜色只作用于没有固定颜色的部分。没有多色版本的符号会显示为单色。"
        }
    }

    var swiftUIMode: SymbolRenderingMode {
        switch self {
        case .monochrome: return .monochrome
        case .hierarchical: return .hierarchical
        case .palette: return .palette
        case .multicolor: return .multicolor
        }
    }
}

enum WeightChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ultraLight: return "极细 Ultralight"
        case .thin: return "纤细 Thin"
        case .light: return "细 Light"
        case .regular: return "常规 Regular"
        case .medium: return "中等 Medium"
        case .semibold: return "中粗 Semibold"
        case .bold: return "粗 Bold"
        case .heavy: return "特粗 Heavy"
        case .black: return "黑 Black"
        }
    }

    var fontWeight: Font.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    var uiWeight: UIImage.SymbolWeight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

enum ScaleChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case small, medium, large

    var id: String { rawValue }
    var title: String { self == .small ? "小" : (self == .medium ? "中" : "大") }
    var imageScale: Image.Scale { self == .small ? .small : (self == .medium ? .medium : .large) }
    var uiScale: UIImage.SymbolScale { self == .small ? .small : (self == .medium ? .medium : .large) }
}

enum AppearanceChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case light, dark

    var id: String { rawValue }
    var title: String { self == .light ? "浅色" : "深色" }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
    var interfaceStyle: UIUserInterfaceStyle { self == .light ? .light : .dark }
}

/// Everything that changes how the system draws the symbol. The same values
/// drive the preview, the SVG export and the generated code.
struct SymbolStyle: Codable, Hashable, Sendable {
    var renderingMode = RenderModeChoice.monochrome
    var colors: [ColorChoice] = [.system(.primary), .system(.blue), .system(.orange)]
    var paletteCount = 2
    /// SF Symbols 7 gradient rendering (iOS 26 and later).
    var gradient = false
    var weight = WeightChoice.regular
    var scale = ScaleChoice.medium
    var pointSize: Double = 17
    var usesVariableValue = false
    var variableValue: Double = 0.5
    /// Resolves primary, secondary, accent and multicolor colors.
    var appearance = AppearanceChoice.light

    func color(at index: Int) -> ColorChoice {
        index < colors.count ? colors[index] : (colors.last ?? .system(.primary))
    }

    mutating func setColor(_ color: ColorChoice, at index: Int) {
        while colors.count <= index { colors.append(colors.last ?? .system(.primary)) }
        colors[index] = color
    }

    /// The colors the current rendering mode actually uses.
    var activeColors: [ColorChoice] {
        guard renderingMode == .palette else { return [color(at: 0)] }
        return (0..<min(max(paletteCount, 1), 3)).map { color(at: $0) }
    }
}

struct ExportOptions: Codable, Hashable, Sendable {
    /// Side of the square canvas in pixels; 0 keeps the symbol's own frame at its point size.
    var canvas = 256
    var padding: Double = 0.1
    var transparentBackground = true
    var background = RGBA.white
}

struct SavedDesign: Codable, Identifiable {
    var id = UUID()
    var title: String
    var symbolName: String
    var style: SymbolStyle
    var options: ExportOptions
    var date = Date()
}

enum StudioError: LocalizedError {
    case resource(String), export(String)
    var errorDescription: String? {
        switch self {
        case .resource(let message), .export(let message): return message
        }
    }
}
