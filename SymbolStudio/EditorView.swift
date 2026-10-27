import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct RenderKey: Equatable {
    let name: String
    let style: SymbolStyle
    let options: ExportOptions
}

private enum PreviewKind: Hashable {
    case system, svg
}

@MainActor
struct EditorView: View {
    let item: SymbolItem
    @EnvironmentObject private var store: StudioStore
    @State private var style: SymbolStyle
    @State private var options: ExportOptions
    @State private var output: RenderOutput?
    @State private var renderFailed = false
    @State private var previewKind = PreviewKind.system
    @State private var previewBackground = PreviewBackground.checker
    @State private var errorMessage: String?
    @State private var shareFile: ShareFile?
    @State private var savingDesign = false
    @State private var designTitle = ""
    @State private var toast: String?

    init(item: SymbolItem, style: SymbolStyle = SymbolStyle(), options: ExportOptions = ExportOptions()) {
        self.item = item
        _style = State(initialValue: style)
        _options = State(initialValue: options)
    }

    var body: some View {
        Form {
            previewSection
            appearanceSection
            symbolSection
            canvasSection
            exportSection
            advancedSection
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { store.toggleFavorite(item.name) } label: {
                    Image(systemName: store.favorites.contains(item.name) ? "star.fill" : "star")
                }
                .accessibilityLabel(store.favorites.contains(item.name) ? "取消收藏" : "收藏")
                Menu {
                    ForEach(CodeFlavor.allCases) { flavor in
                        Button("复制 \(flavor.title) 代码") { copyCode(flavor) }
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                } primaryAction: {
                    copyCode(.swiftUI)
                }
                .accessibilityLabel("复制代码")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
        }
        .task(id: RenderKey(name: item.name, style: style, options: options)) { await rerender() }
        .onAppear { store.recordRecent(item.name) }
        .sheet(item: $shareFile) { ShareSheet(file: $0.url) }
        .alert("保存配色", isPresented: $savingDesign) {
            TextField("配色名称", text: $designTitle)
            Button("保存") { saveDesign() }
            Button("取消", role: .cancel) { }
        } message: { Text("保留渲染模式、颜色、粗细和导出设置，方便下次继续编辑。") }
        .alert("操作未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: toast)
    }

    // MARK: Sections

    private var previewSection: some View {
        Section {
            VStack(spacing: 12) {
                ZStack {
                    previewBackground.view
                    switch previewKind {
                    case .system:
                        StyledSymbol(name: item.name, style: style, pointSize: 96)
                            .environment(\.colorScheme, style.appearance.colorScheme)
                    case .svg:
                        if let output {
                            SVGWebView(svg: output.svg).padding(12)
                        } else if renderFailed {
                            Text("没有可预览的 SVG").foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.gray.opacity(0.15), lineWidth: 1))
                Picker("预览内容", selection: $previewKind) {
                    Text("系统渲染").tag(PreviewKind.system)
                    Text("导出的 SVG").tag(PreviewKind.svg)
                }
                .pickerStyle(.segmented)
                Picker("预览底色", selection: $previewBackground) {
                    ForEach(PreviewBackground.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 6)
        } footer: {
            statusFooter
        }
    }

    @ViewBuilder private var statusFooter: some View {
        if let output {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary(output))
                ForEach(output.drawing.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
        } else if renderFailed {
            Label("没能从系统渲染结果中取出矢量路径，这个符号暂时无法导出 SVG。", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else {
            Text("正在生成 SVG…")
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker(selection: $style.renderingMode) {
                ForEach(RenderModeChoice.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("渲染模式", systemImage: "paintpalette")
            }
            .pickerStyle(.menu)

            if SymbolGradientSupport.isAvailable {
                Toggle(isOn: $style.gradient) { Label("渐变 Gradients", systemImage: "circle.lefthalf.filled") }
            } else {
                LabeledContent {
                    Text("需要 iOS 26")
                } label: {
                    Label("渐变 Gradients", systemImage: "circle.lefthalf.filled")
                }
                .foregroundStyle(.secondary)
            }

            if style.renderingMode == .palette {
                Stepper("颜色层数：\(style.paletteCount)", value: $style.paletteCount, in: 2...3)
                ForEach(0..<min(max(style.paletteCount, 1), 3), id: \.self) { index in
                    ColorChoiceRow(title: "第 \(index + 1) 层", choice: colorBinding(index), appearance: style.appearance)
                }
            } else {
                ColorChoiceRow(title: style.renderingMode == .multicolor ? "可变部分颜色" : "颜色",
                               choice: colorBinding(0), appearance: style.appearance)
            }

            Picker("系统色按此外观导出", selection: $style.appearance) {
                ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("外观")
        } footer: {
            Text(style.renderingMode.footnote + " Primary、Secondary、Accent 等系统色会随浅色/深色变化，SVG 里会写入所选外观下的具体颜色。")
        }
    }

    private var symbolSection: some View {
        Section {
            Picker("粗细", selection: $style.weight) {
                ForEach(WeightChoice.allCases) { Text($0.title).tag($0) }
            }
            Picker("比例", selection: $style.scale) {
                ForEach(ScaleChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("字号", selection: $style.pointSize) {
                ForEach([12, 13, 15, 17, 20, 22, 24, 28, 34, 44, 64, 96] as [Double], id: \.self) { size in
                    Text("\(Int(size)) pt").tag(size)
                }
            }
            Toggle("可变值 Variable Value", isOn: $style.usesVariableValue)
            if style.usesVariableValue {
                ValueSlider(title: "可变值", value: $style.variableValue, range: 0...1,
                            valueText: "\(Int((style.variableValue * 100).rounded()))%")
            }
        } header: {
            Text("符号")
        } footer: {
            Text("字号只影响“原始尺寸”导出和复制的代码。可变值只对支持可变颜色的符号生效，例如 wifi、speaker.wave.3。")
        }
    }

    private var canvasSection: some View {
        Section {
            Picker("画布", selection: $options.canvas) {
                Text("原始尺寸（按字号）").tag(0)
                ForEach([16, 24, 32, 48, 64, 128, 256, 512, 1024, 2048], id: \.self) { size in
                    Text("\(size) × \(size)").tag(size)
                }
            }
            if options.canvas > 0 {
                ValueSlider(title: "四周留白", value: $options.padding, range: 0...0.4,
                            valueText: "\(Int((options.padding * 100).rounded()))%")
            }
            Toggle("透明背景", isOn: $options.transparentBackground)
            if !options.transparentBackground { ColorEditor(label: "背景颜色", value: $options.background) }
        } header: {
            Text("画布")
        } footer: {
            Text(options.canvas > 0
                 ? "图形按实际轮廓居中缩放到画布内。"
                 : "保留符号在 \(Int(style.pointSize)) pt 下的排版框，适合和文字对齐。")
        }
    }

    private var exportSection: some View {
        Section {
            Button { saveSVG() } label: { Label("保存 SVG 到“文件”", systemImage: "square.and.arrow.down") }
                .disabled(output == nil)
            Button { share("svg") } label: { Label("分享 SVG", systemImage: "square.and.arrow.up") }
                .disabled(output == nil)
            Button { share("png") } label: { Label("导出 PNG", systemImage: "photo") }
                .disabled(output == nil)
            Button {
                guard let output else { return }
                UIPasteboard.general.string = output.svg
                showToast("已复制 SVG 源码")
            } label: { Label("复制 SVG 源码", systemImage: "chevron.left.forwardslash.chevron.right") }
                .disabled(output == nil)
            Menu {
                ForEach(CodeFlavor.allCases) { flavor in
                    Button(flavor.title) { copyCode(flavor) }
                }
            } label: { Label("复制代码", systemImage: "swift") }
            Button { designTitle = item.name; savingDesign = true } label: {
                Label("保存配色", systemImage: "bookmark")
            }
        } header: {
            Text("保存与导出")
        } footer: {
            Text("SVG 由系统实际绘制的矢量路径转换而来，颜色、层级透明度和渐变都会写入文件。")
        }
    }

    private var advancedSection: some View {
        Section {
            Button { share("pdf") } label: { Label("导出原始 PDF（排查问题用）", systemImage: "doc.richtext") }
                .disabled(output == nil)
            Button { share("json") } label: { Label("导出配色 JSON", systemImage: "curlybraces") }
        } header: {
            Text("高级")
        } footer: {
            Text("SVG 由复制出去的同一段 SwiftUI 代码绘制后转换而来。如果“导出的 SVG”和“系统渲染”看起来不一样，可以导出原始 PDF 用来排查。")
        }
    }

    // MARK: Actions

    private func colorBinding(_ index: Int) -> Binding<ColorChoice> {
        Binding(get: { style.color(at: index) }, set: { style.setColor($0, at: index) })
    }

    private func summary(_ output: RenderOutput) -> String {
        var parts = ["\(output.drawing.shapeCount) 条路径"]
        if !output.drawing.gradients.isEmpty { parts.append("\(output.drawing.gradients.count) 个渐变") }
        if !output.drawing.masks.isEmpty { parts.append("\(output.drawing.masks.count) 个蒙版") }
        parts.append("\(SVGWriter.number(output.layout.width)) × \(SVGWriter.number(output.layout.height))")
        return "SVG：" + parts.joined(separator: " · ")
    }

    private func rerender() async {
        try? await Task.sleep(nanoseconds: 120_000_000)
        if Task.isCancelled { return }
        let result = SymbolPipeline.render(name: item.name, style: style, options: options)
        if Task.isCancelled { return }
        output = result
        renderFailed = result == nil
    }

    private func saveSVG() {
        guard let output else { return }
        do {
            let url = try ExportFile.write(Data(output.svg.utf8), name: item.name, fileExtension: "svg")
            if !DocumentPicker.save(url, saved: { showToast("已保存 SVG") }) { shareFile = ShareFile(url: url) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func share(_ kind: String) {
        do {
            let data: Data
            switch kind {
            case "json":
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                data = try encoder.encode(SavedDesign(title: item.name, symbolName: item.name, style: style, options: options))
            default:
                guard let output else { throw StudioError.export("SVG 还没有生成好，请稍后再试。") }
                switch kind {
                case "svg": data = Data(output.svg.utf8)
                case "pdf": data = output.pdf
                default:
                    guard let png = SymbolPipeline.png(output, options: options) else {
                        throw StudioError.export("PNG 生成失败，请重试。")
                    }
                    data = png
                }
            }
            shareFile = ShareFile(url: try ExportFile.write(data, name: item.name, fileExtension: kind))
        } catch { errorMessage = error.localizedDescription }
    }

    private func copyCode(_ flavor: CodeFlavor) {
        UIPasteboard.general.string = CodeGenerator.code(name: item.name, style: style, flavor: flavor)
        showToast("已复制 \(flavor.title) 代码")
    }

    private func saveDesign() {
        do {
            try store.saveDesign(name: item.name, title: designTitle, style: style, options: options)
            showToast("已保存配色")
        } catch { errorMessage = error.localizedDescription }
    }

    private func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if toast == text { toast = nil }
        }
    }
}

/// A color menu like the system's: named colors, semantic colors and custom.
struct ColorChoiceRow: View {
    let title: String
    @Binding var choice: ColorChoice
    let appearance: AppearanceChoice

    var body: some View {
        Picker(selection: key) {
            ForEach(SystemColor.allCases) { color in
                Text(color.title).tag(color.rawValue)
            }
            Text("自定义 Custom").tag(ColorChoice.customKey)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(choice.shapeStyle)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(.gray.opacity(0.35), lineWidth: 1))
                    .environment(\.colorScheme, appearance.colorScheme)
                Text(title)
            }
        }
        .pickerStyle(.menu)
        if case .custom = choice {
            ColorEditor(label: "自定义颜色", value: custom)
        }
    }

    private var key: Binding<String> {
        Binding(get: { choice.key }, set: { newKey in
            if let color = SystemColor(rawValue: newKey) {
                choice = .system(color)
            } else if case .system = choice {
                choice = .custom(choice.resolved(appearance))
            }
        })
    }

    private var custom: Binding<RGBA> {
        Binding(get: {
            if case .custom(let rgba) = choice { return rgba }
            return choice.resolved(appearance)
        }, set: { choice = .custom($0) })
    }
}

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueText: String
    var body: some View {
        VStack(spacing: 6) {
            HStack { Text(title); Spacer(); Text(valueText).foregroundStyle(.secondary).monospacedDigit() }
            Slider(value: $value, in: range).accessibilityLabel(title)
        }.padding(.vertical, 4)
    }
}

struct ColorEditor: View {
    let label: String
    @Binding var value: RGBA
    var showsHex = true
    @State private var input = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ColorPicker(label, selection: Binding(get: { value.color }, set: { value = RGBA($0) }), supportsOpacity: true)
            if showsHex {
                HStack(spacing: 10) {
                    Text("HEX").font(.caption).foregroundStyle(.secondary)
                    TextField("#RRGGBB 或 #RRGGBBAA", text: $input)
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .onSubmit { applyHex() }
                    Button("应用") { applyHex() }.font(.caption)
                }
                if invalid { Text("请输入 6 位颜色或 8 位含透明度的 HEX。").font(.caption2).foregroundStyle(.red) }
            }
        }
        .onAppear { syncHex() }
        .onChange(of: value) { _ in syncHex() }
    }
    private func syncHex() {
        input = value.hexWithAlpha
        invalid = false
    }
    private func applyHex() {
        if let next = RGBA(hex: input) { value = next; invalid = false }
        else { invalid = true }
    }
}
