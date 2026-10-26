import SwiftUI
import UIKit
import WebKit

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

enum PreviewBackground: String, CaseIterable, Identifiable {
    case checker, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .checker: return "棋盘格"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .checker: Checkerboard()
        case .light: Color.white
        case .dark: Color(white: 0.11)
        }
    }
}

/// Library thumbnail: the system symbol itself.
struct SymbolGlyph: View {
    let name: String
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size))
            .foregroundStyle(.primary)
            .frame(width: size * 1.8, height: size * 1.8)
            .accessibilityHidden(true)
    }
}

/// Shows an SVG file with WebKit, so the preview is the exported file itself
/// rather than another drawing of the symbol.
struct SVGWebView: UIViewRepresentable {
    let svg: String

    final class Coordinator {
        var loaded: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != svg else { return }
        context.coordinator.loaded = svg
        view.loadHTMLString(Self.html(svg), baseURL: nil)
    }

    static func html(_ svg: String) -> String {
        let body = svg.replacingOccurrences(of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>", with: "")
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">\
        <style>html,body{margin:0;width:100%;height:100%;background:transparent}\
        body{display:flex;align-items:center;justify-content:center}\
        svg{width:100%;height:100%}</style></head><body>\(body)</body></html>
        """
    }
}
