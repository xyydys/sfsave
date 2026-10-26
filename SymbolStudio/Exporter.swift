import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum StaticExporter {
    static func svg(name: String, glyph: VectorGlyph, style: ExportStyle) -> String {
        let side = min(max(style.size, 16), 2048)
        let p = glyph.placement(side: Double(side), padding: style.padding)
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
                     "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(side)\" height=\"\(side)\" viewBox=\"0 0 \(side) \(side)\">",
                     "  <title>\(escape(name))</title>"]
        if !style.transparentBackground {
            lines.append("  <rect width=\"\(side)\" height=\"\(side)\" fill=\"\(style.background.hex)\" fill-opacity=\"\(style.background.alpha.clamped01.svgNumber)\"/>")
        }
        lines.append("  <g opacity=\"\(style.opacity.clamped01.svgNumber)\" transform=\"translate(\(p.x.svgNumber) \(p.y.svgNumber)) scale(\(p.scale.svgNumber))\" fill-rule=\"nonzero\">")
        for (index, part) in glyph.parts.enumerated() {
            let color = style.color(for: index)
            lines.append("    <path id=\"part-\(index + 1)\" fill=\"\(color.hex)\" fill-opacity=\"\((color.alpha * part.alpha).clamped01.svgNumber)\" d=\"\(escape(part.d))\"/>")
        }
        lines += ["  </g>", "</svg>"]
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    static func write(name: String, glyph: VectorGlyph, style: ExportStyle, format: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SymbolStudio-exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = name.replacingOccurrences(of: "/", with: "_")
        let file = directory.appendingPathComponent(base + "." + format)
        let data: Data
        switch format {
        case "svg": data = Data(svg(name: name, glyph: glyph, style: style).utf8)
        case "png":
            let side = CGFloat(min(max(style.size, 16), 2048))
            let renderer = ImageRenderer(content: GlyphCanvas(glyph: glyph, style: style).frame(width: side, height: side))
            renderer.scale = 1
            renderer.isOpaque = false
            guard let png = renderer.uiImage?.pngData() else { throw StudioError.export("PNG 生成失败，请重试。") }
            data = png
        case "json":
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(SavedDesign(title: name, symbolName: name, style: style))
        default: throw StudioError.export("不支持的导出格式。")
        }
        try data.write(to: file, options: .atomic)
        return file
    }

    private static func escape(_ input: String) -> String {
        input.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

struct ShareFile: Identifiable { let id = UUID(); let url: URL }

struct ShareSheet: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
