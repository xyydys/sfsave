import Foundation
import SwiftUI
import UIKit

/// The parts of a WeChatIconCapture `manifest.json` this app reads. Fields
/// other than `name` and `file` are optional and skipped when malformed.
struct CaptureManifest: Decodable {
    struct Size: Decodable {
        var w: Double
        var h: Double
        var cgSize: CGSize { CGSize(width: w, height: h) }
    }

    struct App: Decodable {
        var version: String?
    }

    struct Device: Decodable {
        var model: String?
        var systemVersion: String?
    }

    struct Entry: Decodable {
        var name: String
        var file: String
        var type: String?
        var renderSize: Size?
        var imageSize: Size?
        var color: String?
        var angle: Double?

        private enum CodingKeys: String, CodingKey { case name, file, type, renderSize, imageSize, color, angle }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            file = try c.decode(String.self, forKey: .file)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            renderSize = try? c.decodeIfPresent(Size.self, forKey: .renderSize)
            imageSize = try? c.decodeIfPresent(Size.self, forKey: .imageSize)
            color = try? c.decodeIfPresent(String.self, forKey: .color)
            angle = try? c.decodeIfPresent(Double.self, forKey: .angle)
        }
    }

    var tool: String?
    var app: App?
    var device: Device?
    var icons: [Entry]
}

/// One WeChat resource, with every capture of it merged.
struct CaptureIcon: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        /// SVG that WeChat draws in a color it passes at runtime.
        case svg
        /// SVG that carries its own colors.
        case colorful
        case bitmap

        var title: String {
            switch self {
            case .svg: return "SVG 图标（微信上色）"
            case .colorful: return "彩色 SVG"
            case .bitmap: return "位图"
            }
        }
    }

    var id: String { name }
    /// The resource name without `.png` / `.jpg`; also the exported file name.
    var name: String
    var kind: Kind
    /// Sizes WeChat asked for, in points.
    var sizes: [CGSize]
    /// Colors WeChat drew it in, as `#RRGGBB`.
    var colors: [String]
    var angles: [Double]
    /// The largest capture, inside the project's `icons` folder.
    var image: String
    var canvas: CGSize
    /// Where the original's visible pixels are, in canvas points.
    var inkBox: CGRect?
    var captures: Int
    /// The WeChat version of the capture that first had this icon.
    var firstSeen: String? = nil
    /// Which import added it, counting from 1.
    var importIndex: Int? = nil
    /// A newer capture with a different canvas or visible area, kept aside
    /// because the icon already has a replacement tuned to the old one.
    var update: CaptureUpdate? = nil
    /// What the icon-replacement plugin's template says about this resource.
    var plugin: PluginResource? = nil

    /// The color WeChat uses most for this icon, if it tints it.
    var mainColor: String? { colors.first }

    var sizeText: String {
        sizes.map { "\(SVGWriter.number($0.width))×\(SVGWriter.number($0.height))" }.joined(separator: "、")
    }

    /// Light icons are shown on a dark tile so they stay visible.
    var prefersDarkTile: Bool {
        guard let color = mainColor.flatMap({ RGBA(hex: $0) }) else { return false }
        return color.red * 0.3 + color.green * 0.59 + color.blue * 0.11 > 0.8
    }
}

/// How a replacement is drawn. Presets fill this in; the custom editor changes it.
struct IconLook: Codable, Hashable {
    var mode: RenderModeChoice
    /// Fill of each layer. Multicolor uses only the first one, as its accent color.
    var fills: [GradientFill]
    var weight = WeightChoice.regular
    /// SF Symbols 7 gradient rendering (iOS 26).
    var gradientRendering = false
    var badge: SymbolBadge? = nil
    /// Size relative to the original's visible area.
    var size: Double = 1

    func style(pointSize: Double) -> SymbolStyle {
        var style = SymbolStyle()
        style.renderingMode = mode
        style.colors = fills.map { .custom($0.start) }
        style.paletteCount = min(max(fills.count, 2), 3)
        style.fills = mode == .multicolor ? nil : fills
        style.weight = weight
        style.gradient = gradientRendering
        style.badge = badge
        style.pointSize = pointSize
        return style
    }

    var layerCount: Int { mode == .palette ? min(max(fills.count, 2), 3) : 1 }
}

/// One resource as listed in the plugin's template `manifest.json`.
struct PluginResource: Codable, Equatable {
    /// `png` and/or `svg`: the files the plugin takes for this resource.
    var formats: [String]
    /// The SVG's file name inside WeChat (`inApp`).
    var inApp: String?
    /// The template also has `png-dark/name@3x.png`.
    var hasDark: Bool
    /// `width` × `height` from the template, in points.
    var size: CGSize
    /// WeChat's own SVG, kept in the project's `icons` folder.
    var svgFile: String?
}

/// The look every icon gets unless it was styled on its own.
struct GlobalStyle: Codable, Equatable {
    var look = IconLook(mode: .hierarchical, fills: [GradientFill(solid: RGBA(red: 0.2, green: 0.47, blue: 0.96))], weight: .medium)
    /// The first color comes from the color WeChat draws the icon in, when known.
    var useOriginalColor = false
}

struct CaptureUpdate: Codable, Equatable {
    var image: String
    var canvas: CGSize
    var inkBox: CGRect?
    var version: String?
}

struct IconChoice: Codable, Hashable {
    /// `false` keeps WeChat's own icon.
    var replace: Bool
    var symbol: String
    var look: IconLook
    /// The preset the look came from; `nil` once it has been edited.
    var presetID: String?
    /// Set by the per-icon screen, cleared by bulk apply. Choices saved
    /// before this existed count as hand-made.
    var manual: Bool? = nil
    /// Drawn with the global style instead of `look`. Choices saved before
    /// this existed follow it unless they were styled by hand.
    var followsGlobal: Bool? = nil

    var isManual: Bool { manual ?? true }
    var usesGlobal: Bool { followsGlobal ?? !isManual }
}

private func hexColor(_ hex: String) -> RGBA { RGBA(hex: hex) ?? .black }
private func gradient(_ start: String, _ end: String, angle: Double = 45) -> GradientFill {
    GradientFill(hexColor(start), hexColor(end), angle: angle)
}
private func solid(_ hex: String) -> GradientFill { GradientFill(solid: hexColor(hex)) }

struct LookPreset: Identifiable {
    let id: String
    let title: String
    private let make: (CaptureIcon?) -> IconLook

    init(_ id: String, _ title: String, _ make: @escaping (CaptureIcon?) -> IconLook) {
        self.id = id
        self.title = title
        self.make = make
    }

    func look(for icon: CaptureIcon?) -> IconLook { make(icon) }

    static let all: [LookPreset] = [
        LookPreset("aurora", "极光") { _ in IconLook(mode: .hierarchical, fills: [gradient("#7F5AF0", "#2CB5FF")], weight: .medium) },
        LookPreset("sunset", "日落") { _ in IconLook(mode: .hierarchical, fills: [gradient("#FF5F6D", "#FFC371")], weight: .medium) },
        LookPreset("lime", "青柠") { _ in IconLook(mode: .hierarchical, fills: [gradient("#11998E", "#38EF7D")], weight: .medium) },
        LookPreset("sakura", "樱花") { _ in IconLook(mode: .hierarchical, fills: [gradient("#FF6CAB", "#7366FF")], weight: .medium) },
        LookPreset("neon", "霓虹") { _ in
            IconLook(mode: .palette, fills: [gradient("#FF3CAC", "#784BA0"), gradient("#00DBDE", "#2B86C5"),
                                             gradient("#FFD452", "#FF8A00")], weight: .medium)
        },
        LookPreset("contrast", "撞色") { _ in
            IconLook(mode: .palette, fills: [gradient("#0061FF", "#60EFFF"), gradient("#FF8A65", "#FF5252"),
                                             gradient("#FFE259", "#FFA751")], weight: .medium)
        },
        LookPreset("candy", "糖果") { _ in
            IconLook(mode: .palette, fills: [solid("#FF6FB5"), solid("#4FC3F7"), solid("#FFC93C")],
                     weight: .semibold, gradientRendering: true)
        },
        LookPreset("official", "官方多色") { _ in IconLook(mode: .multicolor, fills: [solid("#0A84FF")]) },
        LookPreset("badgeViolet", "紫色方章") { _ in
            IconLook(mode: .hierarchical, fills: [solid("#FFFFFF")], weight: .semibold,
                     badge: SymbolBadge(shape: .squircle, fill: gradient("#6A5CFF", "#C04CFD")))
        },
        LookPreset("badgeOcean", "蓝色方章") { _ in
            IconLook(mode: .hierarchical, fills: [solid("#FFFFFF")], weight: .semibold,
                     badge: SymbolBadge(shape: .squircle, fill: gradient("#2B5CFF", "#2CD8FF")))
        },
        LookPreset("badgeGreen", "微信绿方章") { _ in
            IconLook(mode: .hierarchical, fills: [solid("#FFFFFF")], weight: .semibold,
                     badge: SymbolBadge(shape: .squircle, fill: gradient("#07C160", "#2BD9A0")))
        },
        LookPreset("badgeCoral", "珊瑚圆章") { _ in
            IconLook(mode: .hierarchical, fills: [solid("#FFFFFF")], weight: .semibold,
                     badge: SymbolBadge(shape: .circle, fill: gradient("#FF7A45", "#FF3D71")))
        },
        LookPreset("original", "原色") { icon in
            IconLook(mode: .monochrome, fills: [solid(icon?.mainColor ?? "#191919")])
        }
    ]

    static func named(_ id: String?) -> LookPreset? { all.first { $0.id == id } }
}

/// Candidate symbols per resource name: the bundled list for the captured
/// WeChat resources, then guesses from the words in the name.
struct SuggestionBook {
    struct Item: Decodable {
        var title: String
        var symbols: [String]
        var decorative: Bool?
    }

    private struct File: Decodable { var icons: [String: Item] }

    var items: [String: Item] = [:]

    static func bundled() -> SuggestionBook {
        guard let url = Bundle.main.url(forResource: "wechat-suggestions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return SuggestionBook() }
        return SuggestionBook(items: file.icons)
    }

    func title(for name: String) -> String? { items[name]?.title }

    func isDecorative(_ name: String) -> Bool {
        if let item = items[name] { return item.decorative ?? false }
        let lower = name.lowercased()
        let words = Self.words(in: name)
        return ["shadow", "mask", "bkg", "background", "border", "placeholder", "slider", "loading"].contains { lower.contains($0) }
            || words.contains("bg")
    }

    func symbols(for name: String) -> [String] {
        var result = items[name]?.symbols ?? []
        if result.isEmpty {
            for word in Self.words(in: name) { result += Self.keywordSymbols[word] ?? [] }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted && UIImage(systemName: $0) != nil }.prefix(6).map { $0 }
    }

    /// Lower-cased words of a resource name, split at `_`, `.`, digits and camel case.
    static func words(in name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in name {
            if !character.isLetter {
                if !current.isEmpty { words.append(current.lowercased()) }
                current = ""
            } else {
                if character.isUppercase, let previous, previous.isLowercase, !current.isEmpty {
                    words.append(current.lowercased())
                    current = ""
                }
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    private static let keywordSymbols: [String: [String]] = [
        "arrow": ["chevron.right"], "left": ["chevron.left"], "right": ["chevron.right"], "up": ["chevron.up"],
        "down": ["chevron.down"], "back": ["chevron.left"], "close": ["xmark", "xmark.circle.fill"],
        "xmark": ["xmark", "xmark.circle.fill"], "search": ["magnifyingglass"], "magnifying": ["magnifyingglass"],
        "add": ["plus", "plus.circle.fill"], "plus": ["plus", "plus.circle.fill"], "minus": ["minus.circle.fill"],
        "heart": ["heart.fill"], "like": ["heart.fill", "hand.thumbsup.fill"], "star": ["star.fill"],
        "share": ["arrowshape.turn.up.right.fill", "square.and.arrow.up"], "more": ["ellipsis", "ellipsis.circle.fill"],
        "dot": ["ellipsis"], "camera": ["camera.fill"], "photo": ["photo"], "picture": ["photo"], "image": ["photo"],
        "img": ["photo"], "video": ["video.fill", "play.rectangle.fill"], "play": ["play.fill", "play.circle.fill"],
        "pause": ["pause.fill"], "music": ["music.note"], "voice": ["waveform", "microphone.fill"],
        "mic": ["microphone.fill"], "mike": ["microphone.fill"], "volume": ["speaker.wave.2.fill"],
        "speaker": ["speaker.wave.2.fill"], "person": ["person.fill"], "contact": ["person.crop.circle.fill"],
        "friend": ["person.2.fill"], "group": ["person.3.fill"], "setting": ["gearshape.fill"], "gear": ["gearshape.fill"],
        "location": ["mappin", "location.fill"], "lock": ["lock.fill"], "trash": ["trash"], "delete": ["trash", "delete.left"],
        "copy": ["document.on.document"], "download": ["arrow.down.circle", "square.and.arrow.down"],
        "upload": ["arrow.up.circle"], "refresh": ["arrow.clockwise"], "bell": ["bell.fill"],
        "notify": ["bell.fill"], "chat": ["bubble.left.fill"], "bubble": ["bubble.left.fill"], "comment": ["bubble.left"],
        "message": ["message.fill"], "mail": ["envelope.fill"], "email": ["envelope.fill"], "pay": ["creditcard.fill"],
        "wallet": ["wallet.pass.fill"], "envelope": ["envelope.fill"], "link": ["link"], "file": ["document"],
        "doc": ["document"], "folder": ["folder.fill"], "tag": ["tag.fill"], "clock": ["clock"], "time": ["clock"],
        "check": ["checkmark.circle.fill"], "checkbox": ["checkmark.circle.fill"], "warning": ["exclamationmark.triangle.fill"],
        "exclamation": ["exclamationmark.circle.fill"], "game": ["gamecontroller.fill"], "moment": ["camera.aperture"],
        "moments": ["camera.aperture"], "live": ["record.circle"], "scan": ["qrcode.viewfinder"], "qr": ["qrcode"],
        "phone": ["phone.fill"], "call": ["phone.fill"], "translate": ["translate"], "font": ["textformat"],
        "edit": ["square.and.pencil"], "pencil": ["pencil"], "gift": ["gift.fill"], "emoji": ["face.smiling"],
        "emoticon": ["face.smiling"], "smile": ["face.smiling"], "keyboard": ["keyboard"], "cloud": ["icloud"],
        "home": ["house.fill"], "index": ["house.fill"], "cart": ["cart.fill"], "flag": ["flag.fill"], "map": ["map.fill"],
        "favorite": ["star.fill"], "favorites": ["star.fill"], "sticker": ["face.smiling"], "card": ["creditcard.fill"],
        "news": ["newspaper.fill"], "book": ["book.fill"], "red": ["envelope.fill"], "mini": ["link.circle.fill"],
        "program": ["link.circle.fill"], "weapp": ["link.circle.fill"], "finder": ["play.rectangle.on.rectangle"],
        "channels": ["play.rectangle.on.rectangle"], "sun": ["sun.max.fill"], "moon": ["moon.fill"], "fire": ["flame.fill"]
    ]
}
