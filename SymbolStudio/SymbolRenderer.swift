import SwiftUI
import UIKit

/// The symbol exactly as the generated SwiftUI code draws it.
struct StyledSymbol: View {
    let name: String
    let style: SymbolStyle
    var pointSize: Double? = nil

    var body: some View {
        let size = pointSize ?? style.pointSize
        if let badge = style.badge {
            ZStack {
                badgeShape(badge.shape, side: size).fill(badge.fill.shapeStyle)
                glyph(size: size * badge.glyphScale)
            }
            .frame(width: size, height: size)
        } else {
            glyph(size: size)
        }
    }

    private func glyph(size: Double) -> some View {
        image
            .font(.system(size: size, weight: style.weight.fontWeight))
            .imageScale(style.scale.imageScale)
            .symbolRenderingMode(style.renderingMode.swiftUIMode)
            .modifier(SymbolForeground(styles: style.layerStyles))
            .modifier(SymbolGradient(enabled: style.gradient))
    }

    private func badgeShape(_ shape: BadgeShape, side: Double) -> AnyShape {
        switch shape {
        case .circle: return AnyShape(Circle())
        case .squircle: return AnyShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
        }
    }

    private var image: Image {
        style.usesVariableValue
            ? Image(systemName: name, variableValue: style.variableValue)
            : Image(systemName: name)
    }
}

private struct SymbolForeground: ViewModifier {
    let styles: [AnyShapeStyle]

    func body(content: Content) -> some View {
        switch styles.count {
        case 3: return AnyView(content.foregroundStyle(styles[0], styles[1], styles[2]))
        case 2: return AnyView(content.foregroundStyle(styles[0], styles[1]))
        default: return AnyView(content.foregroundStyle(styles.first ?? AnyShapeStyle(HierarchicalShapeStyle.primary)))
        }
    }
}

private struct SymbolGradient: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return AnyView(content.symbolColorRenderingMode(enabled ? SymbolColorRenderingMode.gradient : nil))
        }
        #endif
        return AnyView(content)
    }
}

enum SymbolGradientSupport {
    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
}

struct RenderOutput {
    let pdf: Data
    /// The symbol's layout frame in page space (y down).
    let frame: CGRect
    let drawing: VectorDrawing
    let layout: SVGLayout
    let svg: String
}

/// Lets SwiftUI draw the symbol into a PDF, then turns the PDF's vector
/// paths into SVG. Whatever the system draws (layers, palette colors,
/// hierarchical opacity, multicolor, gradients) ends up in the file.
///
/// Only SwiftUI is used for drawing: a UIImage symbol drawn into a PDF
/// context with UIKit comes out as an embedded bitmap, not as paths.
@MainActor
enum SymbolPipeline {
    /// The symbol drawn into a PDF and read back as vectors, before any layout.
    /// Clips and knockout masks are already merged into the paths (see `flattened()`).
    static func renderDrawing(name: String, style: SymbolStyle) -> (pdf: Data, frame: CGRect, drawing: VectorDrawing)? {
        guard let capture = capturePDF(name: name, style: style),
              let drawing = PDFVectorExtractor.extract(pdf: capture.pdf)?.flattened(), !drawing.isEmpty else { return nil }
        return (capture.pdf, capture.frame, drawing)
    }

    static func render(name: String, style: SymbolStyle, options: ExportOptions) -> RenderOutput? {
        guard let capture = renderDrawing(name: name, style: style) else { return nil }
        let drawing = capture.drawing
        let layout = SVGWriter.layout(for: drawing, frame: capture.frame, options: options)
        let svg = SVGWriter.svg(drawing, layout: layout, title: name,
                                background: options.transparentBackground ? nil : options.background)
        return RenderOutput(pdf: capture.pdf, frame: capture.frame, drawing: drawing, layout: layout, svg: svg)
    }

    /// The symbol drawn into a one-page PDF, with its layout frame in page space.
    static func capturePDF(name: String, style: SymbolStyle) -> (pdf: Data, frame: CGRect)? {
        // Room around the symbol so parts that overhang its frame are not clipped.
        let inset = CGFloat(max(style.pointSize, 8))
        let view = StyledSymbol(name: name, style: style)
            .padding(inset)
            .environment(\.colorScheme, style.appearance.colorScheme)
        let renderer = ImageRenderer(content: view)
        let data = NSMutableData()
        var pageSize = CGSize.zero
        renderer.render { size, draw in
            pageSize = size
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
        }
        guard data.length > 0, pageSize.width > inset * 2, pageSize.height > inset * 2 else { return nil }
        let frame = CGRect(x: inset, y: inset, width: pageSize.width - inset * 2, height: pageSize.height - inset * 2)
        return (data as Data, frame)
    }

    /// Rasterizes the captured PDF with the same layout as the SVG.
    static func png(_ output: RenderOutput, options: ExportOptions) -> Data? {
        rasterize(pdf: output.pdf, layout: output.layout, pixelScale: options.canvas > 0 ? 1 : 3,
                  background: options.transparentBackground ? nil : options.background)
    }

    /// PNG of `layout` (in points) at `pixelScale` pixels per point. The image
    /// is exactly `round(width * pixelScale)` by `round(height * pixelScale)`.
    static func rasterize(pdf: Data, layout: SVGLayout, pixelScale: CGFloat, background: RGBA?) -> Data? {
        guard let provider = CGDataProvider(data: pdf as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let size = CGSize(width: max((layout.width * pixelScale).rounded(), 1),
                          height: max((layout.height * pixelScale).rounded(), 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            if let background {
                cg.setFillColor(background.cgColor)
                cg.fill(CGRect(origin: .zero, size: size))
            }
            let box = page.getBoxRect(.mediaBox)
            cg.scaleBy(x: size.width / layout.width, y: size.height / layout.height)
            cg.concatenate(layout.transform)
            cg.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -box.minX, ty: box.maxY))
            cg.drawPDFPage(page)
        }
        return image.pngData()
    }
}
