import SwiftUI

struct GlyphCanvas: View {
    let glyph: VectorGlyph
    var style = ExportStyle()
    var highlightedPart: Int? = nil

    var body: some View {
        ZStack {
            if !style.transparentBackground { style.background.color }
            Canvas { context, size in
                let side = min(size.width, size.height)
                let place = glyph.placement(side: Double(side), padding: style.padding)
                context.translateBy(x: (size.width - side) / 2 + CGFloat(place.x),
                                    y: (size.height - side) / 2 + CGFloat(place.y))
                context.scaleBy(x: CGFloat(place.scale), y: CGFloat(place.scale))
                for (index, part) in glyph.parts.enumerated() {
                    let color = style.color(for: index)
                    var local = context
                    let dim = highlightedPart == nil || highlightedPart == index ? 1.0 : 0.15
                    local.opacity = part.alpha * dim
                    local.fill(part.path(), with: .color(color.color), style: FillStyle(eoFill: false))
                }
            }
            .opacity(style.opacity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 14
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.96)))
            for row in 0...Int(size.height / cell) {
                for column in 0...Int(size.width / cell) where (row + column) % 2 == 0 {
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(Color(white: 0.88)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct SymbolThumbnail: View {
    let name: String
    var color: RGBA = .black
    var savedStyle: ExportStyle? = nil
    @State private var glyph: VectorGlyph?
    @State private var failed = false

    var body: some View {
        Group {
            if let glyph {
                GlyphCanvas(glyph: glyph, style: thumbnailStyle)
            } else if failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else { ProgressView().controlSize(.small) }
        }
        .task(id: name) {
            glyph = nil; failed = false
            do {
                let loaded = try await GlyphStore.shared.load(name)
                try Task.checkCancellation(); glyph = loaded
            } catch is CancellationError { } catch { failed = true }
        }
    }
    private var thumbnailStyle: ExportStyle {
        if let savedStyle { return savedStyle }
        var style = ExportStyle(); style.primary = color; style.padding = 0.16
        return style
    }
}
