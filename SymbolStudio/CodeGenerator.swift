import Foundation

enum CodeFlavor: String, CaseIterable, Identifiable {
    case swiftUI, uiKit, objectiveC

    var id: String { rawValue }

    var title: String {
        switch self {
        case .swiftUI: return "SwiftUI"
        case .uiKit: return "UIKit (Swift)"
        case .objectiveC: return "Objective-C"
        }
    }
}

/// Code that draws the symbol the way the preview and the SVG show it.
enum CodeGenerator {
    static func code(name: String, style: SymbolStyle, flavor: CodeFlavor) -> String {
        switch flavor {
        case .swiftUI: return swiftUI(name, style)
        case .uiKit: return uiKit(name, style)
        case .objectiveC: return objectiveC(name, style)
        }
    }

    private static func swiftUI(_ name: String, _ style: SymbolStyle) -> String {
        var lines = [style.usesVariableValue
            ? "Image(systemName: \(quoted(name)), variableValue: \(number(style.variableValue)))"
            : "Image(systemName: \(quoted(name)))"]
        if style.weight != .regular || style.pointSize != 17 {
            lines.append("    .font(.system(size: \(number(style.pointSize)), weight: .\(style.weight.rawValue)))")
        }
        if style.scale != .medium { lines.append("    .imageScale(.\(style.scale.rawValue))") }
        lines.append("    .symbolRenderingMode(.\(style.renderingMode.rawValue))")
        lines.append("    .foregroundStyle(\(style.activeColors.map(swiftUIColor).joined(separator: ", ")))")
        if style.gradient { lines.append("    .symbolColorRenderingMode(.gradient) // iOS 26+") }
        return lines.joined(separator: "\n")
    }

    private static func uiKit(_ name: String, _ style: SymbolStyle) -> String {
        let colors = style.activeColors.map(uiKitColor)
        var lines = ["let configuration = UIImage.SymbolConfiguration(pointSize: \(number(style.pointSize)), weight: .\(style.weight.rawValue), scale: .\(style.scale.rawValue))"]
        switch style.renderingMode {
        case .monochrome: lines.append("    .applying(UIImage.SymbolConfiguration.preferringMonochrome())")
        case .hierarchical: lines.append("    .applying(UIImage.SymbolConfiguration(hierarchicalColor: \(colors[0])))")
        case .palette: lines.append("    .applying(UIImage.SymbolConfiguration(paletteColors: [\(colors.joined(separator: ", "))]))")
        case .multicolor: lines.append("    .applying(UIImage.SymbolConfiguration.preferringMulticolor())")
        }
        if style.gradient { lines.append("    .applying(UIImage.SymbolConfiguration(colorRenderingMode: .gradient)) // iOS 26+") }
        let create = style.usesVariableValue
            ? "UIImage(systemName: \(quoted(name)), variableValue: \(number(style.variableValue)), configuration: configuration)"
            : "UIImage(systemName: \(quoted(name)), withConfiguration: configuration)"
        switch style.renderingMode {
        case .monochrome, .multicolor:
            lines.append("let image = \(create)?")
            lines.append("    .withTintColor(\(colors[0]), renderingMode: .alwaysOriginal)")
        case .hierarchical, .palette:
            lines.append("let image = \(create)")
        }
        return lines.joined(separator: "\n")
    }

    private static func objectiveC(_ name: String, _ style: SymbolStyle) -> String {
        let colors = style.activeColors.map(objectiveCColor)
        let weight = "UIImageSymbolWeight" + capitalized(style.weight.rawValue)
        let scale = "UIImageSymbolScale" + capitalized(style.scale.rawValue)
        var lines = ["UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:\(number(style.pointSize)) weight:\(weight) scale:\(scale)];"]
        let colorConfiguration: String
        switch style.renderingMode {
        case .monochrome: colorConfiguration = "[UIImageSymbolConfiguration configurationPreferringMonochrome]"
        case .hierarchical: colorConfiguration = "[UIImageSymbolConfiguration configurationWithHierarchicalColor:\(colors[0])]"
        case .palette: colorConfiguration = "[UIImageSymbolConfiguration configurationWithPaletteColors:@[\(colors.joined(separator: ", "))]]"
        case .multicolor: colorConfiguration = "[UIImageSymbolConfiguration configurationPreferringMulticolor]"
        }
        lines.append("configuration = [configuration configurationByApplyingConfiguration:\(colorConfiguration)];")
        if style.gradient {
            lines.append("configuration = [configuration configurationByApplyingConfiguration:[UIImageSymbolConfiguration configurationWithColorRenderingMode:UIImageSymbolColorRenderingModeGradient]]; // iOS 26+")
        }
        lines.append(style.usesVariableValue
            ? "UIImage *image = [UIImage systemImageNamed:@\(quoted(name)) variableValue:\(number(style.variableValue)) withConfiguration:configuration];"
            : "UIImage *image = [UIImage systemImageNamed:@\(quoted(name)) withConfiguration:configuration];")
        if style.renderingMode == .monochrome || style.renderingMode == .multicolor {
            lines.append("image = [image imageWithTintColor:\(colors[0]) renderingMode:UIImageRenderingModeAlwaysOriginal];")
        }
        return lines.joined(separator: "\n")
    }

    private static func swiftUIColor(_ choice: ColorChoice) -> String {
        switch choice {
        case .system(.accent): return "Color.accentColor"
        case .system(let color): return "." + color.rawValue
        case .custom(let c):
            let opacity = c.alpha < 1 ? ", opacity: \(number(c.alpha))" : ""
            return "Color(red: \(number(c.red)), green: \(number(c.green)), blue: \(number(c.blue))\(opacity))"
        }
    }

    private static func uiKitColor(_ choice: ColorChoice) -> String {
        switch choice {
        case .system(let color): return "." + uiKitName(color)
        case .custom(let c):
            return "UIColor(red: \(number(c.red)), green: \(number(c.green)), blue: \(number(c.blue)), alpha: \(number(c.alpha)))"
        }
    }

    private static func objectiveCColor(_ choice: ColorChoice) -> String {
        switch choice {
        case .system(.accent): return "UIColor.tintColor"
        case .system(let color): return "UIColor.\(uiKitName(color))Color"
        case .custom(let c):
            return "[UIColor colorWithRed:\(number(c.red)) green:\(number(c.green)) blue:\(number(c.blue)) alpha:\(number(c.alpha))]"
        }
    }

    private static func uiKitName(_ color: SystemColor) -> String {
        switch color {
        case .white, .black: return color.rawValue
        case .primary: return "label"
        case .secondary: return "secondaryLabel"
        case .tertiary: return "tertiaryLabel"
        case .quaternary: return "quaternaryLabel"
        case .accent: return "tintColor"
        default: return "system" + capitalized(color.rawValue)
        }
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func number(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}
