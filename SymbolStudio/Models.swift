import Foundation
import SwiftUI
import UIKit

struct SymbolItem: Codable, Identifiable, Hashable, Sendable {
    let name: String
    let categories: [String]
    let keywords: String
    let partCount: Int
    var id: String { name }
    var searchableText: String { name + " " + keywords }
}

struct SymbolCategory: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let icon: String
    let count: Int
}

struct SymbolCatalog: Codable, Sendable {
    let version: String
    let weight: String
    let sourceCommit: String
    let categories: [SymbolCategory]
    let symbols: [SymbolItem]
}

struct VectorPart: Codable, Sendable {
    let d: String
    let commands: [Double]
    let alpha: Double

    func path() -> Path {
        var result = Path()
        var i = 0
        while i < commands.count {
            let operation = Int(commands[i]); i += 1
            switch operation {
            case 0, 1:
                guard i + 1 < commands.count else { return result }
                let point = CGPoint(x: commands[i], y: commands[i + 1]); i += 2
                if operation == 0 { result.move(to: point) } else { result.addLine(to: point) }
            case 2:
                guard i + 5 < commands.count else { return result }
                result.addCurve(to: CGPoint(x: commands[i + 4], y: commands[i + 5]),
                                control1: CGPoint(x: commands[i], y: commands[i + 1]),
                                control2: CGPoint(x: commands[i + 2], y: commands[i + 3]))
                i += 6
            case 3:
                guard i + 3 < commands.count else { return result }
                result.addQuadCurve(to: CGPoint(x: commands[i + 2], y: commands[i + 3]),
                                    control: CGPoint(x: commands[i], y: commands[i + 1]))
                i += 4
            case 4: result.closeSubpath()
            default: return result
            }
        }
        return result
    }
}

struct VectorGlyph: Codable, Sendable {
    let viewBox: [Double]
    let parts: [VectorPart]

    func placement(side: Double, padding: Double) -> (scale: Double, x: Double, y: Double) {
        let usable = side * (1 - min(max(padding, 0), 0.4) * 2)
        let scale = min(usable / viewBox[2], usable / viewBox[3])
        return (scale, (side - viewBox[2] * scale) / 2 - viewBox[0] * scale,
                (side - viewBox[3] * scale) / 2 - viewBox[1] * scale)
    }
}

struct RGBA: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let black = RGBA(red: 0, green: 0, blue: 0)
    static let white = RGBA(red: 1, green: 1, blue: 1)
    static let oceanBlue = RGBA(red: 0.05, green: 0.43, blue: 1)
    static let orange = RGBA(red: 1, green: 0.57, blue: 0.08)
    static let pink = RGBA(red: 1, green: 0.22, blue: 0.42)
    static let leafGreen = RGBA(red: 0.13, green: 0.73, blue: 0.46)
    static let purple = RGBA(red: 0.55, green: 0.31, blue: 0.92)
    static let presets: [RGBA] = [.black, .white, .oceanBlue, .orange, .pink, .leafGreen, .purple]

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var hex: String {
        String(format: "#%02X%02X%02X", Int((red.clamped01 * 255).rounded()),
               Int((green.clamped01 * 255).rounded()), Int((blue.clamped01 * 255).rounded()))
    }
    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = (red.clamped01 * 255).rounded() / 255
        self.green = (green.clamped01 * 255).rounded() / 255
        self.blue = (blue.clamped01 * 255).rounded() / 255
        self.alpha = alpha.clamped01
    }
    init(_ color: Color) {
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
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
    var svgNumber: String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), self)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

enum PaintMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case uniform, parts
    var id: String { rawValue }
    var title: String { self == .uniform ? "统一配色" : "分部配色" }
}

struct ExportStyle: Codable, Equatable, Sendable {
    var mode = PaintMode.uniform
    var primary = RGBA.black
    var partColors: [Int: RGBA] = [:]
    var opacity: Double = 1
    var size: Int = 256
    var padding: Double = 0.12
    var transparentBackground = true
    var background = RGBA.white

    func color(for index: Int) -> RGBA {
        mode == .parts ? (partColors[index] ?? primary) : primary
    }
    mutating func applyPalette() {
        mode = .parts
    }
}

struct SavedDesign: Codable, Identifiable {
    var id = UUID()
    var title: String
    var symbolName: String
    var style: ExportStyle
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
