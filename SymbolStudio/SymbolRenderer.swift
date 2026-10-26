import SwiftUI
import UIKit

/// The symbol exactly as the generated SwiftUI code draws it.
struct StyledSymbol: View {
    let name: String
    let style: SymbolStyle
    var pointSize: Double? = nil

    var body: some View {
        image
            .font(.system(size: pointSize ?? style.pointSize, weight: style.weight.fontWeight))
            .imageScale(style.scale.imageScale)
            .symbolRenderingMode(style.renderingMode.swiftUIMode)
            .modifier(SymbolForeground(colors: style.activeColors))
            .modifier(SymbolGradient(enabled: style.gradient))
    }

    private var image: Image {
        style.usesVariableValue
            ? Image(systemName: name, variableValue: style.variableValue)
            : Image(systemName: name)
    }
}

private struct SymbolForeground: ViewModifier {
    let colors: [ColorChoice]

    func body(content: Content) -> some View {
        let styles = colors.map(\.shapeStyle)
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
    let engine: RenderEngine
    var notes: [String]
}

/// Lets the system draw the symbol into a PDF, then turns the PDF's vector
/// paths into SVG. Whatever the system draws (layers, palette colors,
/// hierarchical opacity, multicolor, gradients) ends up in the file.
@MainActor
enum SymbolPipeline {
    private struct Capture {
        let pdf: Data
        let frame: CGRect
    }

    static func render(name: String, style: SymbolStyle, options: ExportOptions) -> RenderOutput? {
        var engine = options.engine
        var notes: [String] = []
        var captured = capture(name, style, engine)
        var extracted = captured.flatMap { PDFVectorExtractor.extract(pdf: $0.pdf) }

        if engine == .swiftUI, extracted.map({ $0.isEmpty || $0.isIncomplete }) ?? true,
           let fallback = capture(name, style, .uiKit),
           let fallbackDrawing = PDFVectorExtractor.extract(pdf: fallback.pdf), !fallbackDrawing.isEmpty {
            captured = fallback
            extracted = fallbackDrawing
            engine = .uiKit
            notes.append("SwiftUI 的渲染结果不是纯矢量，已自动改用 UIKit 引擎。")
        }
        guard let result = captured, let drawing = extracted, !drawing.isEmpty else { return nil }

        let layout = SVGWriter.layout(for: drawing, frame: result.frame, options: options)
        let svg = SVGWriter.svg(drawing, layout: layout, title: name,
                                background: options.transparentBackground ? nil : options.background)
        return RenderOutput(pdf: result.pdf, frame: result.frame, drawing: drawing, layout: layout,
                            svg: svg, engine: engine, notes: notes)
    }

    private static func capture(_ name: String, _ style: SymbolStyle, _ engine: RenderEngine) -> Capture? {
        switch engine {
        case .swiftUI: return swiftUICapture(name, style)
        case .uiKit: return uiKitCapture(name, style)
        }
    }

    /// Room around the symbol so parts that overhang its frame are not clipped.
    private static func margin(_ style: SymbolStyle) -> CGFloat { CGFloat(max(style.pointSize, 8)) }

    private static func swiftUICapture(_ name: String, _ style: SymbolStyle) -> Capture? {
        let inset = margin(style)
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
        return Capture(pdf: data as Data, frame: frame)
    }

    private static func uiKitCapture(_ name: String, _ style: SymbolStyle) -> Capture? {
        guard let image = uiImage(name, style) else { return nil }
        let inset = margin(style)
        let size = image.size
        let bounds = CGRect(x: 0, y: 0, width: size.width + inset * 2, height: size.height + inset * 2)
        let traits = UITraitCollection(userInterfaceStyle: style.appearance.interfaceStyle)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            traits.performAsCurrent { image.draw(at: CGPoint(x: inset, y: inset)) }
        }
        return Capture(pdf: data, frame: CGRect(x: inset, y: inset, width: size.width, height: size.height))
    }

    /// The symbol as the generated UIKit code builds it.
    static func uiImage(_ name: String, _ style: SymbolStyle) -> UIImage? {
        let traits = UITraitCollection(userInterfaceStyle: style.appearance.interfaceStyle)
        let colors = style.activeColors.map { $0.uiColor.resolvedColor(with: traits) }
        var configuration = UIImage.SymbolConfiguration(pointSize: CGFloat(style.pointSize),
                                                        weight: style.weight.uiWeight,
                                                        scale: style.scale.uiScale)
        switch style.renderingMode {
        case .monochrome:
            configuration = configuration.applying(UIImage.SymbolConfiguration.preferringMonochrome())
        case .hierarchical:
            configuration = configuration.applying(UIImage.SymbolConfiguration(hierarchicalColor: colors[0]))
        case .palette:
            configuration = configuration.applying(UIImage.SymbolConfiguration(paletteColors: colors))
        case .multicolor:
            configuration = configuration.applying(UIImage.SymbolConfiguration.preferringMulticolor())
        }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), style.gradient {
            configuration = configuration.applying(UIImage.SymbolConfiguration(colorRenderingMode: .gradient))
        }
        #endif
        let image = style.usesVariableValue
            ? UIImage(systemName: name, variableValue: style.variableValue, configuration: configuration)
            : UIImage(systemName: name, withConfiguration: configuration)
        switch style.renderingMode {
        case .monochrome, .multicolor:
            return image?.withTintColor(colors[0], renderingMode: .alwaysOriginal)
        case .hierarchical, .palette:
            return image?.withRenderingMode(.alwaysOriginal)
        }
    }

    /// Rasterizes the captured PDF with the same layout as the SVG.
    static func png(_ output: RenderOutput, options: ExportOptions) -> Data? {
        guard let provider = CGDataProvider(data: output.pdf as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let pixelScale: CGFloat = options.canvas > 0 ? 1 : 3
        let size = CGSize(width: (output.layout.width * pixelScale).rounded(.up),
                          height: (output.layout.height * pixelScale).rounded(.up))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            if !options.transparentBackground {
                cg.setFillColor(options.background.cgColor)
                cg.fill(CGRect(origin: .zero, size: size))
            }
            let box = page.getBoxRect(.mediaBox)
            cg.scaleBy(x: pixelScale, y: pixelScale)
            cg.concatenate(output.layout.transform)
            cg.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -box.minX, ty: box.maxY))
            cg.drawPDFPage(page)
        }
        return image.pngData()
    }
}
