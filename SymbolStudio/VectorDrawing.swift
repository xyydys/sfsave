import CoreGraphics
import Foundation

/// Vector content recovered from a PDF page. All geometry is in page space with
/// the origin at the top-left corner and y pointing down, like SVG.
struct VectorDrawing {
    var nodes: [VectorNode] = []
    var clips: [String: VectorClip] = [:]
    var gradients: [String: VectorGradient] = [:]
    var masks: [String: VectorMask] = [:]
    var pageSize: CGSize = .zero
    /// Union of everything painted outside masks; `.null` when nothing was painted.
    var bounds: CGRect = .null
    var warnings: [String] = []
    var rasterImages = 0
    var textRuns = 0

    var shapeCount: Int { Self.count(nodes) }
    var isEmpty: Bool { bounds.isNull || shapeCount == 0 }
    /// True when the PDF held content that the SVG cannot carry as vectors.
    var isIncomplete: Bool { rasterImages > 0 || textRuns > 0 }

    private static func count(_ nodes: [VectorNode]) -> Int {
        nodes.reduce(0) { total, node in
            switch node {
            case .shape: return total + 1
            case .group(let group): return total + count(group.children)
            }
        }
    }
}

enum VectorNode {
    case shape(VectorShape)
    case group(VectorGroup)
}

struct VectorShape {
    enum Paint {
        case color(RGBA)
        case gradient(String)
    }

    var path: CGPath
    var evenOdd = false
    var fill: Paint?
    var fillOpacity: Double = 1
    var stroke: RGBA?
    var strokeOpacity: Double = 1
    /// Stroke width in page space.
    var strokeWidth: CGFloat = 0
    var lineCap = 0
    var lineJoin = 0
    var clipID: String?
    var maskID: String?

    var bounds: CGRect {
        let box = path.boundingBoxOfPath
        return stroke == nil ? box : box.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
    }
}

struct VectorGroup {
    var opacity: Double = 1
    var clipID: String?
    var maskID: String?
    var children: [VectorNode] = []
}

struct VectorClip {
    let index: Int
    let path: CGPath
    let evenOdd: Bool
    /// Clips intersect: a clip also applies every clip up its parent chain.
    let parent: String?
}

struct GradientStop {
    let offset: CGFloat
    let color: RGBA
}

struct VectorGradient {
    let index: Int
    let radial: Bool
    /// Axial: x0 y0 x1 y1. Radial: x0 y0 r0 x1 y1 r1. In shading space.
    let coords: [CGFloat]
    /// Shading space to page space.
    let transform: CGAffineTransform
    let stops: [GradientStop]
}

struct VectorMask {
    let index: Int
    /// Alpha mask when true, luminosity mask otherwise.
    let alpha: Bool
    /// Luminosity masks start from this color (PDF `BC`) instead of black.
    /// The system draws "clear behind" layers as black shapes on a white
    /// backdrop, so without it the masked layer disappears entirely.
    let backdrop: RGBA?
    let children: [VectorNode]
}
